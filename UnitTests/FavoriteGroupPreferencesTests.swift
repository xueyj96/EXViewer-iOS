import XCTest
import ExViewerCore
@testable import ExViewer

@MainActor final class FavoriteGroupPreferencesTests: XCTestCase {
    func testDefaultAndNamesRemainScopedToAccountAndSiteAcrossReload() {
        let suite = "FavoriteGroupPreferencesTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = FavoriteGroupPreferences(defaults: defaults)
        XCTAssertEqual(preferences.defaultGroup(owner: "one", site: .ex), 0)
        preferences.setDefault(7, owner: "one", site: .ex)
        preferences.setNames((0...9).map { "Group \($0)" }, owner: "one", site: .ex)
        let restored = FavoriteGroupPreferences(defaults: defaults)
        XCTAssertEqual(restored.defaultGroup(owner: "one", site: .ex), 7)
        XCTAssertEqual(restored.defaultGroup(owner: "one", site: .eh), 0)
        XCTAssertEqual(restored.defaultGroup(owner: "two", site: .ex), 0)
        XCTAssertEqual(restored.name(7, owner: "one", site: .ex), "Group 7")
        XCTAssertEqual(restored.name(7, owner: "two", site: .ex), "分组 8")
        restored.setDefault(10, owner: "one", site: .ex)
        XCTAssertEqual(restored.defaultGroup(owner: "one", site: .ex), 7)
    }
}
