import Foundation
import ExViewerCore
import SwiftUI

/// Deterministic local transport and isolated persistent cache for simulator QA.
/// It is intentionally inaccessible unless the app is in QA mode and the explicit
/// `--qa-feed-cache` launch argument is present.
enum FeedCacheQA {
    private static let arguments = ProcessInfo.processInfo.arguments
    @MainActor private static var listRequestsByPath: [String: Int] = [:]

    static var isEnabled: Bool {
        AppMode.qa && arguments.contains("--qa-feed-cache")
    }

    private static var runID: String {
        guard let index = arguments.firstIndex(of: "--qa-feed-cache-run"),
              arguments.indices.contains(index + 1) else { return "default" }
        let candidate = arguments[index + 1]
        return candidate.range(of: #"^[A-Za-z0-9_-]{1,80}$"#, options: .regularExpression) != nil
            ? candidate : "default"
    }

    static let cache: FeedSnapshotCache = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ExViewerFeedCache-QA", isDirectory: true)
            .appendingPathComponent(runID, isDirectory: true)
        return FeedSnapshotCache(root: base)
    }()

    static func stateIdentifier(for lane: String) -> String {
        "feed.qa.state.\(lane == "favorites" ? "favorites" : "discover")"
    }

    @MainActor static func stateValue(pager: GalleryPager) -> String {
        "cached=\(pager.cachedAt != nil);loading=\(pager.loading);items=\(pager.items.count);next=\(pager.next != nil);failure=\(pager.failure != nil);latestRequests=\(listRequestsByPath["/", default: 0]);popularRequests=\(listRequestsByPath["/popular", default: 0]);favoriteRequests=\(listRequestsByPath["/favorites.php", default: 0])"
    }
    @MainActor private static func recordListRequest(_ url: URL) { listRequestsByPath[url.path, default: 0] += 1 }

    /// Loader signature matches GalleryPager's injected transport. API metadata
    /// requests are synthesized from their gids; list pages are selected by URL.
    static func loadHTML(_ url: URL, search: Bool, body: Data?) async throws -> String {
        guard isEnabled else { throw URLError(.unsupportedURL) }
        if search { await recordListRequest(url) }
        if arguments.contains("--qa-feed-cache-login-expired") { throw ViewerError.authentication }
        if arguments.contains("--qa-feed-cache-failure") { throw URLError(.timedOut) }
        if arguments.contains("--qa-feed-cache-empty") {
            return "<html><body><div class=\"itg\">No hits found</div></body></html>"
        }
        if arguments.contains("--qa-feed-cache-slow") {
            try await Task.sleep(nanoseconds: 60_000_000_000)
        }
        if arguments.contains("--qa-feed-cache-offline") {
            try await Task.sleep(nanoseconds: 12_000_000_000)
            try Task.checkCancellation()
            throw URLError(.notConnectedToInternet)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        if search, arguments.contains("--qa-feed-cache-refresh-delay") {
            try await Task.sleep(for: .seconds(3))
        }
        try Task.checkCancellation()

        if let body, url.host == "api.e-hentai.org" {
            return metadataJSON(for: body)
        }
        guard search else { throw URLError(.unsupportedURL) }
        let favorites = url.path == "/favorites.php"
        let lane = favorites ? "Favorites" : "Discover"
        let pageValue = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "qa-feed-page" })?.value
        let page = Int(pageValue ?? "1") ?? 1
        let pageCount = arguments.contains("--qa-feed-sort-regression") ? 3 : 2
        let firstGID: Int64 = favorites ? 910_001 : 900_001
        let start = firstGID + Int64((page - 1) * 24)
        let rows = (0..<24).map { offset -> String in
            let gid = start + Int64(offset)
            let title = "QA Feed \(lane) \(String(format: "%02d", (page - 1) * 24 + offset + 1))"
            return """
            <tr><td><a href="/g/\(gid)/qaFeed\(gid)/"><div class="glink">\(title)</div><img src="https://ehgt.org/qa-\(gid).webp" alt="cover"></a><div>4 pages</div></td></tr>
            """
        }.joined()

        let next: String
        if page < pageCount {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            var items = components.queryItems ?? []
            items.removeAll { $0.name == "qa-feed-page" }
            items.append(URLQueryItem(name: "qa-feed-page", value: String(page + 1)))
            components.queryItems = items
            next = "<a id=\"dnext\" href=\"\(components.url!.absoluteString)\">Next &gt;</a>"
        } else { next = "" }
        let categories = favorites ? "<select name=\"favcat\"><option value=\"all\">All</option></select>" : ""
        return "<html><body>\(categories)<div class=\"itg\"><table>\(rows)</table></div>\(next)</body></html>"
    }

    private static func metadataJSON(for body: Data) -> String {
        guard let request = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let pairs = request["gidlist"] as? [[Any]] else { return "{\"gmetadata\":[]}" }
        let entries: [[String: Any]] = pairs.compactMap { pair in
            guard let raw = pair.first, let number = raw as? NSNumber else { return nil }
            let gid = number.int64Value
            let lane = gid >= 910_000 ? "Favorites" : "Discover"
            let firstGID: Int64 = lane == "Favorites" ? 910_001 : 900_001
            let index = Int(gid - firstGID + 1)
            let sorting = arguments.contains("--qa-feed-sort-regression")
            let page = (index - 1) / 24
            return ["gid": gid, "title": "\(sorting ? ["Z", "M", "A"][min(page, 2)] : "QA") Feed \(lane) \(String(format: "%02d", index))",
                    "category": "Manga", "filecount": sorting ? String(200 - index) : "4",
                    "rating": sorting ? String(3.0 + Double(min(page, 2)) * 0.8 + Double(index % 3) * 0.05) : "4.5",
                    "tags": ["other:neutralonlytag"]]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ["gmetadata": entries]),
              let result = String(data: data, encoding: .utf8) else { return "{\"gmetadata\":[]}" }
        return result
    }
}

struct FeedCacheQAStatus: View {
    @ObservedObject var pager: GalleryPager
    let lane: String

    var body: some View {
        Text(" ")
            .font(.system(size: 1))
            .foregroundStyle(.clear)
            .frame(width: 1, height: 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Feed cache QA state")
            .accessibilityIdentifier(FeedCacheQA.stateIdentifier(for: lane))
            .accessibilityValue(FeedCacheQA.stateValue(pager: pager))
            .allowsHitTesting(false)
    }
}
