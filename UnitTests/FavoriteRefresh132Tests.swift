import XCTest
import ExViewerCore
@testable import ExViewer

@MainActor final class FavoriteRefresh132Tests: XCTestCase {
    private let reference = GalleryRef(site: .ex, gid: 132, token: "fixture")
    private func form(_ group: Int?) throws -> GalleryFavoriteForm {
        try GalleryFavoriteForm.read(NativeFavoritesQA.html(reference: reference, group: group, note: ""), reference: reference)
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 { if condition() { return }; try await Task.sleep(nanoseconds: 2_000_000) }
        XCTFail("Favorite worker did not reach the expected state")
    }
    func testRepeatedDirectTogglesKeepTheLatestOptimisticIntentWhileReadIsHeld() async throws {
        for taps in [2, 3] {
            let cache = SiteFavoriteCache(), scope = GalleryFavoriteScope(reference: reference, owner: "aa", generation: UUID())
            cache.activate(owner: scope.owner, generation: scope.generation)
            var held: CheckedContinuation<GalleryFavoriteForm, Error>?
            var first = true, serverGroup: Int?, posts = 0
            let client = GalleryFavoriteClient(isCurrent: { true }, read: {
                if first { first = false; return try await withCheckedThrowingContinuation { held = $0 } }
                return try self.form(serverGroup)
            }, submit: { request in
                posts += 1
                let fields = URLComponents(string: "https://example.invalid/?" + String(decoding: request.body, as: UTF8.self))!.queryItems!
                serverGroup = Int(fields.first { $0.name == "favcat" }!.value!)
            })
            for tap in 1...taps {
                try cache.enqueueToggle(scope: scope, client: client, group: 2, groupName: NativeFavoritesQA.groups[2], title: "Fixture")
                XCTAssertEqual(cache.entry(scope)?.state, tap.isMultiple(of: 2) ? .notFavorited : .favorited(NativeFavoritesQA.groups[2]))
                if tap == 1 { try await wait { held != nil } }
            }
            held?.resume(returning: try form(nil)); held = nil
            try await wait { cache.entry(scope)?.phase == nil }
            XCTAssertEqual(serverGroup, taps == 2 ? nil : 2)
            XCTAssertEqual(posts, taps == 2 ? 0 : 1)
        }
    }

    func testAlreadySatisfiedAdditionPublishesAListRefreshWithoutPosting() async throws {
        let cache = SiteFavoriteCache(), scope = GalleryFavoriteScope(reference: reference, owner: "aa", generation: UUID())
        cache.activate(owner: scope.owner, generation: scope.generation)
        var posts = 0, notifications = 0
        let client = GalleryFavoriteClient(isCurrent: { true }, read: { try self.form(2) }, submit: { _ in posts += 1 }, didSubmit: { notifications += 1 })
        _ = try cache.enqueueAdditions([.init(scope: scope, client: client, title: "Fixture", groupName: "Group", group: 2)], group: 2)
        try await wait { cache.entry(scope)?.phase == nil }
        XCTAssertEqual(posts, 0); XCTAssertEqual(notifications, 1)
        XCTAssertEqual(cache.entry(scope)?.state, .favorited(NativeFavoritesQA.groups[2]))
    }
    func testDelayedConfirmationPublishesAnotherRefreshWithoutAnotherPost() async throws {
        let cache = SiteFavoriteCache(), scope = GalleryFavoriteScope(reference: reference, owner: "aa", generation: UUID())
        cache.activate(owner: scope.owner, generation: scope.generation)
        var reads = 0, posts = 0, notifications = 0
        let client = GalleryFavoriteClient(isCurrent: { true }, read: {
            reads += 1
            if reads == 2 { throw URLError(.timedOut) }
            return try self.form(reads == 1 ? nil : 2)
        }, submit: { _ in posts += 1 }, didSubmit: { notifications += 1 })
        _ = try cache.enqueueAdditions([.init(scope: scope, client: client, title: "Fixture", groupName: "Group", group: 2)], group: 2)
        try await wait { cache.entry(scope)?.phase == .uncertain }
        XCTAssertEqual(posts, 1); XCTAssertEqual(notifications, 1)
        cache.check(reference.id)
        try await wait { cache.entry(scope)?.phase == nil }
        XCTAssertEqual(posts, 1); XCTAssertEqual(notifications, 2)
    }
}
