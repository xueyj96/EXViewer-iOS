import Foundation
import ExViewerCore

/// Transport boundary shared by settings and deterministic failure-path tests.
@MainActor struct FavoriteSettingsClient {
    var isCurrent: () -> Bool
    var read: () async throws -> FavoriteSettingsForm
    var submit: (GalleryFavoriteRequest) async throws -> Void

    static func live(site: GallerySite, session: SiteSession) -> Self {
        let owner = session.owner, generation = session.generation
        let current = { session.owner == owner && session.generation == generation }
        return Self(isCurrent: current, read: {
            guard current() else { throw ViewerError.stale }
            if AppMode.qa { return try FavoriteSettingsForm.read(NativeFavoritesQA.settingsHTML(site: site), site: site) }
            guard session.hasCredentials else { throw ViewerError.authentication }
            return try FavoriteSettingsForm.read(await session.html(FavoriteSettingsForm.endpoint(for: site)), site: site)
        }, submit: { request in
            guard current() else { throw ViewerError.stale }
            if AppMode.qa {
                let items = URLComponents(string: "https://example.invalid/?" + String(decoding: request.body, as: UTF8.self).replacingOccurrences(of: "+", with: "%20"))?.queryItems ?? []
                for index in 0...9 {
                    if let value = items.first(where: { $0.name == "favorite_\(index)" })?.value {
                        NativeFavoritesQA.renameGroup(index, name: value, site: site)
                    }
                }
                return
            }
            guard session.hasCredentials else { throw ViewerError.authentication }
            try EHParser.check(await session.html(request.url, method: "POST", body: request.body))
        })
    }
}
