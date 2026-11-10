import SwiftUI
import ExViewerCore

struct ReaderOpeningDetail {
    let detail: GalleryDetail
    let generation: UUID
    let owner: String
    var fetchedAt = Date()

    func isReusable(for reference: GalleryRef, generation: UUID, owner: String) -> Bool {
        detail.gallery.ref == reference && detail.gallery.tagsComplete && !detail.pages.isEmpty &&
            self.generation == generation && self.owner == owner &&
            (0...60).contains(Date().timeIntervalSince(fetchedAt))
    }
}

@MainActor final class ReaderModel: ObservableObject {
    @Published private(set) var pages: [GalleryPage] = []
    @Published private(set) var total: Int?
    @Published private(set) var next: URL?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private var seen = Set<URL>()
    private var context = UUID()
    private var generation: UUID?
    private var owner: String?
    private var metadataDemand: MediaRequestDemand?
    private let qa: Bool
    private(set) var qaMetadataCalls = 0
    init(qa: Bool = AppMode.qa) { self.qa = qa }
    func cancel() { context = UUID(); generation = nil; owner = nil; loading = false; metadataDemand = nil }
    func promotePendingMetadata() { metadataDemand?.setPriority(.foreground) }
    var hasForegroundMetadataDemand: Bool { metadataDemand?.priority == .foreground }
    func load(gallery: Gallery, offline: Bool, session: SiteSession, library: LibraryStore,
              openingDetail: ReaderOpeningDetail? = nil) async {
        cancel(); generation = session.generation; owner = library.owner
        pages = []; seen = []; total = gallery.pages; next = nil; error = nil
        if let record = library.readableDownload(for: gallery) {
            pages = library.downloadedPages(record)
            total = record.total ?? gallery.pages
            if let total, record.status == .complete, pages.count == total,
               pages.first?.index == 1, pages.last?.index == total { return }
        }
        if offline {
            if pages.isEmpty {
                let metadata = gallery.tagsComplete ? gallery : (library.download(for: gallery.ref)?.gallery ?? gallery)
                let blocked = TagFilter.decision(tags: metadata.tags, blocked: library.blockedIDs, complete: metadata.tagsComplete) != .visible
                error = blocked ? "此画廊已被标签设置屏蔽，或标签尚未核实。" : "本机没有可读取的离线副本。"
            }
            return
        }
        if qa {
            let fixtures: [GalleryPage]
            if ProcessInfo.processInfo.arguments.contains("--qa-reader-large-window") {
                fixtures = (1...40).map { GalleryPage(index: $0, url: QASamples.image(index: $0)) }
            } else {
                fixtures = QASamples.pages
            }
            total = fixtures.count
            if ProcessInfo.processInfo.arguments.contains("--qa-reader-paging") {
                pages = Array(fixtures.prefix(2)); next = URL(string: "https://exhentai.org/g/1/preview/?p=1")
            } else { pages = fixtures; next = nil }
            return
        }
        let detail = openingDetail.flatMap { opening in
            opening.isReusable(for: gallery.ref, generation: session.generation, owner: library.owner) ? opening.detail : nil
        }
        if pages.isEmpty || detail != nil {
            await fetch(url: gallery.ref.url, gallery: gallery, session: session, library: library, openingDetail: detail)
        } else {
            next = gallery.ref.url
        }
    }
    func more(gallery: Gallery, session: SiteSession, library: LibraryStore,
              priority: MediaRequestPriority = .foreground, beforeAppending: (() -> Void)? = nil) async {
        guard !loading else { return }
        if qa, next != nil {
            qaMetadataCalls += 1
            let expected = context
            loading = true
            defer { if expected == context { loading = false } }
            if ProcessInfo.processInfo.arguments.contains("--qa-reader-metadata-stall") {
                try? await Task.sleep(nanoseconds: 200_000_000)
                return
            }
            if ProcessInfo.processInfo.arguments.contains("--qa-reader-delay") { try? await Task.sleep(nanoseconds: 3_000_000_000) }
            if let value = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--qa-metadata-ms=") })?.split(separator: "=").last.flatMap({ UInt64($0) }) {
                try? await Task.sleep(nanoseconds: min(value, 15_000) * 1_000_000)
            }
            guard !Task.isCancelled, expected == context, generation == session.generation, owner == library.owner else { return }
            beforeAppending?()
            pages = QASamples.pages; next = nil; return
        }
        if let next { await fetch(url: next, gallery: gallery, session: session, library: library, priority: priority, beforeAppending: beforeAppending) }
    }
    private func fetch(url: URL, gallery: Gallery, session: SiteSession, library: LibraryStore,
                       priority: MediaRequestPriority = .foreground, beforeAppending: (() -> Void)? = nil,
                       openingDetail: GalleryDetail? = nil) async {
        guard generation == session.generation, owner == library.owner, !seen.contains(url), seen.count < 100 else { return }
        let current = context, revision = session.generation
        let demand = MediaRequestDemand(priority: priority)
        metadataDemand = demand
        loading = true
        defer { if current == context { loading = false; if metadataDemand === demand { metadataDemand = nil } } }
        do {
            try Task.checkCancellation()
            let detail: GalleryDetail
            if let openingDetail { detail = openingDetail }
            else { detail = try await session.galleryDetail(for: gallery.ref, pageURL: url, request: demand).detail }
            guard current == context, revision == session.generation, owner == library.owner else { return }
            guard TagFilter.decision(tags: detail.gallery.tags, blocked: library.blockedIDs, complete: true) == .visible else { throw ViewerError.invalidQuery("此画廊命中本机屏蔽标签，可到账号的「标签与屏蔽」调整。") }
            beforeAppending?()
            seen.insert(url); var indexes = Set(pages.map(\.index)); pages += detail.pages.filter { indexes.insert($0.index).inserted }
            pages.sort { $0.index < $1.index }
            total = detail.gallery.pages
            if let candidate = detail.next, seen.contains(candidate) || seen.count >= 100 {
                next = nil
                error = "站点没有返回可用的后续页，已保留当前已加载的页面。"
            } else {
                next = detail.next
                error = nil
            }
        } catch is CancellationError { }
        catch { guard current == context, revision == session.generation, owner == library.owner else { return }; self.error = ErrorMessages.message(error, fallback: ViewerError.network.localizedDescription) }
    }
}
