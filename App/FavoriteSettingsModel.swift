import SwiftUI
import ExViewerCore

extension SiteSession {
    func toggleSiteFavorite(_ gallery: Gallery) throws {
        guard hasCredentials || AppMode.qa else { throw ViewerError.authentication }
        let group = favoriteGroups.defaultGroup(owner: owner, site: gallery.ref.site)
        try favoriteStateCache.enqueueToggle(scope: .init(gallery, self), client: favoriteClient(for: gallery, session: self),
                                            group: group, groupName: favoriteGroups.name(group, owner: owner, site: gallery.ref.site), title: gallery.title)
    }

    @discardableResult func addToDefaultFavorites(_ galleries: [Gallery]) throws -> Int {
        guard hasCredentials || AppMode.qa else { throw ViewerError.authentication }
        // Persist all intents before any network work; each worker checks whether
        // the gallery is already favorited and preserves its existing category.
        let additions = galleries.map { gallery in
            let site = gallery.ref.site
            let group = favoriteGroups.defaultGroup(owner: owner, site: site)
            return SiteFavoriteCache.BatchAddition(scope: .init(gallery, self), client: favoriteClient(for: gallery, session: self),
                                                   title: gallery.title, groupName: favoriteGroups.name(group, owner: owner, site: site),
                                                   group: group)
        }
        return try favoriteStateCache.enqueueAdditions(additions, group: 0)
    }

}

@MainActor final class FavoriteSettingsModel: ObservableObject {
    @Published private(set) var loading = false
    @Published private(set) var saving = false
    @Published private(set) var loaded = false
    @Published private(set) var error: String?
    let site: GallerySite
    private let session: SiteSession
    private let owner: String
    private let generation: UUID
    private let client: FavoriteSettingsClient
    private var requestEpoch = UUID()
    var isCurrent: Bool { owner == session.owner && generation == session.generation && client.isCurrent() }
    var defaultGroup: Int { session.favoriteGroups.defaultGroup(owner: owner, site: site) }
    func groupName(_ group: Int) -> String { session.favoriteGroups.name(group, owner: owner, site: site) }
    func setDefaultGroup(_ group: Int) {
        guard isCurrent else { return }
        session.favoriteGroups.setDefault(group, owner: owner, site: site)
    }

    init(site: GallerySite, session: SiteSession, client: FavoriteSettingsClient? = nil) {
        self.site = site; self.session = session; owner = session.owner; generation = session.generation
        self.client = client ?? .live(site: site, session: session)
    }

    func load() async {
        guard isCurrent, !loading, !saving else { return }
        let epoch = UUID(); requestEpoch = epoch; loading = true
        defer { if requestEpoch == epoch { loading = false } }
        do {
            let form = try await client.read()
            guard isCurrent, requestEpoch == epoch, !Task.isCancelled else { return }
            try await applyConfirmedNames(form)
            guard isCurrent, requestEpoch == epoch else { return }
            loaded = true; error = nil
        } catch is CancellationError { return }
        catch { if isCurrent, requestEpoch == epoch { self.error = ErrorMessages.message(error, fallback: "收藏分组未能读取") } }
    }

    func rename(_ group: Int, to name: String) async -> Bool {
        guard isCurrent, !saving else { return false }
        // Saving supersedes any refresh that was already in flight.
        requestEpoch = UUID(); loading = false; saving = true; error = nil
        defer { saving = false }
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let form = try await client.read()
            let request = try form.requestRenaming(group: group, to: value)
            guard isCurrent, !Task.isCancelled else { throw ViewerError.stale }
            if form.names[group] == value {
                try await applyConfirmedNames(form)
                return true
            }
            // Exactly one POST; even a lost response is resolved by a GET.
            do { try await client.submit(request) }
            catch { guard isCurrent, !Task.isCancelled else { throw ViewerError.stale } }
            let confirmed = try await client.read()
            guard isCurrent, !Task.isCancelled else { throw ViewerError.stale }
            try await applyConfirmedNames(confirmed)
            guard confirmed.names[group] == value else {
                throw ViewerError.invalidQuery("改名结果待确认 请刷新检查")
            }
            return true
        } catch {
            if isCurrent { self.error = ErrorMessages.message(error, fallback: "改名结果待确认 请刷新检查") }
            return false
        }
    }

    private func applyConfirmedNames(_ form: FavoriteSettingsForm) async throws {
        guard isCurrent, form.site == site else { throw ViewerError.stale }
        let previous = session.favoriteGroups.names(owner: owner, site: site) ?? form.names
        // Persist the cache migration first: failed storage must not destroy the
        // old name mapping required by a later retry.
        try session.favoriteStateCache.updateGroupNames(site: site, before: previous, after: form.names)
        session.favoriteGroups.setNames(form.names, owner: owner, site: site)
        await FeedSnapshotCache.shared.invalidateFavorites(owner: owner)
        guard isCurrent else { throw ViewerError.stale }
        session.favoriteChanged()
    }
}
