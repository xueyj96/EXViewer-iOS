import SwiftUI
import ExViewerCore

@MainActor final class FavoriteGroupPreferences: ObservableObject {
    @Published private(set) var revision = UUID()
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func key(_ owner: String, _ site: GallerySite, _ field: String) -> String {
        "favorites.groups.\(owner).\(site.rawValue).\(field)"
    }

    func defaultGroup(owner: String, site: GallerySite) -> Int {
        let value = defaults.integer(forKey: key(owner, site, "default"))
        return (0...9).contains(value) ? value : 0
    }

    func setDefault(_ group: Int, owner: String, site: GallerySite) {
        guard (0...9).contains(group) else { return }
        defaults.set(group, forKey: key(owner, site, "default"))
        revision = UUID()
    }

    func names(owner: String, site: GallerySite) -> [String]? {
        guard let values = defaults.stringArray(forKey: key(owner, site, "names")), values.count == 10 else { return nil }
        return values
    }

    func name(_ group: Int, owner: String, site: GallerySite) -> String {
        guard (0...9).contains(group), let names = names(owner: owner, site: site), !names[group].isEmpty else {
            return "分组 \(group + 1)"
        }
        return names[group]
    }

    func setNames(_ names: [String], owner: String, site: GallerySite) {
        guard names.count == 10 else { return }
        defaults.set(names, forKey: key(owner, site, "names"))
        revision = UUID()
    }
}
