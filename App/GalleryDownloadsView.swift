import SwiftUI
import UIKit
import CryptoKit
import ExViewerCore

enum GalleryDownloadState {
    case ready, downloading(DownloadRecord), retry(DownloadRecord), saved, update(GalleryOfflineUpdate)

    var title: String {
        switch self {
        case .ready: "离线下载"
        case .downloading(let record): record.status == .waiting ? "等待下载" : "正在下载"
        case .retry: "重试下载"
        case .saved: "下载完成"
        case .update: "更新可用"
        }
    }

    var symbol: String {
        switch self {
        case .ready: "arrow.down.to.line"
        case .downloading: "arrow.down.circle"
        case .retry: "arrow.clockwise"
        case .saved: "checkmark.circle"
        case .update: "arrow.triangle.2.circlepath"
        }
    }

    var progress: String {
        let record: DownloadRecord
        switch self {
        case .downloading(let active): record = active
        case .retry(let failed): record = failed
        default: return ""
        }
        if record.status == .waiting { return "等待中" }
        let completed = record.completed.count
        let count = record.total.map { "已保存 \(completed)/\($0) 页" } ?? "已保存 \(completed) 页"
        return record.requiresRetry ? [record.error ?? "下载失败", count].joined(separator: "，") : count
    }

    static func resolve(_ reference: GalleryRef, records: [DownloadRecord],
                        links: GalleryVersionLinks?, owner: String, generation: UUID) -> Self {
        var related = Set([reference] + (links?.earlier ?? []))
        if let latest = links?.latest { related.insert(latest) }
        // A confirmed replacement is also a version link while it is queued or paused.
        for record in records {
            guard let old = record.replaces, old.site == reference.site,
                  record.gallery.ref.site == reference.site, old.gid < record.gallery.ref.gid,
                  related.contains(old) || related.contains(record.gallery.ref) else { continue }
            related.insert(old)
            related.insert(record.gallery.ref)
        }
        let known = records.filter { related.contains($0.gallery.ref) }
        let target = related.max { $0.gid < $1.gid } ?? reference
        if known.contains(where: { $0.gallery.ref == target && $0.status == .complete }) { return .saved }
        if let active = known.filter({ $0.status == .waiting || $0.status == .downloading })
            .max(by: { $0.gallery.ref.gid < $1.gallery.ref.gid }) {
            return .downloading(active)
        }
        if let failed = known.first(where: { $0.gallery.ref == target && $0.requiresRetry }) {
            return .retry(failed)
        }
        if let old = known.filter({ $0.status == .complete && $0.gallery.ref.gid < target.gid })
            .max(by: { $0.gallery.ref.gid < $1.gallery.ref.gid })?.gallery.ref {
            return .update(.init(old: old, target: target, owner: owner, generation: generation))
        }
        return .ready
    }
}

@MainActor final class GalleryDownloadVersions: ObservableObject {
    struct Query: Equatable {
        let reference: GalleryRef
        let owner: String
        let generation: UUID
    }

    enum Phase {
        case idle, checking, ready(GalleryVersionLinks?), failed(String)

        var links: GalleryVersionLinks? {
            if case .ready(let links) = self { return links }
            return nil
        }
    }

    @Published private var result: (query: Query, phase: Phase)?
    private var revision = UUID()

    static func query(for reference: GalleryRef, library: LibraryStore, session: SiteSession) -> Query? {
        guard library.owner == session.owner,
              library.snapshot.downloads.contains(where: { $0.status == .complete && $0.gallery.ref.site == reference.site }) else { return nil }
        return Query(reference: reference, owner: session.owner, generation: session.generation)
    }

    func phase(for query: Query?) -> Phase {
        result?.query == query ? result?.phase ?? .idle : .idle
    }

    func downloadState(for reference: GalleryRef, library: LibraryStore, session: SiteSession) -> GalleryDownloadState {
        let query = Self.query(for: reference, library: library, session: session)
        return .resolve(reference, records: library.snapshot.downloads, links: phase(for: query).links,
                        owner: library.owner, generation: session.generation)
    }

    func refresh(_ gallery: Gallery, query: Query?, session: SiteSession, force: Bool = false) async {
        guard let query else { result = nil; revision = UUID(); return }
        guard force || result?.query != query else { return }
        let revision = UUID()
        self.revision = revision
        result = (query, .checking)
        do {
            let links: GalleryVersionLinks?
            if AppMode.qa {
                links = Self.fixture(for: gallery.ref)
            } else {
                links = try await session.galleryVersionLinks(gallery, priority: force ? .foreground : .prefetch, refresh: force)
            }
            try Task.checkCancellation()
            guard self.revision == revision, session.generation == query.generation, session.owner == query.owner else { return }
            result = (query, .ready(links))
        } catch is CancellationError {
            if self.revision == revision { result = nil }
        } catch {
            guard self.revision == revision, session.generation == query.generation, session.owner == query.owner else { return }
            result = (query, .failed(ErrorMessages.message(error, fallback: "暂时无法检查画廊版本。")))
        }
    }

    private static func fixture(for reference: GalleryRef) -> GalleryVersionLinks? {
        guard ProcessInfo.processInfo.arguments.contains("--qa-download-version") else { return nil }
        let old = GalleryRef(site: reference.site, gid: 1, token: "preview")
        let latest = GalleryRef(site: reference.site, gid: 2, token: "preview")
        if reference == old { return .init(latest: latest, earlier: []) }
        if reference == latest { return .init(latest: latest, earlier: [old]) }
        return nil
    }
}

extension View {
    func confirmOfflineUpdate(_ update: Binding<GalleryOfflineUpdate?>,
                              onConfirm: @escaping (GalleryOfflineUpdate) -> Void) -> some View {
        confirmationDialog("更新离线副本？", isPresented: Binding(get: { update.wrappedValue != nil }, set: { if !$0 { update.wrappedValue = nil } }),
                           titleVisibility: .visible, presenting: update.wrappedValue) { plan in
            Button("更新到新版") { onConfirm(plan) }
            Button("取消", role: .cancel) { }
        } message: { _ in
            Text("能核对的图片会直接复用，其余图片重新缓存。新版完整后，旧副本将在结束阅读时移除。")
        }
    }
}

struct GalleryDownloadsView: View {
    let gallery: Gallery
    @ObservedObject var versions: GalleryDownloadVersions
    @EnvironmentObject private var session: SiteSession
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.dismiss) private var dismiss
    @State private var pendingUpdate: GalleryOfflineUpdate?

    private var query: GalleryDownloadVersions.Query? {
        GalleryDownloadVersions.query(for: gallery.ref, library: library, session: session)
    }

    var body: some View {
        NavigationStack {
            List {
                Text(gallery.title).lineLimit(2).foregroundStyle(.secondary)
                    .accountPageCard(compactRows: true)
                downloadAction(for: versions.downloadState(for: gallery.ref, library: library, session: session))
                NavigationLink { GalleryTorrentsView(gallery: gallery, session: session) } label: {
                    Label("BT 种子", systemImage: "point.3.connected.trianglepath.dotted")
                        .downloadOptionTarget()
                }
                .accessibilityIdentifier("downloads.torrents")
                .accountPageCard(compactRows: true)
            }
            .accountSubpageContent()
            .floatingPageHeader("下载方式", identifier: "downloads.options") {
                Button { dismiss() } label: { Label("关闭", systemImage: "xmark") }.buttonStyle(FeedHeaderButtonStyle())
                    .accessibilityIdentifier("downloads.options.close")
            } trailing: {
                EmptyView()
            }
            .task(id: query) { await versions.refresh(gallery, query: query, session: session) }
            .confirmOfflineUpdate($pendingUpdate) { update in
                if downloads.enqueueUpdate(update, from: gallery) { dismiss() }
            }
        }
        .localPageChrome()
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder private func downloadAction(for state: GalleryDownloadState) -> some View {
        switch state {
        case .ready:
            Button { if downloads.enqueue(gallery) { dismiss() } } label: {
                Label("保存到本地", systemImage: state.symbol)
                    .downloadOptionTarget()
            }.accessibilityIdentifier("downloads.save").accountPageCard(compactRows: true)
        case .downloading:
            Label(state.title, systemImage: state.symbol).foregroundStyle(.secondary)
                .accessibilityValue(state.progress).accountPageCard(compactRows: true)
        case .retry(let record):
            Button { if downloads.enqueue(record.gallery) { dismiss() } } label: {
                Label(state.title, systemImage: state.symbol)
                    .downloadOptionTarget()
            }.accessibilityIdentifier("downloads.save").accessibilityValue(state.progress)
                .accountPageCard(compactRows: true)
            if let error = record.error {
                Text(error).font(.caption).foregroundStyle(.secondary).accountPageCard()
            }
        case .saved:
            Label(state.title, systemImage: state.symbol).foregroundStyle(.secondary)
                .accountPageCard(compactRows: true)
            switch versions.phase(for: query) {
            case .checking: ProgressView("检查画廊新版…").accountPageCard(compactRows: true)
            case .failed(let reason):
                Text(reason).font(.caption).foregroundStyle(.secondary).accountPageCard()
                retryVersionCheck
            case .ready(let links) where links?.latest == nil:
                retryVersionCheck
            default: EmptyView()
            }
        case .update(let update):
            Button { pendingUpdate = update } label: {
                Label("更新离线副本", systemImage: state.symbol).downloadOptionTarget()
            }
                .accessibilityIdentifier("downloads.update")
                .accountPageCard(compactRows: true)
        }
    }

    private var retryVersionCheck: some View {
        Button {
            Task { await versions.refresh(gallery, query: query, session: session, force: true) }
        } label: {
            Label("检查新版", systemImage: "arrow.clockwise").downloadOptionTarget()
        }
        .disabled(AppMode.qa).accountPageCard(compactRows: true)
    }
}

private extension View {
    func downloadOptionTarget() -> some View {
        frame(maxWidth: .infinity, minHeight: FeedChrome.compactFormRowHeight, alignment: .leading)
            .contentShape(Rectangle())
    }
}

private final class TorrentRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, GalleryTorrentParser.publicDownloadURL(url) == url else { completionHandler(nil); return }
        var safe = URLRequest(url: url); safe.httpMethod = "GET"; completionHandler(safe)
    }
}

enum TorrentFileTransfer {
    static func read(_ torrent: GalleryTorrent) async throws -> Data {
        guard GalleryTorrentParser.publicDownloadURL(torrent.downloadURL) == torrent.downloadURL else { throw ViewerError.restricted }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 60
        let session = URLSession(configuration: config, delegate: TorrentRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: torrent.downloadURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.mimeType?.lowercased() != "text/html",
              response.expectedContentLength <= PublicTorrentFile.maximumBytes else { throw ViewerError.layoutChanged }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < PublicTorrentFile.maximumBytes else { throw ViewerError.layoutChanged }
            data.append(byte)
        }
        return data
    }
}

final class TorrentShare: Identifiable {
    let id: UUID
    let file: URL

    fileprivate init(data: Data, infoHash: String) throws {
        let id = UUID()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExViewer-Torrent-\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let file = directory.appendingPathComponent(infoHash + ".torrent")
        do {
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        self.id = id
        self.file = file
    }

    deinit { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
}

@MainActor final class GalleryTorrentsModel: ObservableObject {
    @Published var items: [GalleryTorrent] = []
    @Published var loading = false
    @Published var error: String?
    @Published var preparing: String?
    @Published var share: TorrentShare?
    private let gallery: Gallery
    private let session: SiteSession
    private let readTorrent: (GalleryTorrent) async throws -> Data
    private var revision = UUID()
    private var exportTask: Task<Void, Never>?
    init(gallery: Gallery, session: SiteSession,
         readTorrent: @escaping (GalleryTorrent) async throws -> Data = { torrent in
             if AppMode.qa { return TorrentSample.raw }
             return try await TorrentFileTransfer.read(torrent)
         }) {
        self.gallery = gallery
        self.session = session
        self.readTorrent = readTorrent
    }
    func load() async {
        let token = UUID(); revision = token
        let generation = session.generation
        loading = true; error = nil
        defer { if revision == token { loading = false } }
        do {
            let values: [GalleryTorrent]
            if AppMode.qa { values = [TorrentSample.torrent] }
            else {
                let url = try GalleryTorrentParser.listURL(gallery.ref)
                values = try GalleryTorrentParser.parse(await session.html(url), base: url)
            }
            guard !Task.isCancelled, revision == token, session.generation == generation else { return }
            items = values
        } catch is CancellationError { }
        catch { if revision == token { self.error = ErrorMessages.message(error) } }
    }
    func prepare(_ torrent: GalleryTorrent) {
        guard preparing == nil, share == nil else { return }
        let token = revision, generation = session.generation
        preparing = torrent.id; error = nil
        exportTask = Task { [weak self] in
            guard let self else { return }
            defer { if revision == token { preparing = nil; exportTask = nil } }
            do {
                let raw = try await readTorrent(torrent)
                let data = try PublicTorrentFile.sanitize(raw, expectedHash: torrent.infoHash, galleryID: gallery.ref.gid)
                try Task.checkCancellation()
                guard revision == token, generation == session.generation else { return }
                share = try TorrentShare(data: data, infoHash: torrent.infoHash)
            } catch is CancellationError { }
            catch { if revision == token { self.error = "种子文件未能准备，请重试。" } }
        }
    }
    func cancel() {
        revision = UUID()
        exportTask?.cancel()
        exportTask = nil
        preparing = nil
        loading = false
        share = nil
    }

    func finishSharing(_ id: UUID) {
        if share?.id == id { share = nil }
    }
}

struct GalleryTorrentsView: View {
    let gallery: Gallery
    @Environment(\.dynamicTypeSize) private var typeSize
    @ObservedObject private var session: SiteSession
    @StateObject private var model: GalleryTorrentsModel
    @State private var copied: String?
    init(gallery: Gallery, session: SiteSession) {
        self.gallery = gallery; self.session = session
        _model = StateObject(wrappedValue: GalleryTorrentsModel(gallery: gallery, session: session))
    }
    var body: some View {
        List {
            if model.loading && model.items.isEmpty { ProgressView("读取种子…").accountPageCard() }
            if let error = model.error {
                VStack(alignment: .leading, spacing: FeedChrome.panelSpacing) {
                    Text(error).foregroundStyle(.secondary)
                    if model.items.isEmpty {
                        Button("重试") { Task { await model.load() } }
                            .buttonStyle(AppActionButtonStyle(tone: .accent))
                    }
                }
                .accountPageCard()
            }
            if !model.loading && model.error == nil && model.items.isEmpty {
                Text("这部作品暂无种子").foregroundStyle(.secondary).accountPageCard(compactRows: true)
            }
            ForEach(model.items) { torrent in
                torrentCard(torrent)
            }
        }
        .accountSubpageHeader("BT 种子", identifier: "torrent") { EmptyView() }
        .task { await model.load() }.onDisappear { model.cancel() }
        .onChange(of: session.generation) { _, _ in model.cancel(); model.items = []; model.error = "账号状态已变化，请重新打开。" }
        .sheet(item: $model.share) { share in
            TorrentShareView(file: share.file) {
                model.finishSharing(share.id)
            }
        }
    }

    private func torrentCard(_ torrent: GalleryTorrent) -> some View {
        let metadata = [torrent.size, torrent.seeds.map { "做种 \($0)" }, torrent.peers.map { "下载 \($0)" }]
            .compactMap { $0 }.joined(separator: " · ")
        let magnet = torrent.magnet(galleryID: gallery.ref.gid)
        let actions = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: FeedChrome.panelSpacing))
            : AnyLayout(HStackLayout(spacing: FeedChrome.panelSpacing))
        return VStack(alignment: .leading, spacing: FeedChrome.panelSpacing) {
            VStack(alignment: .leading, spacing: FeedChrome.panelSpacing) {
                Text(torrent.title).font(.subheadline.weight(.medium)).lineLimit(2)
                if !metadata.isEmpty { Text(metadata).font(.caption).foregroundStyle(.secondary) }
            }
            actions {
                Button { model.prepare(torrent) } label: {
                    torrentActionLabel(model.preparing == torrent.id ? "准备中…" : "导出种子",
                                       symbol: model.preparing == torrent.id ? "hourglass" : "square.and.arrow.up")
                }
                .buttonStyle(AppActionButtonStyle(tone: .accent))
                .disabled(model.preparing != nil)
                .accessibilityIdentifier("torrent.export")
                Button { UIPasteboard.general.string = magnet; copied = torrent.id } label: {
                    torrentActionLabel(copied == torrent.id ? "已复制" : "复制磁链", symbol: "link")
                }
                .buttonStyle(AppActionButtonStyle())
                .accessibilityIdentifier("torrent.copy-magnet")
                ShareLink(item: magnet) { torrentActionLabel("分享磁链", symbol: "square.and.arrow.up") }
                    .buttonStyle(AppActionButtonStyle())
            }
        }
        .accountPageCard()
    }

    private func torrentActionLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: FeedChrome.panelSpacing) {
            Image(systemName: symbol).font(.caption.weight(.medium)).accessibilityHidden(true)
            Text(title).font(.footnote.weight(.medium)).lineLimit(1)
        }
        .foregroundStyle(Color.primary)
        .frame(maxWidth: .infinity)
    }
}

private struct TorrentShareView: UIViewControllerRepresentable {
    let file: URL
    let onComplete: () -> Void
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in onComplete() }
        controller.view.accessibilityIdentifier = "torrent.share"
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}

private enum TorrentSample {
    static let info = Data("d6:lengthi4e4:name12:sample01.png12:piece lengthi16384e6:pieces20:".utf8) + Data(repeating: 0, count: 20) + Data("e".utf8)
    static let hash = Insecure.SHA1.hash(data: info).map { String(format: "%02x", $0) }.joined()
    static let torrent = GalleryTorrent(title: "海岸线 · 中性示例", downloadURL: URL(string: "https://ehtracker.org/get/1/\(hash).torrent")!, infoHash: hash, size: "4 B", seeds: 3, peers: 1)
    static let raw = Data("d4:info".utf8) + info + Data("e".utf8)
}
