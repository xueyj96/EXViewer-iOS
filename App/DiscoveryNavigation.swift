import Foundation
import Combine
import ExViewerCore

@MainActor final class DiscoveryEntry: ObservableObject, Identifiable {
    let id = UUID()
    let query: SearchQuery
    let site: GallerySite
    let lane: Int
    let savedID: UUID?
    let requestURL: URL
    let pager: GalleryPager
    @Published var scrollAnchor: String?
    private(set) var didStart = false

    init(query: SearchQuery, site: GallerySite, lane: Int, savedID: UUID?, requestURL: URL, scrollAnchor: String? = nil, pager: GalleryPager? = nil) {
        self.query = query
        self.site = site
        self.lane = lane
        self.savedID = savedID
        self.requestURL = requestURL
        self.scrollAnchor = scrollAnchor
        self.pager = pager ?? GalleryPager()
    }

    func markStarted() { didStart = true }

    func updateVisibleAnchor(_ anchor: String) {
        guard scrollAnchor != anchor else { return }
        scrollAnchor = anchor
    }
}

/// Keeps one active feed and a bounded in-memory trail of paused feeds.
@MainActor final class DiscoveryNavigation: ObservableObject {
    static let historyLimit = 32
    @Published private(set) var current: DiscoveryEntry
    @Published private(set) var history: [DiscoveryEntry] = []
    @Published private(set) var forwardHistory: [DiscoveryEntry] = []
    @Published var submissionError: String?
    var canGoBack: Bool { !history.isEmpty }
    var canGoBackToSearch: Bool { history.contains { $0.query.hasSettings } }
    var canGoForward: Bool { !forwardHistory.isEmpty }

    init(query: SearchQuery = SearchQuery(), site: GallerySite = .ex, lane: Int = 0, savedID: UUID? = nil) {
        current = Self.initialEntry(query: query, site: site, lane: lane, savedID: savedID)
    }

    private static func initialEntry(query: SearchQuery, site: GallerySite, lane: Int, savedID: UUID?) -> DiscoveryEntry {
        let url = (try? Self.requestURL(query: query, site: site, lane: lane)) ?? (try! SearchQuery().url(site: site))
        return DiscoveryEntry(query: query, site: site, lane: lane, savedID: savedID, requestURL: url)
    }

    func reset(query: SearchQuery = SearchQuery(), site: GallerySite, savedID: UUID? = nil) {
        cancelLoading()
        history.removeAll()
        forwardHistory.removeAll()
        submissionError = nil
        current = Self.initialEntry(query: query, site: site, lane: 0, savedID: savedID)
    }

    func cancelLoading() {
        current.pager.cancel()
        for entry in history + forwardHistory { entry.pager.cancel() }
    }

    func execute(query: SearchQuery, site: GallerySite, lane: Int? = nil, savedID: UUID?, session: SiteSession, library: LibraryStore) throws {
        try submit(query: query, site: site, lane: lane ?? current.lane, savedID: savedID, session: session, qa: AppMode.qa)
        library.recordSearch(query: current.query, site: current.site)
        submissionError = nil
    }

    func report(_ error: Error) {
        submissionError = (error as? LocalizedError)?.errorDescription ?? "搜索条件无效"
    }

    func startCurrent(session: SiteSession, qa: Bool) throws {
        guard !current.didStart else { return }
        let url = try Self.requestURL(query: current.query, site: current.site, lane: current.lane)
        guard url == current.requestURL else { throw ViewerError.invalidQuery("搜索未能开始 请重试") }
        current.markStarted()
        current.pager.reset(url: url, session: session, qa: qa, preserveCachedPresentation: !current.query.hasSettings)
    }

    /// Prepare a presentation owner without starting a request or changing the trail.
    /// The exact object can then be committed after an accepted section gesture.
    func preparedEntry(query: SearchQuery, site: GallerySite, lane: Int, savedID: UUID? = nil) throws -> DiscoveryEntry {
        let url = try Self.requestURL(query: query, site: site, lane: lane)
        if let existing = ([current] + history + forwardHistory).first(where: {
            $0.requestURL == url && $0.query == query && $0.site == site && $0.lane == lane && $0.savedID == savedID
        }) { return existing }
        let sameFeed = current.requestURL == url
        let prepared = DiscoveryEntry(query: query, site: site, lane: lane, savedID: savedID, requestURL: url,
                                      scrollAnchor: sameFeed ? current.scrollAnchor : nil,
                                      pager: sameFeed ? current.pager : nil)
        if sameFeed && current.didStart { prepared.markStarted() }
        return prepared
    }

    /// Validates before changing history. Identical URLs reuse the current feed
    /// and replace only immutable presentation/saved-search metadata.
    @discardableResult
    func submit(query: SearchQuery, site: GallerySite, lane: Int, savedID: UUID?, session: SiteSession, qa: Bool, prepared: DiscoveryEntry? = nil) throws -> Bool {
        let url = try Self.requestURL(query: query, site: site, lane: lane)
        if let prepared {
            guard prepared.requestURL == url, prepared.query == query, prepared.site == site,
                  prepared.lane == lane, prepared.savedID == savedID else { throw ViewerError.stale }
        }
        if current.requestURL == url {
            if current.query == query, current.site == site, current.lane == lane, current.savedID == savedID {
                if !current.didStart { current.markStarted(); current.pager.reset(url: url, session: session, qa: qa, preserveCachedPresentation: !current.query.hasSettings) }
                return false
            }
            let old = current
            let replacement = prepared ?? DiscoveryEntry(query: query, site: site, lane: lane, savedID: savedID, requestURL: url,
                                             scrollAnchor: old.scrollAnchor,
                                             pager: old.pager)
            if old.didStart { replacement.markStarted() }
            current = replacement
            if !replacement.didStart {
                replacement.markStarted()
                replacement.pager.reset(url: url, session: session, qa: qa, preserveCachedPresentation: !replacement.query.hasSettings)
            }
            return false
        }

        let matches: (DiscoveryEntry) -> Bool = {
            $0.requestURL == url && $0.query == query && $0.site == site && $0.lane == lane && $0.savedID == savedID
        }
        let reusable: DiscoveryEntry?
        if let index = history.lastIndex(where: matches) {
            reusable = history.remove(at: index)
        } else if let index = forwardHistory.lastIndex(where: matches) {
            reusable = forwardHistory.remove(at: index)
        } else { reusable = nil }
        // A new navigation branches from the current page, like browser history.
        // Reuse a matching paused feed before discarding the abandoned branch.
        forwardHistory.forEach { $0.pager.cancel() }
        forwardHistory.removeAll()
        if let restored = reusable {
            current.pager.cancel(); history.append(current); current = restored
            if restored.pager.interrupted { restored.pager.retry(session: session) }
            return true
        }

        current.pager.cancel()
        history.append(current)
        if history.count > Self.historyLimit {
            let excess = history.count - Self.historyLimit
            let removed = Array(history.prefix(excess))
            history.removeFirst(excess)
            removed.forEach { $0.pager.cancel() }
        }
        let entry = prepared ?? DiscoveryEntry(query: query, site: site, lane: lane, savedID: savedID, requestURL: url)
        entry.markStarted()
        current = entry
        entry.pager.reset(url: url, session: session, qa: qa, preserveCachedPresentation: !entry.query.hasSettings)
        return true
    }

    @discardableResult
    func back() -> Bool {
        guard !history.isEmpty else { return false }
        return restoreHistoryEntry(at: history.count - 1)
    }

    @discardableResult
    func backToPreviousSearch() -> Bool {
        guard let index = history.lastIndex(where: { $0.query.hasSettings }) else { return false }
        return restoreHistoryEntry(at: index)
    }

    private func restoreHistoryEntry(at index: Int) -> Bool {
        let previous = history[index]
        let skipped = Array(history.dropFirst(index + 1))
        current.pager.cancel()
        forwardHistory.append(current)
        forwardHistory.append(contentsOf: skipped.reversed())
        history.removeSubrange(index...)
        current = previous
        return true
    }

    @discardableResult
    func forward() -> Bool {
        guard let next = forwardHistory.popLast() else { return false }
        current.pager.cancel()
        history.append(current)
        current = next
        return true
    }

    static func requestURL(query: SearchQuery, site: GallerySite, lane: Int) throws -> URL {
        guard (0...1).contains(lane) else { throw ViewerError.invalidQuery("浏览范围无效") }
        if query.hasSettings { return try query.url(site: site) }
        return lane == 1 ? site.baseURL.appendingPathComponent("popular") : try SearchQuery().url(site: site)
    }
}

enum DiscoveryHistorySwipe {
    enum Direction: Equatable { case back, forward }

    static func direction(horizontal: Double, vertical: Double, canGoBack: Bool, canGoForward: Bool) -> Direction? {
        guard abs(horizontal) >= 24, abs(horizontal) > abs(vertical) * 1.6 else { return nil }
        if horizontal > 0 { return canGoBack ? .back : nil }
        return canGoForward ? .forward : nil
    }

    static func committedDirection(horizontal: Double, vertical: Double, predictedHorizontal: Double,
                                   canGoBack: Bool, canGoForward: Bool) -> Direction? {
        guard let direction = direction(horizontal: horizontal, vertical: vertical, canGoBack: canGoBack, canGoForward: canGoForward) else { return nil }
        let flick = abs(horizontal) >= 30 && horizontal * predictedHorizontal > 0 && abs(predictedHorizontal) >= 120
        return abs(horizontal) >= 72 || flick ? direction : nil
    }
}
