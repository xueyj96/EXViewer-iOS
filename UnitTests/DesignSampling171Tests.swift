import XCTest
import Combine
import UIKit
import ExViewerCore
@testable import ExViewer

/// Bounded component probes. These exercise production APIs where accessible;
/// lookup and raster probes isolate the exact kernels, not complete SwiftUI routes.
@MainActor final class DesignSampling171Tests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        // Every access is covered by lock; callbacks may arrive on transport threads.
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }
    @MainActor private final class Transfer {
        var demands: [Int: MediaRequestDemand] = [:]
        var pending: [Int: CheckedContinuation<URL, Error>] = [:]
        func load(_ page: GalleryPage, _ demand: MediaRequestDemand) async throws -> URL {
            demands[page.index] = demand
            return try await withCheckedThrowingContinuation { pending[page.index] = $0 }
        }
        func finish() {
            let values = pending.values; pending.removeAll()
            for continuation in values { continuation.resume(throwing: CancellationError()) }
        }
    }
    private func milliseconds(_ start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }
    private func stats(_ samples: [Double]) -> [String: Any] {
        let values = samples.sorted()
        return ["samples": values.count, "medianMS": values[values.count / 2],
                "minMS": values.first!, "maxMS": values.last!,
                "over8_33MS": values.filter { $0 > 8.33 }.count,
                "over16_67MS": values.filter { $0 > 16.67 }.count]
    }
    private func emit(_ name: String, _ data: [String: Any]) throws {
        var record = data
        record["probe"] = name
        record["environment"] = ProcessInfo.processInfo.environment["SIMULATOR_UDID"] == nil ? "native-test-process" : "iOS Simulator"
        let bytes = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        print("DESIGN_SAMPLING_171 " + String(decoding: bytes, as: UTF8.self))
    }
    private func pages(_ count: Int) -> [GalleryPage] {
        (1...count).map { .init(index: $0, url: URL(string: "https://exhentai.org/s/sample/1-\($0)")!) }
    }

    func testProgressCallbacksAndReaderDictionaryPublications() async throws {
        for visible in [true, false] {
            let transfer = Transfer(), store = ReaderMediaStore()
            let scope = ReaderMediaScope(galleryID: "ex:1", owner: "aa", generation: UUID(), context: UUID())
            store.update(scope: scope, pages: pages(3), current: 1, prefetchCount: 2,
                         downloadConcurrency: 2, demandLoader: { page, demand in
                try await transfer.load(page, demand)
            }, isCurrent: { true })
            let index = visible ? 1 : 2
            for _ in 0..<100 {
                if transfer.demands[index] != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let demand = try XCTUnwrap(transfer.demands[index])
            let callbacks = Counter()
            let token = demand.observeProgress { _ in callbacks.increment() }
            let callbackBaseline = callbacks.count
            var publications = 0
            let subscription = store.$progress.dropFirst().sink { _ in publications += 1 }
            let reports = 256 // 16 MiB at the actual 64 KiB reporting threshold.
            let start = DispatchTime.now().uptimeNanoseconds
            await Task.detached(priority: .userInitiated) {
                for index in 1...reports {
                    demand.reportProgress(.init(phase: .transferring, completedBytes: Int64(index * 65_536),
                                                totalBytes: Int64(reports * 65_536)))
                }
            }.value
            try await Task.sleep(nanoseconds: 120_000_000)
            let elapsed = milliseconds(start)
            let received = callbacks.count - callbackBaseline
            XCTAssertEqual(received, reports)
            if visible { XCTAssertEqual(store.progress[1]?.completedBytes, Int64(reports * 65_536)) }
            else { XCTAssertNil(store.progress[2]) }
            try emit("progress-burst", ["visible": visible, "producerReports": reports,
                       "observerCallbacks": received, "readerProgressPublications": publications,
                       "elapsedIncluding120MSDrain": elapsed,
                       "limitation": "Synthetic transport burst through production demand and store; 120ms tail drain, unlike baseline 30ms, so elapsed totals are not directly comparable; no SwiftUI body or frame count"])
            subscription.cancel(); demand.removeProgressObserver(token)
            transfer.finish(); store.reset()
        }
    }

    func testSinglePageLookupKernelAtLoadedWindowSizes() throws {
        for size in [100, 1_000, 10_000] {
            let values = pages(size), indices = [size - 2, size - 1, size]
            let mapped = Dictionary(uniqueKeysWithValues: values.map { ($0.index, $0) })
            var linear: [Double] = [], indexed: [Double] = [], checksum = 0
            for _ in 0..<7 {
                var start = DispatchTime.now().uptimeNanoseconds
                for _ in 0..<120 {
                    for index in indices { checksum += values.first(where: { $0.index == index })!.index }
                }
                linear.append(milliseconds(start) / 120)
                start = DispatchTime.now().uptimeNanoseconds
                for _ in 0..<120 {
                    for index in indices { checksum += mapped[index]!.index }
                }
                indexed.append(milliseconds(start) / 120)
            }
            XCTAssertGreaterThan(checksum, 0)
            try emit("three-page-lookup-kernel", ["loadedPages": size, "iterationsPerSample": 120,
                       "linearMSPerThreeLookups": stats(linear), "indexedMSPerThreeLookups": stats(indexed),
                       "limitation": "Exact first(where:) kernel; excludes body construction, diffing, decode, and actual frame time"])
        }
    }

    func testEdgePreviewRasterKernelAtRepresentativeVisibleDensities() throws {
        for cards in [0, 6, 18] {
            let source = UIView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
            source.backgroundColor = .systemBackground
            let image = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 220)).image { c in
                UIColor.systemBlue.setFill(); c.fill(CGRect(x: 0, y: 0, width: 160, height: 220))
                UIColor.systemOrange.setFill(); c.fill(CGRect(x: 20, y: 10, width: 100, height: 180))
            }
            for index in 0..<cards {
                let y = CGFloat(index / 2) * 265, x = CGFloat(index % 2) * 201
                let card = UIView(frame: CGRect(x: x + 8, y: y + 8, width: 185, height: 249))
                card.backgroundColor = .secondarySystemBackground; card.layer.cornerRadius = 12
                card.clipsToBounds = true
                let picture = UIImageView(image: image)
                picture.frame = CGRect(x: 0, y: 0, width: 185, height: 208)
                picture.contentMode = .scaleAspectFill; picture.clipsToBounds = true
                card.addSubview(picture)
                let title = UILabel(frame: CGRect(x: 8, y: 212, width: 169, height: 30))
                title.font = .systemFont(ofSize: 14); title.text = "Sample work \(index)"
                card.addSubview(title); source.addSubview(card)
            }
            source.layoutIfNeeded()
            let renderer = UIGraphicsImageRenderer(bounds: source.bounds)
            var samples: [Double] = []
            for _ in 0..<16 {
                let start = DispatchTime.now().uptimeNanoseconds
                let frame = renderer.image { source.layer.render(in: $0.cgContext) }
                samples.append(milliseconds(start))
                XCTAssertGreaterThan(frame.cgImage?.width ?? 0, 0)
            }
            try emit("edge-preview-raster-kernel", ["cardsInLayerTree": cards,
                       "canvasWidth": 402, "canvasHeight": 874, "scale": UIScreen.main.scale,
                       "firstMS": samples[0], "warm": stats(Array(samples.dropFirst())),
                       "limitation": "Same UIGraphicsImageRenderer+layer.render primitive on UIKit fixture; not full production SwiftUI source or edge gesture trace"])
        }
    }

    func testFeedSnapshotSaveAtBoundedPoolOccupancy() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DesignSampling171-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = FeedSnapshotCache(root: directory), owner = "aabb"
        let expected = await cache.epoch(owner: owner)
        let title = String(repeating: "Sample", count: 160)
        let galleries = (1...500).map { index in
            Gallery(ref: .init(site: .ex, gid: Int64(index), token: "sample"), title: "\(index) \(title)", category: "Manga")
        }
        let urls = (0..<24).map { index in
            URL(string: index < 12 ? "https://exhentai.org/?f_search=sample-\(index)" :
                    "https://exhentai.org/favorites.php?favcat=\(index % 10)&f_search=sample-\(index)")!
        }
        for url in urls {
            await cache.save(.init(owner: owner, root: url, items: galleries, next: nil, categories: [:]), expectedEpoch: expected)
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent(owner), includingPropertiesForKeys: [.fileSizeKey])
        let bytes = try files.reduce(0) { sum, file in sum + (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        XCTAssertEqual(files.count, 24)
        var samples: [Double] = [], heartbeatGaps: [Double] = []
        let heartbeat = Task { @MainActor in
            var previous = DispatchTime.now().uptimeNanoseconds
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000)
                guard !Task.isCancelled else { break }
                let now = DispatchTime.now().uptimeNanoseconds
                heartbeatGaps.append(Double(now - previous) / 1_000_000); previous = now
            }
        }
        for index in 0..<10 {
            let start = DispatchTime.now().uptimeNanoseconds
            await cache.save(.init(owner: owner, root: urls[index], items: galleries, next: nil, categories: [:]), expectedEpoch: expected)
            samples.append(milliseconds(start))
        }
        heartbeat.cancel(); await heartbeat.value
        let result = await cache.read(owner: owner, url: urls[0])
        XCTAssertEqual(result?.items.count, galleries.count)
        try emit("feed-snapshot-save", ["poolFiles": files.count, "poolBytes": bytes,
                   "galleriesPerFile": galleries.count, "save": stats(samples),
                   "mainActorHeartbeatGaps": heartbeatGaps.isEmpty ? [:] : stats(heartbeatGaps),
                   "limitation": "Warm Simulator temporary directory, actor API completion latency; heartbeat is scheduler observation, not full application frame time"])
    }
}
