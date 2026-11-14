import Foundation
import ExViewerCore

@MainActor final class GalleryPager: ObservableObject {
    @Published private(set) var items: [Gallery] = []
    @Published private(set) var loading = false
    @Published private(set) var next: URL?
    @Published private(set) var failure: String?
    @Published private(set) var categories: [String: String] = [:]
    @Published private(set) var interrupted = false
    @Published private(set) var cachedAt: Date?
    enum LoadingPresentation: Equatable { case hidden, initial, more }
    var loadingPresentation: LoadingPresentation {
        guard loading else { return .hidden }
        if items.isEmpty { return .initial }
        return activeURL == root ? .hidden : .more
    }
    private var context = UUID()
    private var task: Task<Void, Never>?
    private var snapshotPreparation: Task<Void, Never>?
    private var loaded = Set<URL>()
    private var root: URL?
    private var qa = false
    private var sourceOwner = ""
    private var sourceGeneration: UUID?
    private var retryURL: URL?
    private var activeURL: URL?
    private var activePriority: SearchRequestPriority = .foreground
    // Belongs to this root presentation, so cancel/resume cannot turn an
    // automatic validation into a visible refresh. Explicit reset promotes it.
    private var preservesCachedPresentation = false
    private var removedFavoriteIDs = Set<String>()
    private var minimumRating: Int? { root.flatMap(GalleryRatingFilter.minimum(in:)) }
    private var cacheEpoch = 0
    private let cache: FeedSnapshotCache?
    private let loadHTML: ((URL, Bool, Data?) async throws -> String)?
    typealias SnapshotCoverPreparation = @MainActor ([Gallery], String) async -> Bool
    private let prepareSnapshotCovers: SnapshotCoverPreparation?
    init(loadHTML: ((URL, Bool, Data?) async throws -> String)? = nil, cache: FeedSnapshotCache? = nil,
         prepareSnapshotCovers: SnapshotCoverPreparation? = nil) {
        if let prepareSnapshotCovers {
            self.prepareSnapshotCovers = prepareSnapshotCovers
        } else if loadHTML == nil && !FeedCacheQA.isEnabled {
            self.prepareSnapshotCovers = { galleries, owner in
                await FeedSnapshotCovers.prepare(galleries) { url in
                    _ = try await MediaRepository.shared.file(for: url, owner: owner, priority: .thumbnailPrefetch)
                }
            }
        } else {
            // Injected HTML/QA fixtures never make unrelated live image requests.
            self.prepareSnapshotCovers = nil
        }
        if loadHTML == nil, FeedCacheQA.isEnabled {
            self.loadHTML = FeedCacheQA.loadHTML
            self.cache = cache ?? FeedCacheQA.cache
        } else {
            self.loadHTML = loadHTML
            self.cache = cache ?? (loadHTML == nil ? .shared : nil)
        }
    }
    struct NavigationSnapshot {
        let items: [Gallery]
        let next: URL?
        let failure: String?
        let categories: [String: String]
        let loaded: Set<URL>
        let root: URL?
        let qa: Bool
        let interrupted: Bool
        let owner: String
        let generation: UUID?
        let retryURL: URL?
        let cachedAt: Date?
        let cacheEpoch: Int
        let preservesCachedPresentation: Bool
    }
    func cancel() {
        if loading { interrupted = true }
        task?.cancel(); task = nil
        snapshotPreparation?.cancel(); snapshotPreparation = nil
        context = UUID(); loading = false; activeURL = nil
    }
    func pauseForSelection() { if loading { cancel() } }
    func navigationSnapshot() -> NavigationSnapshot {
        cancel()
        return .init(items: items, next: next, failure: failure, categories: categories,
                     loaded: loaded, root: root, qa: qa, interrupted: interrupted,
                     owner: sourceOwner, generation: sourceGeneration, retryURL: retryURL, cachedAt: cachedAt, cacheEpoch: cacheEpoch,
                     preservesCachedPresentation: preservesCachedPresentation)
    }
    func restoreNavigationSnapshot(_ snapshot: NavigationSnapshot) {
        cancel(); items = snapshot.items; next = snapshot.next; failure = snapshot.failure
        categories = snapshot.categories; loaded = snapshot.loaded; root = snapshot.root
        qa = snapshot.qa; interrupted = snapshot.interrupted; sourceOwner = snapshot.owner
        sourceGeneration = snapshot.generation; retryURL = snapshot.retryURL; cachedAt = snapshot.cachedAt
        cacheEpoch = snapshot.cacheEpoch; preservesCachedPresentation = snapshot.preservesCachedPresentation
    }
    /// Cache-only preparation for a real, uncommitted pane. No HTTP or cursor is consumed.
    func prepareCached(url: URL, session: SiteSession, qa: Bool) async {
        guard !Task.isCancelled, root == nil, !loading else { return }
        let token = context, owner = session.owner, generation = session.generation
        if qa && !FeedCacheQA.isEnabled {
            root = url; sourceOwner = owner; sourceGeneration = generation; self.qa = true
            applyQASnapshot(url)
            return
        }
        guard let cache else { return }
        let epoch = await cache.epoch(owner: owner)
        guard let snapshot = await cache.read(owner: owner, url: url), !Task.isCancelled,
              context == token, root == nil, !loading, session.owner == owner, session.generation == generation else { return }
        root = url; sourceOwner = owner; sourceGeneration = generation; cacheEpoch = epoch
        items = filterFavorites(snapshot.items, since: snapshot.savedAt, session: session)
        categories = snapshot.categories; cachedAt = snapshot.savedAt
        next = snapshot.next.flatMap { SiteFavoriteOrder.continuation($0, from: url) }
    }

    private func applyQASnapshot(_ url: URL) {
        if url.path == "/favorites.php", ProcessInfo.processInfo.arguments.contains("--qa-favorite-sync-list") {
            let site = GallerySite.allCases.first { $0.host == url.host } ?? .ex
            items = NativeFavoritesQA.favorites(site: site)
            categories = Dictionary(uniqueKeysWithValues: NativeFavoritesQA.groups.enumerated().map { (String($0.offset), $0.element) })
            next = nil; return
        }
        items = QASamples.feedGalleries.filter { GalleryRatingFilter.includes($0, minimum: minimumRating) }
        categories = ["0": "常用", "1": "稍后阅读"]
        let finite = ProcessInfo.processInfo.arguments.contains("--qa-feed-performance") || ProcessInfo.processInfo.arguments.contains("--qa-search-sort")
        next = finite ? nil : URL(string: "https://exhentai.org/?qa-page=2")
    }

    func reset(url: URL, session: SiteSession, qa: Bool = false, replaceInFlight: Bool = false, preserveCachedPresentation: Bool = false) {
        let same = root == url && sourceOwner == session.owner && sourceGeneration == session.generation
        // Repeated pull-to-refresh while this root is already loading shares
        // that request instead of cancelling and adding another queue slot.
        if same && loading && activeURL == url && !replaceInFlight {
            // An explicit refresh promotes a background validation without
            // cancelling its request or consuming another search queue slot.
            if !preserveCachedPresentation { preservesCachedPresentation = false }
            return
        }
        let retained = same ? items : []
        let retainedNext = same ? next : nil
        cancel(); root = url; self.qa = qa && !FeedCacheQA.isEnabled; loaded = []; next = nil; failure = nil
        removedFavoriteIDs.removeAll()
        items = retained; if retained.isEmpty { categories = [:]; cachedAt = nil }
        sourceOwner = session.owner; sourceGeneration = session.generation; interrupted = false
        preservesCachedPresentation = preserveCachedPresentation
        if preserveCachedPresentation, !retained.isEmpty, cachedAt != nil { next = retainedNext }
        if self.qa { applyQASnapshot(url); return }
        let current = context, account = session.generation, owner = session.owner
        loading = true; activeURL = url; activePriority = .foreground; retryURL = url
        task = Task {
            if let cache {
                let epoch = await cache.epoch(owner: owner)
                let snapshot = retained.isEmpty ? await cache.read(owner: owner, url: url) : nil
                guard isCurrent(current, account: account, owner: owner, session: session), !Task.isCancelled else { return }
                cacheEpoch = epoch
                if let snapshot {
                    items = filterFavorites(snapshot.items, since: snapshot.savedAt, session: session)
                    next = snapshot.next.flatMap { SiteFavoriteOrder.continuation($0, from: url) }
                    categories = snapshot.categories; cachedAt = snapshot.savedAt
                }
            }
            let priority: SearchRequestPriority = items.isEmpty ? .foreground : .prefetch
            activePriority = priority
            await loadPage(url, session: session, current: current, account: account, owner: owner, priority: priority)
        }
    }
    func more(session: SiteSession, prefetch: Bool = false) {
        guard let next, !loading else { return }
        if qa {
            let current = context; loading = true; interrupted = false
            task = Task {
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled, current == context else { return }
                items += QASamples.additionalGalleries.filter { GalleryRatingFilter.includes($0, minimum: minimumRating) }; self.next = nil; loading = false; interrupted = false
            }
        } else { beginPage(next, session: session, priority: prefetch ? .prefetch : .foreground) }
    }
    /// Keep pull-to-refresh alive until its request (including enrichment) finishes.
    /// Repeated refreshes still share reset's in-flight root request.
    func waitForLoad() async { await task?.value }
    func retry(session: SiteSession) {
        if qa {
            guard !loading else { return }
            if items.isEmpty, let root { reset(url: root, session: session, qa: true) }
            else { more(session: session) }
        } else if let target = retryURL ?? next ?? root, !loading { beginPage(target, session: session, priority: .foreground) }
    }
    func invalidateFavoriteCache(owner: String) async {
        // Batch submission has no per-item confirmed membership. Preserve its
        // hard invalidation until the new server list verifies the result.
        let site = GallerySite.allCases.first { $0.host == root?.host }
        await cache?.invalidateFavorites(owner: owner, site: site, discardSnapshots: true)
    }
    func removeConfirmedFavorites(_ ids: Set<String>) {
        guard root?.path == "/favorites.php", !ids.isEmpty else { return }
        removedFavoriteIDs.formUnion(ids)
        if items.contains(where: { ids.contains($0.id) }) {
            items.removeAll { ids.contains($0.id) }
        }
    }
    private func prepareLaunchSnapshot(_ snapshot: FeedSnapshot, prepare: @escaping SnapshotCoverPreparation,
                                       current: UUID, account: UUID, owner: String, session: SiteSession) {
        snapshotPreparation?.cancel()
        let epoch = cacheEpoch, cache = cache
        snapshotPreparation = Task { [weak self] in
            let ready = await prepare(snapshot.items, owner)
            guard ready, !Task.isCancelled, let self,
                  self.isCurrent(current, account: account, owner: owner, session: session),
                  self.preservesCachedPresentation else { return }
            await cache?.save(snapshot, expectedEpoch: epoch)
        }
    }

    private func beginPage(_ url: URL, session: SiteSession, priority: SearchRequestPriority) {
        guard !loading, !loaded.contains(url), let root, URLPolicy.continuation(url, from: root),
              sourceOwner == session.owner, sourceGeneration == session.generation else { return }
        let current = context, account = session.generation, owner = session.owner
        loading = true; activeURL = url; activePriority = priority; retryURL = url
        failure = nil; interrupted = false
        task = Task { await loadPage(url, session: session, current: current, account: account, owner: owner, priority: priority) }
    }
    private func isCurrent(_ value: UUID, account: UUID, owner: String, session: SiteSession) -> Bool {
        value == context && account == session.generation && owner == session.owner
    }
    private func filterFavorites(_ galleries: [Gallery], since date: Date, session: SiteSession) -> [Gallery] {
        let favorites = root?.path == "/favorites.php"
        let category = root.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?
            .first(where: { $0.name == "favcat" })?.value.flatMap(Int.init)
        return galleries.filter {
            !removedFavoriteIDs.contains($0.id) && (!favorites ||
                session.favoriteStateCache.includesCachedFavorite(.init($0, session), category: category, savedAt: date))
        }
    }
    private func promoteVerifiedMetadata(_ resolved: [Gallery]) {
        let verified = Dictionary(resolved.filter(\.tagsComplete).map { ($0.ref, $0) }, uniquingKeysWith: { _, latest in latest })
        items = items.compactMap { old in
            guard !old.tagsComplete, let fresh = verified[old.ref] else { return old }
            if minimumRating != nil && GalleryRatingFilter.average(fresh.rating) == nil { return old }
            return GalleryRatingFilter.includes(fresh, minimum: minimumRating) ? fresh : nil
        }
    }

    private func loadMetadata(_ batch: [Gallery], session: SiteSession, priority: SearchRequestPriority) async throws -> [Gallery] {
        if let loadHTML {
            let json = try await loadHTML(SiteSession.metadataURL, false, GalleryMetadata.request(batch))
            return try GalleryMetadata.merge(Data(json.utf8), into: batch)
        }
        return try await session.galleryMetadata(batch, priority: priority == .prefetch ? .prefetch : .foreground)
    }

    private func loadPage(_ url: URL, session: SiteSession, current: UUID, account: UUID, owner: String, priority: SearchRequestPriority) async {
        defer {
            if current == context { loading = false; activeURL = nil; task = nil }
        }
        let requestedAt = Date()
        do {
            let html: String
            if let loadHTML { html = try await loadHTML(url, true, nil) }
            else { html = try await session.html(url, search: true, searchPriority: priority) }
            let parse = Task.detached(priority: .userInitiated) { try EHParser.list(html, base: url) }
            let list = try await withTaskCancellationHandler(operation: { try await parse.value }, onCancel: { parse.cancel() })
            guard isCurrent(current, account: account, owner: owner, session: session), !Task.isCancelled else { return }
            var pageBase = filterFavorites(list.items, since: requestedAt, session: session)
            session.favoriteStateCache.seedFavorites(pageBase, categories: list.favoriteCategories, url: root ?? url,
                                                    scopeOwner: owner, generation: account, observedAfter: requestedAt)
            let replacingRoot = url == root
            let validatingCachedRoot = replacingRoot && preservesCachedPresentation && cachedAt != nil && !items.isEmpty
            // Continuation URLs may omit filters; keep the original query's threshold.
            let minimum = minimumRating
            let publishFavoriteRoot = replacingRoot && root?.path == "/favorites.php" && minimum == nil
            let retainedRoot = replacingRoot && !items.isEmpty && !publishFavoriteRoot
            if !validatingCachedRoot { categories = list.favoriteCategories }
            if publishFavoriteRoot {
                let previous = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                // Rebase on the server's fresh order before waiting for metadata.
                // Reuse verified fields without claiming new items have complete tags.
                pageBase = pageBase.map { incoming in
                    guard let old = previous[incoming.id], old.tagsComplete else { return incoming }
                    var value = incoming
                    value.rating = old.rating
                    value.pages = incoming.pages ?? old.pages
                    value.tags = old.tags
                    value.tagsComplete = true
                    value.cover = incoming.cover ?? old.cover
                    return value
                }
                items = pageBase
                // HTML already contains the complete first page. Retain it if
                // metadata is slow or the view closes before enrichment ends.
                if let cache {
                    let cursor = root.flatMap { root in list.next.flatMap { SiteFavoriteOrder.continuation($0, from: root) } }
                    await cache.save(.init(owner: owner, root: url, items: pageBase, next: cursor, categories: categories), expectedEpoch: cacheEpoch)
                    guard isCurrent(current, account: account, owner: owner, session: session), !Task.isCancelled else { return }
                }
            }
            var unconfirmedRatings = false
            var metadataFailure: Error?
            var pageItems: [Gallery] = []
            if validatingCachedRoot {
                // The server's first page may have changed since this snapshot.
                // Resolve visible cached references too, rather than waiting forever
                // for those old IDs to reappear in the freshly fetched page.
                let incoming = Set(pageBase.map(\.ref))
                let missing = items.filter { !$0.tagsComplete && !incoming.contains($0.ref) }
                for offset in stride(from: 0, to: missing.count, by: 25) {
                    let batch = Array(missing[offset..<min(offset + 25, missing.count)])
                    do {
                        let resolved = try await loadMetadata(batch, session: session, priority: priority)
                        try Task.checkCancellation()
                        guard isCurrent(current, account: account, owner: owner, session: session) else { return }
                        if resolved.contains(where: { !$0.tagsComplete }) { metadataFailure = ViewerError.tagsUnavailable }
                        if minimum != nil, resolved.contains(where: { GalleryRatingFilter.average($0.rating) == nil }) { unconfirmedRatings = true }
                        promoteVerifiedMetadata(resolved)
                    } catch is CancellationError { throw CancellationError() }
                    catch { metadataFailure = error }
                }
            }
            for offset in stride(from: 0, to: pageBase.count, by: 25) {
                try Task.checkCancellation()
                let batch = Array(pageBase[offset..<min(offset + 25, pageBase.count)])
                let enriched: [Gallery]
                do {
                    enriched = try await loadMetadata(batch, session: session, priority: priority)
                } catch is CancellationError { throw CancellationError() }
                catch {
                    if minimum != nil { throw error }
                    enriched = batch
                    metadataFailure = error
                }
                if enriched.contains(where: { !$0.tagsComplete }) {
                    metadataFailure = metadataFailure ?? ViewerError.tagsUnavailable
                }
                try Task.checkCancellation()
                guard isCurrent(current, account: account, owner: owner, session: session) else { return }
                if minimum != nil, enriched.contains(where: { GalleryRatingFilter.average($0.rating) == nil }) {
                    unconfirmedRatings = true
                }
                let accepted = filterFavorites(enriched, since: requestedAt, session: session)
                    .filter { GalleryRatingFilter.includes($0, minimum: minimum) }
                pageItems += accepted
                if validatingCachedRoot {
                    // Preserve order/viewport, but let previously hidden unknown rows
                    // become usable once their tags are actually returned.
                    promoteVerifiedMetadata(enriched)
                }
                if replacingRoot, !retainedRoot, url.path == "/favorites.php", minimum == nil, let cache,
                   offset + batch.count < pageBase.count {
                    // Persist completed metadata batches before starting the next one.
                    // Leaving this page must not lose already verified tags/covers.
                    // Revalidation preserves the newly received server order while enriching it.
                    let completed = Dictionary(pageItems.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
                    let progress = filterFavorites(pageBase.map { completed[$0.id] ?? $0 }, since: requestedAt, session: session)
                    let cursor = list.next.flatMap { SiteFavoriteOrder.continuation($0, from: url) }
                    await cache.save(.init(owner: owner, root: url, items: progress, next: cursor, categories: categories), expectedEpoch: cacheEpoch)
                    guard isCurrent(current, account: account, owner: owner, session: session), !Task.isCancelled else { return }
                }
                if !retainedRoot {
                    var updated = items
                    var positions = Dictionary(uniqueKeysWithValues: updated.enumerated().map { ($0.element.id, $0.offset) })
                    for gallery in accepted {
                        if let index = positions[gallery.id] {
                            if !updated[index].tagsComplete && gallery.tagsComplete { updated[index] = gallery }
                        } else { positions[gallery.id] = updated.count; updated.append(gallery) }
                    }
                    items = updated
                }
            }
            try Task.checkCancellation()
            guard isCurrent(current, account: account, owner: owner, session: session) else { return }
            if unconfirmedRatings { throw ViewerError.ratingUnavailable }
            if let metadataFailure { throw metadataFailure }
            if validatingCachedRoot, preservesCachedPresentation {
                // Keep this presentation and its cursor together. A fresh
                // snapshot becomes visible on the next entry or explicit refresh.
                let cursor = list.next.flatMap { SiteFavoriteOrder.continuation($0, from: url) }
                let snapshot = FeedSnapshot(owner: owner, root: url, items: pageItems, next: cursor,
                                            categories: list.favoriteCategories)
                if let prepareSnapshotCovers {
                    prepareLaunchSnapshot(snapshot, prepare: prepareSnapshotCovers, current: current,
                                          account: account, owner: owner, session: session)
                } else {
                    await cache?.save(snapshot, expectedEpoch: cacheEpoch)
                }
                guard isCurrent(current, account: account, owner: owner, session: session), !Task.isCancelled else { return }
                // A refresh can arrive while the cache actor saves the result.
                if preservesCachedPresentation {
                    loaded.insert(url); retryURL = nil; interrupted = false
                    return
                }
            }
            if replacingRoot {
                pageItems = filterFavorites(pageItems, since: requestedAt, session: session)
                items = pageItems; cachedAt = nil
            }
            loaded.insert(url); retryURL = nil
            next = root.flatMap { root in
                list.next.flatMap { SiteFavoriteOrder.continuation($0, from: root) }
            }.flatMap { loaded.contains($0) ? nil : $0 }
            categories = list.favoriteCategories; interrupted = false
            if replacingRoot, let cache {
                await cache.save(.init(owner: owner, root: url, items: pageItems, next: next, categories: categories), expectedEpoch: cacheEpoch)
            }
        } catch is CancellationError { }
        catch {
            guard isCurrent(current, account: account, owner: owner, session: session) else { return }
            interrupted = false; failure = ErrorMessages.message(error, fallback: ViewerError.network.localizedDescription)
        }
    }
}
