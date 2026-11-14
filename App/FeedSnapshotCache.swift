import Foundation
import CryptoKit
import ExViewerCore

struct FeedSnapshot: Codable, Sendable {
    let version: Int
    let owner: String
    let root: URL
    let items: [Gallery]
    let next: URL?
    let categories: [String: String]
    let savedAt: Date
    init(owner: String, root: URL, items: [Gallery], next: URL?, categories: [String: String]) {
        version = 1; self.owner = owner; self.root = root; self.items = items
        self.next = next; self.categories = categories; savedAt = Date()
    }
}

/// Private, bounded first-page snapshots, always revalidated on use.
/// Invalidation rejects obsolete writes while preserving a last-known view.
actor FeedSnapshotCache {
    static let shared = FeedSnapshotCache()
    private let root: URL
    // Searching must not evict the user's last-known favorites list.
    // Both pools remain bounded and share the existing total byte budget.
    private let maxEntriesPerPool = 12
    private let maxBytes = 20_000_000
    private let maxEntryBytes = 4_000_000
    private var epochs: [String: Int] = [:]
    private var memory: [String: (FeedSnapshot, Int)] = [:]
    private enum Pool: CaseIterable { case browsing, favorites }
    private func pool(_ url: URL) -> Pool { url.path == "/favorites.php" ? .favorites : .browsing }
    private struct Header: Decodable { let root: URL }

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ExViewerFeedCache", isDirectory: true)
    }
    func epoch(owner: String) -> Int { epochs[owner, default: 0] }
    private func key(owner: String, url: URL) -> String {
        // Old rating-filtered snapshots can contain sprite-derived values. Only
        // those queries get a fresh namespace; all other cached feeds stay usable.
        let version = GalleryRatingFilter.minimum(in: url) == nil ? "" : "strict-average-rating-v1\n"
        return SHA256.hash(data: Data((version + owner + "\n" + url.absoluteString).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func validOwner(_ owner: String) -> Bool {
        owner == "guest" || (!owner.isEmpty && owner.count <= 64 && owner.allSatisfy(\.isHexDigit))
    }
    private func valid(_ snapshot: FeedSnapshot, owner: String, url: URL) -> Bool {
        guard snapshot.version == 1, snapshot.owner == owner, snapshot.root == url,
              URLPolicy.account(url), let site = GallerySite.allCases.first(where: { $0.host == url.host }),
              snapshot.next.map({ URLPolicy.continuation($0, from: url) }) ?? true else { return false }
        return Set(snapshot.items.map(\.id)).count == snapshot.items.count &&
            snapshot.items.allSatisfy {
                $0.ref.site == site && ($0.cover.map(URLPolicy.media) ?? true) &&
                GalleryRatingFilter.includes($0, minimum: GalleryRatingFilter.minimum(in: url))
            }
    }
    func read(owner: String, url: URL) -> FeedSnapshot? {
        guard validOwner(owner) else { return nil }
        let id = key(owner: owner, url: url)
        if let value = memory[id]?.0, valid(value, owner: owner, url: url) { return value }
        let file = root.appendingPathComponent(owner).appendingPathComponent(id + ".json")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = attributes[.size] as? NSNumber, size.intValue <= maxEntryBytes,
              let data = try? Data(contentsOf: file),
              let value = try? JSONDecoder().decode(FeedSnapshot.self, from: data), valid(value, owner: owner, url: url) else { return nil }
        memory[id] = (value, data.count); trimMemory(); return value
    }
    func save(_ snapshot: FeedSnapshot, expectedEpoch: Int) {
        guard validOwner(snapshot.owner), epoch(owner: snapshot.owner) == expectedEpoch,
              valid(snapshot, owner: snapshot.owner, url: snapshot.root),
              let data = try? JSONEncoder().encode(snapshot), data.count <= maxEntryBytes else { return }
        let id = key(owner: snapshot.owner, url: snapshot.root)
        let directory = root.appendingPathComponent(snapshot.owner, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var excluded = directory; var attributes = URLResourceValues(); attributes.isExcludedFromBackup = true
            try excluded.setResourceValues(attributes)
            try data.write(to: directory.appendingPathComponent(id + ".json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            memory[id] = (snapshot, data.count); trimMemory()
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
                .filter { $0.pathExtension == "json" }
                .compactMap { file -> (file: URL, size: Int, date: Date, pool: Pool)? in
                    guard let v = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
                    let size = v.fileSize ?? 0
                    let header = size <= maxEntryBytes ? (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Header.self, from: $0) } : nil
                    return (file, size, v.contentModificationDate ?? .distantPast, header.map { pool($0.root) } ?? .browsing)
                }.sorted { $0.date < $1.date }
            var counts = Dictionary(grouping: files, by: \.pool).mapValues(\.count)
            var bytes = files.reduce(0) { $0 + $1.size }
            for entry in files where counts[entry.pool, default: 0] > maxEntriesPerPool || bytes > maxBytes {
                let file = entry.file
                try? FileManager.default.removeItem(at: file)
                counts[entry.pool, default: 0] -= 1; bytes -= entry.size
                memory.removeValue(forKey: file.deletingPathExtension().lastPathComponent)
            }
        } catch { /* Cache failure must never clear visible content or prevent browsing. */ }
    }
    func invalidateFavorites(owner: String, site: GallerySite? = nil, discardSnapshots: Bool = false) {
        guard validOwner(owner) else { return }
        epochs[owner, default: 0] += 1
        // A normal mutation keeps last-known rows for immediate display. Reads
        // always revalidate, so no persisted freshness or dirty flag is needed.
        guard discardSnapshots else { return }
        func affected(_ snapshot: FeedSnapshot) -> Bool {
            snapshot.owner == owner && snapshot.root.path == "/favorites.php" && (site == nil || snapshot.root.host == site?.host)
        }
        memory = memory.filter { !affected($0.value.0) }
        let directory = root.appendingPathComponent(owner, isDirectory: true)
        for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? [] where file.pathExtension == "json" {
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maxEntryBytes,
                  let data = try? Data(contentsOf: file), data.count <= maxEntryBytes,
                  let value = try? JSONDecoder().decode(FeedSnapshot.self, from: data), affected(value) else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
    private func trimMemory() {
        var counts = Dictionary(grouping: memory.values, by: { pool($0.0.root) }).mapValues(\.count)
        var bytes = memory.values.reduce(0) { $0 + $1.1 }
        for entry in memory.sorted(by: { $0.value.0.savedAt < $1.value.0.savedAt }) {
            let pool = pool(entry.value.0.root)
            guard counts[pool, default: 0] > maxEntriesPerPool || bytes > maxBytes else { continue }
            memory.removeValue(forKey: entry.key)
            counts[pool, default: 0] -= 1; bytes -= entry.value.1
        }
    }
}
