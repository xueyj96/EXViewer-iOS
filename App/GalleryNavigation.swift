import SwiftUI
import ExViewerCore

/// Each gallery stack owns an explicit path, including cards mounted after a search.
/// Feed replacement cannot leave an implicit NavigationLink destination behind.
@MainActor final class GalleryNavigation: ObservableObject {
    @Published var path = NavigationPath()

    func open(_ gallery: Gallery, animated: Bool = true) {
        // These routes belong to list cards, not a chain of related details.
        // Ignore late/repeated activations once the list has a destination.
        guard path.isEmpty else { return }
        withAnimation(animated ? .default : nil) { path.append(gallery) }
    }
    func returnToList() {
        guard !path.isEmpty else { return }
        path = NavigationPath()
    }
}

private struct GalleryNavigationKey: EnvironmentKey {
    static let defaultValue: GalleryNavigation? = nil
}
extension EnvironmentValues {
    var galleryNavigation: GalleryNavigation? {
        get { self[GalleryNavigationKey.self] }
        set { self[GalleryNavigationKey.self] = newValue }
    }
}
