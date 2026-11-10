import SwiftUI
import UIKit
import ExViewerCore

enum AppMode {
    static var qa: Bool {
        #if DEBUG && targetEnvironment(simulator)
        return ProcessInfo.processInfo.arguments.contains("--qa")
        #else
        return false
        #endif
    }
    static var screen: String {
        let arguments = ProcessInfo.processInfo.arguments
        guard qa, let index = arguments.firstIndex(of: "--screen"), arguments.indices.contains(index + 1) else { return "browse" }
        return arguments[index + 1]
    }
}
enum Palette {
    static let accent = Color(uiColor: .systemBlue)
    static let background = Color(uiColor: .systemGroupedBackground)
    static let inputPrompt = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark { return UIColor.secondaryLabel.resolvedColor(with: traits) }
        return UIColor(white: 0.36, alpha: 1)
    })
}

private struct AppVisualEnvironment: ViewModifier {
    func body(content: Content) -> some View {
        let arguments = ProcessInfo.processInfo.arguments
        // Installed builds use a fixed text size. Keep the explicit QA override for layout regression tests.
        let textSize: DynamicTypeSize = AppMode.qa && arguments.contains("--qa-large-type") ? .accessibility2 : .large
        content
            .dynamicTypeSize(textSize)
            .preferredColorScheme(AppMode.qa && arguments.contains("--qa-dark") ? .dark : nil)
    }
}

private enum BrowserPreferenceDefaults {
    static let suite = "ExViewer.Browser.QA"
    static let store: UserDefaults = AppMode.qa ? UserDefaults(suiteName: suite)! : .standard
}

@main struct ExViewerApp: App {
    @StateObject private var session: SiteSession
    @StateObject private var library: LibraryStore
    @StateObject private var downloads: DownloadManager
    @Environment(\.scenePhase) private var scenePhase
    init() {
        if AppMode.qa && ProcessInfo.processInfo.arguments.contains("--qa-reset-library-sort") {
            UserDefaults(suiteName: LibrarySortPreferences.qaSuite)?.removePersistentDomain(forName: LibrarySortPreferences.qaSuite)
        }
        if AppMode.qa && !ProcessInfo.processInfo.arguments.contains("--qa-keep-site-preference") {
            BrowserPreferenceDefaults.store.set(GallerySite.ex.rawValue, forKey: "browser.site")
        }
        if AppMode.qa && ProcessInfo.processInfo.arguments.contains("--qa-reset-reader-preferences") {
            UserDefaults(suiteName: "ExViewer.Reader.QA")?.removePersistentDomain(forName: "ExViewer.Reader.QA")
        }
        let session = SiteSession(qa: AppMode.qa), library = LibraryStore(qa: AppMode.qa)
        library.load(owner: session.owner)
        if AppMode.qa && ProcessInfo.processInfo.arguments.contains("--qa-saved-search-management") {
            for saved in QASamples.savedSearches {
                library.saveSearch(name: saved.name, site: saved.site, query: saved.query)
            }
        }
        if AppMode.qa && ProcessInfo.processInfo.arguments.contains("--qa-stored-bookmark-covers") {
            for gallery in QASamples.galleries.prefix(3) { library.bookmark(gallery) }
            library.remember(QASamples.galleries[0], page: 2)
            library.load(owner: session.owner)
        }
        if AppMode.qa && ProcessInfo.processInfo.arguments.contains("--qa-offline-layout") {
            QASamples.installOfflineSample(in: library)
        }
        if AppMode.qa && ProcessInfo.processInfo.arguments.contains("--qa-failed-download") {
            let gallery = QASamples.galleries[0]
            library.updateDownload(.init(gallery: gallery, status: .failed, completed: [1: "page-1.media"],
                                         total: gallery.pages, error: "站点请求过于频繁（429），请稍后重试。"))
        }
        _session = StateObject(wrappedValue: session); _library = StateObject(wrappedValue: library)
        _downloads = StateObject(wrappedValue: DownloadManager(session: session, library: library,
                                                               backgroundWork: AppMode.qa ? nil : BackgroundWork()))
    }
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(session).environmentObject(library).environmentObject(downloads).tint(Palette.accent)
                .modifier(AppVisualEnvironment())
                .overlay { SelectionPerformanceProbeInstaller() }
                .task {
                    if scenePhase == .active { downloads.resumeQueuedDownloads() }
                    if !AppMode.qa && session.hasCredentials { await session.verify() }
                }
                .onChange(of: session.generation) { _, _ in
                    Self.applySessionChange(session: session, library: library, downloads: downloads)
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { downloads.resumeQueuedDownloads() }
                    else if phase == .background { downloads.suspendForBackground() }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in ReaderImagePipeline.shared.clearCache() }
        }
    }

    @MainActor static func applySessionChange(session: SiteSession, library: LibraryStore, downloads: DownloadManager) {
        // Persist the old account's download progress before replacing its snapshot.
        downloads.pauseAll()
        if library.owner != session.owner { library.load(owner: session.owner) }
    }
}

struct RootView: View {

    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var session: SiteSession
    @EnvironmentObject private var library: LibraryStore
    @State private var selection = AppMode.screen == "tags" || AppMode.screen == "account" ? 2 : 0
    @StateObject private var discovery: DiscoveryNavigation
    @AppStorage("browser.site", store: BrowserPreferenceDefaults.store) private var browserSiteRaw = GallerySite.ex.rawValue
    @State private var discoveryPath = NavigationPath()
    @State private var showsDiscoveryHistory = false
    @State private var libraryPath = NavigationPath()
    @State private var accountPath = NavigationPath()

    init() {
        let storedSite = BrowserPreferenceDefaults.store.string(forKey: "browser.site")
        let site = storedSite.flatMap(GallerySite.init(rawValue:)) ?? .ex
        _discovery = StateObject(wrappedValue: DiscoveryNavigation(site: site))
    }

    private var browserSite: GallerySite {
        get { GallerySite(rawValue: browserSiteRaw) ?? .ex }
        nonmutating set { browserSiteRaw = newValue.rawValue }
    }
    private var browserSiteBinding: Binding<GallerySite> {
        Binding(get: { browserSite }, set: { browserSite = $0 })
    }
    private var settingsSiteBinding: Binding<GallerySite> {
        Binding(get: { browserSite }, set: { newSite in
            guard newSite != browserSite else { return }
            executeDiscovery(discovery.current.query, site: newSite, savedID: discovery.current.savedID)
        })
    }
    var body: some View {
        CompactMainTabs(selection: $selection) {
            TabView(selection: $selection) {
                NavigationStack(path: $discoveryPath) {
                    DiscoverView(navigation: discovery, showsReadingHistory: $showsDiscoveryHistory, onSiteChange: { browserSite = $0 })
                        .navigationDestination(for: Gallery.self) { gallery in
                            let origin: DetailTagSearchDraft.Origin = showsDiscoveryHistory || discoveryPath.count > 1 ? .discoverSearch : .currentSearch
                            GalleryDetailView(gallery: gallery, searchTarget: searchTarget(origin))
                        }
                }
                .toolbar(.hidden, for: .tabBar)
                .suppressPinnedChromePreferences(selection != 0)
                .tabItem { Label("发现", systemImage: "square.grid.2x2") }.tag(0)
                NavigationStack(path: $libraryPath) {
                    LibraryView(site: browserSiteBinding, isActive: selection == 1)
                        .navigationDestination(for: Gallery.self) { gallery in
                            GalleryDetailView(gallery: gallery, searchTarget: searchTarget(.discoverSearch))
                        }
                }
                .toolbar(.hidden, for: .tabBar)
                .suppressPinnedChromePreferences(selection != 1)
                .tabItem { Label("资料库", systemImage: "books.vertical") }.tag(1)
                NavigationStack(path: $accountPath) {
                    AccountView(site: settingsSiteBinding) { useTag($0, browserSite) }
                }
                .toolbar(.hidden, for: .tabBar)
                .suppressPinnedChromePreferences(selection != 2)
                .tabItem { Label("我的", systemImage: "person.crop.circle") }.tag(2)
            }
            .galleryDetailPresentations(inlineSearch: true, tab: selection)
        }
        .id(session.generation)
        .overlay(alignment: .bottom) {
            if let notice = library.readLaterNotice {
                Text(notice.text).font(FeedChrome.labelFont).padding(.horizontal, 16).padding(.vertical, 10)
                    .background(FloatingChrome.background, in: AppShape.control).padding(.bottom, 68)
                    .allowsHitTesting(false).accessibilityIdentifier("read-later.feedback")
                    .task(id: notice.id) {
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        guard !Task.isCancelled else { return }; library.dismissReadLaterNotice(notice.id)
                    }
            }
        }
        .onChange(of: session.generation) { _, _ in
            discoveryPath = NavigationPath(); libraryPath = NavigationPath(); accountPath = NavigationPath()
            discovery.reset(query: discovery.current.query, site: browserSite, savedID: discovery.current.savedID)
        }
        .onChange(of: session.owner) { _, _ in
            discovery.reset(site: browserSite)
            selection = 0
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { session.favoriteStateCache.refreshActive() } }
        .sheet(isPresented: .constant(AppMode.screen == "reader" || AppMode.screen == "web-compat")) {
            if AppMode.screen == "web-compat" { WebCompatibilityQAView() }
            else { ReaderView(gallery: QASamples.galleries[0]) }
        }
    }
    private func useTag(_ tag: GalleryTag, _ sourceSite: GallerySite) {
        var query = discovery.current.query
        if tag.namespace == "artist" {
            query = SearchQuery()
            query.replaceArtist(tag.name)
        } else {
            query.rules.removeAll { $0.id == tag.id }; query.rules.append(.init(tag: tag))
        }
        executeDiscovery(query, site: sourceSite, savedID: nil)
        showDiscovery(discovery.current.site)
    }

    private func executeDiscovery(_ query: SearchQuery, site: GallerySite, savedID: UUID?) {
        do {
            try discovery.execute(query: query, site: site, savedID: savedID, session: session, library: library)
            browserSite = discovery.current.site
        } catch {
            discovery.report(error)
        }
    }

    private func searchTarget(_ origin: DetailTagSearchDraft.Origin) -> DetailSearchTarget? {
        DetailSearchTarget(navigation: discovery, generation: session.generation, origin: origin, showResults: showDiscovery)
    }

    private func showDiscovery(_ site: GallerySite) {
        browserSite = site
        showsDiscoveryHistory = false
        discoveryPath = NavigationPath()
        selection = 0
    }
}

struct StatusMessage: View {
    var title: String
    var symbol = "exclamationmark.circle"
    var action: (() -> Void)?
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 28, weight: .light)).foregroundStyle(.secondary)
            Text(title).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let action { Button("重试", action: action).buttonStyle(AppActionButtonStyle()) }
        }.frame(maxWidth: .infinity).padding(28)
    }
}
