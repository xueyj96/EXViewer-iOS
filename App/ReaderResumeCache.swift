import Foundation
import CryptoKit
import ExViewerCore

struct ReaderResumeSnapshot: Codable, Sendable {
    let index: Int
    let pages: [GalleryPage]
    let total: Int?
    let next: URL?
    let tags: [GalleryTag]
    let fileName: String
    let savedAt: Date
}

/// Stores reader locators alongside an owner’s browse files. MediaRepository
/// serializes reads, writes and cache clearing and validates the image bytes.
struct ReaderResumeCache {
    let directory: URL

    private func location(for reference: GalleryRef) -> URL {
        let name = SHA256.hash(data: Data(reference.url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("reader-resume", isDirectory: true)
            .appendingPathComponent(name)
    }

    func save(reference: GalleryRef, index: Int, pages: [GalleryPage],
                          total: Int?, next: URL?, tags: [GalleryTag], file: URL, at date: Date) {
        guard file.standardizedFileURL.deletingLastPathComponent().path == directory.standardizedFileURL.path,
              Self.isCacheFileName(file.lastPathComponent) else { return }
        // Store only ordinary reader page locators and the hashed local filename.
        // Intermediate image-source URLs can expire and are never persisted here.
        let online = pages.filter { Self.isReaderPage($0, for: reference) }
        guard online.count == pages.count, online.count <= 5_000,
              online.contains(where: { $0.index == index }) else { return }
        let location = location(for: reference)
        let folder = location.deletingLastPathComponent()
        let current = try? readReaderResume(at: location)
        guard current.map({ $0.savedAt <= date }) ?? true else { return }
        guard current?.index != index || current?.fileName != file.lastPathComponent ||
                current?.pages != online || current?.next != next || current?.tags != tags ||
                current?.total != total || (current?.savedAt ?? .distantPast).timeIntervalSince(date) < -86_400 else { return }
        let snapshot = ReaderResumeSnapshot(index: index, pages: online, total: total,
                                            next: next.flatMap { Self.isReaderContinuation($0, for: reference) ? $0 : nil },
                                            tags: tags, fileName: file.lastPathComponent, savedAt: date)
        // A bad continuation must retain the normal online recovery path.
        guard next == nil || snapshot.next != nil else { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(to: location, options: .atomic)
            if current == nil {
                let keys: Set<URLResourceKey> = [.contentModificationDateKey]
                let entries = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys))
                if entries.count > 32 {
                    let ordered = entries.sorted {
                        let lhs = (try? $0.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
                        let rhs = (try? $1.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
                        return lhs > rhs
                    }
                    for stale in ordered.dropFirst(32) { try? FileManager.default.removeItem(at: stale) }
                }
            }
        } catch { /* This cache is optional. The existing reader can load online. */ }
    }

    func read(reference: GalleryRef, index: Int, blocked: Set<String>) -> (ReaderResumeSnapshot, URL)? {
        guard let snapshot = try? readReaderResume(at: location(for: reference)),
              snapshot.index == index, snapshot.total.map({ index <= $0 }) ?? true,
              snapshot.pages.contains(where: { $0.index == index }),
              snapshot.pages.allSatisfy({ Self.isReaderPage($0, for: reference) }),
              snapshot.next.map({ Self.isReaderContinuation($0, for: reference) }) ?? true,
              TagFilter.decision(tags: snapshot.tags, blocked: blocked, complete: true) == .visible,
              Self.isCacheFileName(snapshot.fileName) else { return nil }
        return (snapshot, directory.appendingPathComponent(snapshot.fileName))
    }

    private func readReaderResume(at location: URL) throws -> ReaderResumeSnapshot {
        let values = try location.resourceValues(forKeys: [.fileSizeKey])
        guard let bytes = values.fileSize, bytes <= 1_500_000 else { throw ViewerError.storage }
        return try JSONDecoder().decode(ReaderResumeSnapshot.self, from: Data(contentsOf: location))
    }

    private static func isCacheFileName(_ name: String) -> Bool {
        name.utf8.count == 64 && name.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func isReaderPage(_ page: GalleryPage, for reference: GalleryRef) -> Bool {
        let url = page.url
        let path = url.pathComponents
        return URLPolicy.account(url) && url.host == reference.site.host && url.query == nil && url.fragment == nil &&
            path.count == 4 && path[1] == "s" && path[3] == "\(reference.gid)-\(page.index)" && page.index > 0
    }

    private static func isReaderContinuation(_ url: URL, for reference: GalleryRef) -> Bool {
        guard URLPolicy.continuation(url, from: reference.url), url.fragment == nil,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems, items.count == 1,
              items[0].name == "p", let value = items[0].value, let page = Int(value) else { return false }
        return page > 0
    }
}
