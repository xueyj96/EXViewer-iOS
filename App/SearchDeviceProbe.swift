import SwiftUI
import ExViewerCore

/// Opt-in device probe. Uses the real account and pager, with a private cache
/// for the two runs. Its result contains timings and counts only.
@MainActor struct SearchDeviceProbe: View {
    let session: SiteSession
    let library: LibraryStore
    @State private var status = "正在测量搜索"

    static var enabled: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--search-device-probe")
        #else
        false
        #endif
    }

    private struct Stage: Codable {
        let phase: String
        let ms: Double
    }

    private struct Sample: Codable {
        let warm: Bool
        var hitSnapshot = false
        var firstVisibleMS: Double?
        var firstCoverFileMS: Double?
        var firstCoverMS: Double?
        var rootReadyMS: Double?
        var nextFirstVisibleMS: Double?
        var nextReadyMS: Double?
        var firstPageCount = 0
        var firstPageVisible = 0
        var combinedCount = 0
        var hadNext = false
        var rootFailed = false
        var nextFailed = false
        var stages: [Stage] = []
    }

    private struct Result: Codable {
        let site: String
        let blocks: Int
        let samples: [Sample]
        let sameFirstPage: Bool
        let sameCombined: Bool
    }

    var body: some View {
        Text(status).task { await run() }
    }

    private func run() async {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let output = caches.appendingPathComponent("ExViewerSearchProbe", isDirectory: true)
        let working = output.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: working) }
        let storage = working.appendingPathComponent("feed")
        let covers = MediaRepository(root: working.appendingPathComponent("covers"))
        let decoder = StaticCoverImageCache()
        let owner = session.owner, generation = session.generation, blocked = library.blockedIDs
        let site: GallerySite = session.hasCredentials ? .ex : .eh
        var query = SearchQuery()
        query.text = "neutral"
        guard let url = try? query.url(site: site) else { status = "测量失败"; return }
        var samples: [Sample] = []
        var firstPages: [[String]] = [], combined: [[String]] = []
        for warm in [false, true] {
            guard !Task.isCancelled, owner == session.owner, generation == session.generation else { return }
            let start = ProcessInfo.processInfo.systemUptime
            let elapsed = { (ProcessInfo.processInfo.systemUptime - start) * 1_000 }
            var stages: [Stage] = []
            let pager = GalleryPager(cache: FeedSnapshotCache(root: storage), onTiming: {
                stages.append(.init(phase: $0.rawValue, ms: $1))
            })
            var sample = Sample(warm: warm)
            pager.reset(url: url, session: session, rootLoad: .openSearch)
            await waitWhileLoading(pager) {
                guard let visible = LibrarySelectionPolicy.filtered(pager.items, blocked: blocked).visible.first else { return false }
                if sample.firstVisibleMS == nil {
                    sample.hitSnapshot = pager.cachedAt != nil
                    sample.firstVisibleMS = elapsed()
                }
                return visible.cover != nil
            }
            let firstVisible = LibrarySelectionPolicy.filtered(pager.items, blocked: blocked).visible
            let coverTask = Task { () -> (Double?, Double?) in
                guard let url = firstVisible.first?.cover,
                      let file = try? await covers.file(for: url, owner: owner, priority: .thumbnail) else { return (nil, nil) }
                let fileMS = elapsed()
                let image = await decoder.thumbnail(for: file, maxPixelSize: 480)
                return (fileMS, image == nil ? nil : elapsed())
            }
            await waitWhileLoading(pager) { false }
            sample.rootReadyMS = elapsed()
            sample.rootFailed = pager.failure != nil || pager.loading
            sample.firstPageCount = pager.items.count
            sample.firstPageVisible = LibrarySelectionPolicy.filtered(pager.items, blocked: blocked).visible.count
            let first = pager.items.map(\.id)
            firstPages.append(first)
            sample.hadNext = pager.next != nil
            if sample.hadNext && !pager.loading {
                let alreadyLoaded = Set(first)
                let nextStart = elapsed()
                pager.more(session: session)
                await waitWhileLoading(pager) {
                    let rows = LibrarySelectionPolicy.filtered(pager.items, blocked: blocked).visible
                    if sample.nextFirstVisibleMS == nil && rows.contains(where: { !alreadyLoaded.contains($0.id) }) {
                        sample.nextFirstVisibleMS = elapsed() - nextStart
                    }
                    return false
                }
                sample.nextReadyMS = elapsed() - nextStart
                sample.nextFailed = pager.failure != nil || pager.loading
            }
            if pager.loading { pager.cancel() }
            sample.combinedCount = pager.items.count
            combined.append(pager.items.map(\.id))
            (sample.firstCoverFileMS, sample.firstCoverMS) = await coverTask.value
            sample.stages = stages
            samples.append(sample)
        }
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let result = Result(site: site.rawValue, blocks: blocked.count, samples: samples,
                                sameFirstPage: firstPages.first == firstPages.last,
                                sameCombined: combined.first == combined.last)
            try JSONEncoder().encode(result).write(to: output.appendingPathComponent("latest.json"), options: .atomic)
            status = "搜索测量完成"
        } catch { status = "测量结果保存失败" }
    }

    private func waitWhileLoading(_ pager: GalleryPager, until condition: () -> Bool) async {
        let deadline = ProcessInfo.processInfo.systemUptime + 35
        repeat {
            if condition() || !pager.loading || Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(12))
        } while ProcessInfo.processInfo.systemUptime < deadline
    }
}
