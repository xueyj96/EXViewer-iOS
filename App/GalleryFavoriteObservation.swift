import Foundation
import ExViewerCore

struct GalleryFavoriteScope: Hashable {
    let reference: GalleryRef
    let owner: String
    let generation: UUID
    init(reference: GalleryRef, owner: String, generation: UUID) {
        self.reference = reference; self.owner = owner; self.generation = generation
    }
    @MainActor init(_ gallery: Gallery, _ session: SiteSession) {
        reference = gallery.ref; owner = session.owner; generation = session.generation
    }
}

/// Reading/display observes local state only. Favorite form network access
/// belongs to the explicitly opened editor, never to binding or notifications.
@MainActor final class GalleryFavoriteObservation: ObservableObject {
    @Published private(set) var state: GalleryFavoriteState = .unknown
    @Published private(set) var phase: FavoriteSyncPhase?
    private let observerID = UUID()
    private var client: GalleryFavoriteClient?
    private var reference: GalleryRef?
    private var form: GalleryFavoriteForm?
    private var observedAt: Date?
    private weak var cache: SiteFavoriteCache?
    private var scope: GalleryFavoriteScope?
    private var cacheVersion: UUID?

    func bind(_ client: GalleryFavoriteClient, reference: GalleryRef,
              cache: SiteFavoriteCache? = nil, scope: GalleryFavoriteScope? = nil,
              now: Date = Date()) {
        cancel(); self.reference = reference
        self.cache = cache; self.scope = scope
        self.client = client; state = .unknown; phase = nil
        guard client.isCurrent() else { return }
        if let cache, let scope { cache.register(observerID, scope: scope, client: client) }
        if let cache, let scope, let recent = cache.recent(scope, now: now) {
            state = recent.state; phase = recent.phase; form = recent.form; observedAt = recent.date; cacheVersion = recent.version; return
        }
        if let cache, let scope { state = cache.entry(scope)?.state ?? .unknown; phase = cache.entry(scope)?.phase }
        cacheVersion = scope.flatMap { cache?.entry($0)?.version }
    }
    func accept(_ value: GalleryFavoriteState, form verifiedForm: GalleryFavoriteForm? = nil) {
        guard client?.isCurrent() == true else { return }
        if let verifiedForm, verifiedForm.state == value, verifiedForm.reference == reference {
            form = verifiedForm; observedAt = Date()
        } else if form?.state != value { form = nil; observedAt = nil }
        state = value
        if let cache, let scope {
            cache.put(value, form: form?.state == value ? form : nil, scope: scope)
            cacheVersion = cache.entry(scope)?.version
            if let value = cache.entry(scope) { state = value.state; phase = value.phase }
        }
    }
    func cancel() { cache?.unregister(observerID); form = nil; observedAt = nil }
    private func beginChange() {
        cancel(); state = .unknown
        if let cache, let scope {
            cache.put(.unknown, scope: scope, force: true)
            cacheVersion = cache.entry(scope)?.version
        }
    }
    func syncFromCache() {
        guard client?.isCurrent() == true, let scope, let value = cache?.entry(scope) else { return }
        cacheVersion = value.version
        if state != value.state { state = value.state }
        if phase != value.phase { phase = value.phase }
        form = value.form; observedAt = value.date
    }

    /// A recent same-account form can be reused by an explicit editor. There
    /// are no display-side reads to await or start. Verification remains fresh.
    func preparation(_ upstream: GalleryFavoriteClient, reference: GalleryRef, now: Date = Date()) -> GalleryFavoritePreparation {
        let valid = self.reference == reference && client?.isCurrent() == true && upstream.isCurrent()
        let cached = valid ? scope.flatMap { cache?.entry($0) } : nil
        let fresh = valid && (scope.flatMap { cache?.formIsFresh($0, now: now) }
            ?? (observedAt.map { now.timeIntervalSince($0) >= 0 && now.timeIntervalSince($0) < SiteFavoriteCache.refreshInterval } == true))
        let initial = valid ? cached?.form ?? form : nil
        let readScope = scope
        let wrapped = GalleryFavoriteClient(isCurrent: upstream.isCurrent, read: {
            guard upstream.isCurrent() else { throw ViewerError.stale }
            let epoch = readScope.flatMap { self.cache?.mutationEpoch($0) }
            let value = try await upstream.read()
            guard upstream.isCurrent(), self.reference == reference, self.scope == readScope,
                  readScope.flatMap({ self.cache?.mutationEpoch($0) }) == epoch else { throw ViewerError.stale }
            guard value.reference == reference else { throw ViewerError.restricted }
            self.accept(value.state, form: value)
            return value
        }, submit: upstream.submit, willSubmit: { [weak self] in
            self?.beginChange(); await upstream.willSubmit()
        }, didSubmit: upstream.didSubmit)
        let enqueue: ((GalleryFavoriteForm, FavoriteAction, String, String) throws -> Void)?
        if valid, let cache, let scope {
            enqueue = { form, action, note, title in try cache.enqueue(scope: scope, client: upstream, form: form, action: action, note: note, title: title) }
        } else { enqueue = nil }
        return .init(client: wrapped, initialForm: initial, initialState: cached?.state ?? state,
                     requiresRefresh: initial != nil && !fresh, pending: cached?.phase != nil,
                     pendingGroup: cached?.pendingGroup, pendingNote: cached?.pendingNote, enqueue: enqueue)
    }
}

struct GalleryFavoritePreparation {
    let client: GalleryFavoriteClient
    let initialForm: GalleryFavoriteForm?
    var initialState: GalleryFavoriteState = .unknown
    var requiresRefresh = false
    var pending = false
    var pendingGroup: Int?
    var pendingNote: String?
    var enqueue: ((GalleryFavoriteForm, FavoriteAction, String, String) throws -> Void)? = nil
}

@MainActor func favoriteClient(for gallery: Gallery, session: SiteSession) -> GalleryFavoriteClient {
    AppMode.qa ? NativeFavoritesQA.client(reference: gallery.ref, session: session)
        : GalleryFavoriteClient.live(reference: gallery.ref, session: session)
}

func favoriteStateDescription(_ state: GalleryFavoriteState) -> String {
    switch state {
    case .unknown: return "收藏状态尚未读取"
    case .notFavorited: return "未收藏"
    case .favorited(let group): return "已收藏，\(group)"
    }
}
