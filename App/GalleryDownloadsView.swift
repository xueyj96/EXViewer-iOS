import SwiftUI
import UIKit
import CryptoKit
import ExViewerCore

struct GalleryDownloadsView: View {
    let gallery: Gallery
    @EnvironmentObject private var session: SiteSession
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.dismiss) private var dismiss
    @State private var help = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { downloads.enqueue(gallery); dismiss() } label: {
                        Label("保存到本地", systemImage: "arrow.down.to.line")
                    }.disabled(library.snapshot.downloads.contains { $0.id == gallery.id && $0.status == .complete })
                        .accessibilityIdentifier("downloads.save")
                    NavigationLink { GalleryTorrentsView(gallery: gallery, session: session) } label: {
                        Label("BT 种子", systemImage: "point.3.connected.trianglepath.dotted")
                    }.accessibilityIdentifier("downloads.torrents")
                } header: { Text(gallery.title).lineLimit(2) }
            }
            .navigationTitle("下载方式").navigationBarTitleDisplayMode(.inline).appNavigationChrome()
            .toolbar {
                AppToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                AppToolbarItem(placement: .confirmationAction) {
                    Button { help = true } label: { Image(systemName: "info.circle") }.accessibilityLabel("下载说明")
                }
            }
            .sheet(isPresented: $help) { DownloadHelpView() }
        }.presentationDetents([.medium, .large])
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

private struct TorrentShare: Identifiable {
    let id = UUID()
    let file: URL
}

@MainActor private final class GalleryTorrentsModel: ObservableObject {
    @Published var items: [GalleryTorrent] = []
    @Published var loading = false
    @Published var error: String?
    @Published var preparing: String?
    @Published var share: TorrentShare?
    private let gallery: Gallery
    private let session: SiteSession
    private var revision = UUID()
    private var exportTask: Task<Void, Never>?
    private var exportDirectory: URL?
    init(gallery: Gallery, session: SiteSession) { self.gallery = gallery; self.session = session }
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
                let raw: Data
                if AppMode.qa { raw = TorrentSample.raw }
                else { raw = try await TorrentFileTransfer.read(torrent) }
                let data = try PublicTorrentFile.sanitize(raw, expectedHash: torrent.infoHash, galleryID: gallery.ref.gid)
                try Task.checkCancellation()
                guard revision == token, generation == session.generation else { return }
                clearExport()
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ExViewer-Torrent-" + UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
                let file = directory.appendingPathComponent(torrent.infoHash + ".torrent")
                do { try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
                catch { try? FileManager.default.removeItem(at: directory); throw error }
                exportDirectory = directory; share = .init(file: file)
            } catch is CancellationError { }
            catch { if revision == token { self.error = "种子文件未能准备，请重试。" } }
        }
    }
    func cancel() { revision = UUID(); exportTask?.cancel(); exportTask = nil; preparing = nil; loading = false }
    func clearExport() { if let directory = exportDirectory { try? FileManager.default.removeItem(at: directory) }; exportDirectory = nil }
}

struct GalleryTorrentsView: View {
    let gallery: Gallery
    @ObservedObject private var session: SiteSession
    @StateObject private var model: GalleryTorrentsModel
    @State private var copied: String?
    init(gallery: Gallery, session: SiteSession) {
        self.gallery = gallery; self.session = session
        _model = StateObject(wrappedValue: GalleryTorrentsModel(gallery: gallery, session: session))
    }
    var body: some View {
        List {
            if model.loading && model.items.isEmpty { ProgressView("读取种子…") }
            if let error = model.error {
                Text(error).font(.subheadline).foregroundStyle(.secondary)
                if model.items.isEmpty { Button("重试") { Task { await model.load() } } }
            }
            if !model.loading && model.error == nil && model.items.isEmpty { Text("这部作品暂无种子").foregroundStyle(.secondary) }
            ForEach(model.items) { torrent in
                Section {
                    Text(torrent.title).font(.subheadline).lineLimit(3)
                    let metadata = [torrent.size, torrent.seeds.map { "做种 \($0)" }, torrent.peers.map { "下载 \($0)" }].compactMap { $0 }.joined(separator: " · ")
                    if !metadata.isEmpty { Text(metadata).font(.caption).foregroundStyle(.secondary) }
                    Button { model.prepare(torrent) } label: {
                        if model.preparing == torrent.id { Label("准备中…", systemImage: "hourglass") }
                        else { Label("导出种子文件", systemImage: "square.and.arrow.up") }
                    }.disabled(model.preparing != nil).accessibilityIdentifier("torrent.export")
                    Button { UIPasteboard.general.string = torrent.magnet(galleryID: gallery.ref.gid); copied = torrent.id } label: {
                        Label(copied == torrent.id ? "已复制磁链" : "复制磁链", systemImage: "link")
                    }.accessibilityIdentifier("torrent.copy-magnet")
                    ShareLink(item: torrent.magnet(galleryID: gallery.ref.gid)) { Label("分享磁链", systemImage: "square.and.arrow.up") }
                }
            }
        }
        .navigationTitle("BT 种子").navigationBarTitleDisplayMode(.inline).appNavigationChrome(backButton: true)
        .task { await model.load() }.onDisappear { model.cancel() }
        .onChange(of: session.generation) { _, _ in model.cancel(); model.items = []; model.error = "账号状态已变化，请重新打开。" }
        .sheet(item: $model.share, onDismiss: model.clearExport) { TorrentShareView(file: $0.file) }
    }
}

private struct TorrentShareView: UIViewControllerRepresentable {
    let file: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [file], applicationActivities: nil)
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
