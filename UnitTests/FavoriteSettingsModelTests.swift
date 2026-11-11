import XCTest
import ExViewerCore
@testable import ExViewer

@MainActor final class FavoriteSettingsModelTests: XCTestCase {
    private final class Server {
        var names = (0...9).map { "Group \($0)" }
        var reads = 0, posts = 0
        var failures = Set<Int>()
        var holdRead: Int?
        var held: CheckedContinuation<Void, Never>?
        var lostReply = false
        var current = true
        func form() throws -> FavoriteSettingsForm {
            let fields = names.enumerated().map { "<input name='favorite_\($0)' value='\($1)' maxlength='20'>" }.joined()
            return try .read("<form method='post'>\(fields)<input type='submit' name='apply' value='Apply'></form>", site: .ex)
        }
        var client: FavoriteSettingsClient {
            .init(isCurrent: { self.current }, read: {
                self.reads += 1; let number = self.reads, form = try self.form()
                if number == self.holdRead { await withCheckedContinuation { self.held = $0 } }
                if self.failures.contains(number) { throw URLError(.timedOut) }
                return form
            }, submit: { request in
                self.posts += 1
                let query = String(decoding: request.body, as: UTF8.self).replacingOccurrences(of: "+", with: "%20")
                let fields = URLComponents(string: "https://example.invalid/?" + query)!.queryItems!
                for index in 0...9 { self.names[index] = fields.first { $0.name == "favorite_\(index)" }!.value! }
                if self.lostReply { throw URLError(.networkConnectionLost) }
            })
        }
    }
    private var suite = ""
    override func setUp() { super.setUp(); suite = "FavoriteSettingsModelTests." + UUID().uuidString }
    override func tearDown() { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite); super.tearDown() }
    private func session(cache: SiteFavoriteCache? = nil) -> SiteSession {
        SiteSession(qa: true, favoriteCache: cache, favoritePreferences: FavoriteGroupPreferences(defaults: UserDefaults(suiteName: suite)!))
    }
    private func waitForRead(_ server: Server) async throws {
        for _ in 0..<100 where server.held == nil { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertNotNil(server.held)
    }
    private let reference = GalleryRef(site: .ex, gid: 456, token: "fixture")

    func testLostPostReplyThenFailedReadbackAndSameNameRetryConvergeAllLocalState() async throws {
        let session = session(), server = Server()
        let scope = GalleryFavoriteScope(reference: reference, owner: session.owner, generation: session.generation)
        session.favoriteGroups.setNames(server.names, owner: session.owner, site: .ex)
        session.favoriteStateCache.put(.favorited("Group 2"), scope: scope)
        let model = FavoriteSettingsModel(site: .ex, session: session, client: server.client)
        server.lostReply = true; server.failures = [2]
        let first = await model.rename(2, to: "Reading")
        XCTAssertFalse(first); XCTAssertEqual(server.posts, 1)
        XCTAssertEqual(session.favoriteGroups.name(2, owner: session.owner, site: .ex), "Group 2")
        let retry = await model.rename(2, to: "Reading")
        XCTAssertTrue(retry); XCTAssertEqual(server.posts, 1, "Confirmed same-name retry must not POST again")
        XCTAssertEqual(session.favoriteStateCache.entry(scope)?.state, .favorited("Reading"))
        XCTAssertEqual(session.favoriteGroups.name(2, owner: session.owner, site: .ex), "Reading")
    }

    func testOlderLoadCannotOverwriteConfirmedRename() async throws {
        let session = session(), server = Server()
        session.favoriteGroups.setNames(server.names, owner: session.owner, site: .ex)
        let model = FavoriteSettingsModel(site: .ex, session: session, client: server.client)
        server.holdRead = 1
        let loading = Task { await model.load() }
        try await waitForRead(server)
        let saved = await model.rename(2, to: "Reading")
        XCTAssertTrue(saved)
        server.held?.resume(); server.held = nil; await loading.value
        XCTAssertEqual(model.groupName(2), "Reading"); XCTAssertFalse(model.loading)
    }

    func testRefreshingExternallyRenamedGroupsAlsoMigratesCache() async throws {
        let session = session(), server = Server()
        let scope = GalleryFavoriteScope(reference: reference, owner: session.owner, generation: session.generation)
        session.favoriteGroups.setNames(server.names, owner: session.owner, site: .ex)
        session.favoriteStateCache.put(.favorited("Group 2"), scope: scope)
        server.names[2] = "External"
        let model = FavoriteSettingsModel(site: .ex, session: session, client: server.client)
        await model.load()
        XCTAssertTrue(model.loaded); XCTAssertNil(model.error)
        XCTAssertEqual(session.favoriteStateCache.entry(scope)?.state, .favorited("External"))
        XCTAssertEqual(server.posts, 0)
    }

    func testStorageFailureKeepsOldMappingForSameNameRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1]).write(to: root)
        let cache = SiteFavoriteCache(storageRoot: root), session = session(cache: cache), server = Server()
        let scope = GalleryFavoriteScope(reference: reference, owner: session.owner, generation: session.generation)
        session.favoriteGroups.setNames(server.names, owner: session.owner, site: .ex)
        cache.put(.favorited("Group 2"), scope: scope)
        let model = FavoriteSettingsModel(site: .ex, session: session, client: server.client)
        let failed = await model.rename(2, to: "Reading")
        XCTAssertFalse(failed); XCTAssertEqual(model.groupName(2), "Group 2")
        try FileManager.default.removeItem(at: root)
        let saved = await model.rename(2, to: "Reading")
        XCTAssertTrue(saved); XCTAssertEqual(server.posts, 1)
        XCTAssertEqual(cache.entry(scope)?.state, .favorited("Reading"))
    }

    func testStaleClientCannotChangeDefaultOrPublishNames() async throws {
        let session = session(), server = Server()
        let model = FavoriteSettingsModel(site: .ex, session: session, client: server.client)
        server.holdRead = 1
        let loading = Task { await model.load() }
        try await waitForRead(server); server.current = false
        model.setDefaultGroup(4)
        server.held?.resume(); server.held = nil; await loading.value
        XCTAssertEqual(model.defaultGroup, 0)
        XCTAssertNil(session.favoriteGroups.names(owner: session.owner, site: .ex))
        let saved = await model.rename(2, to: "Reading")
        XCTAssertFalse(saved); XCTAssertEqual(server.posts, 0)
    }
}
