import Foundation
import ExViewerCore

struct ReadingRecord: Codable, Identifiable {
    var gallery: Gallery
    var page: Int
    var date: Date
    var id: String { gallery.id }
}
struct DownloadRecord: Codable, Identifiable {
    enum Status: String, Codable { case waiting, downloading, paused, complete, failed }
    var gallery: Gallery
    var status: Status
    var completed: [Int: String] = [:]
    var total: Int?
    var error: String?
    var replaces: GalleryRef? = nil
    var id: String { gallery.id }
    var requiresRetry: Bool { status == .failed || (status == .paused && error != nil) }
}
struct LibrarySnapshot: Codable {
    var version = 1
    var saved: [SavedSearch] = []
    var favoriteTags: [GalleryTag] = []
    var blockedTags: [GalleryTag] = []
    var bookmarks: [Gallery] = []
    // Keep the v1 storage key and original order. Reinterpreting old bookmarks
    // as read-later intent needs no duplicate import or invented timestamp.
    var readLater: [Gallery] {
        get { bookmarks }
        set { bookmarks = newValue }
    }
    var history: [ReadingRecord] = []
    var downloads: [DownloadRecord] = []
}

struct RecentSearchRecord: Codable, Identifiable {
    var id = UUID()
    var site: GallerySite
    var query: SearchQuery
    var date: Date

    static func requestKey(site: GallerySite, query: SearchQuery) throws -> String {
        var canonical = query
        canonical.rules.sort {
            $0.id == $1.id ? $0.match.rawValue < $1.match.rawValue : $0.id < $1.id
        }
        return try canonical.url(site: site).absoluteString
    }
}

private struct RecentSearchFile: Codable {
    var version = 1
    var entries: [RecentSearchRecord]
}

@MainActor final class LibraryStore: ObservableObject {
    struct ReadLaterNotice: Identifiable { let id = UUID(); let text: String }
    @Published private(set) var readLaterNotice: ReadLaterNotice?
    @Published private(set) var snapshot = LibrarySnapshot()
    @Published private(set) var recentSearches: [RecentSearchRecord] = []
    @Published private(set) var searchHistoryError: String?
    @Published var error: String?
    @Published private(set) var owner = "guest"
    private let root: URL
    private let ephemeral: Bool
    private var offlineReaders: [UUID: (owner: String, gallery: GalleryRef)] = [:]
    var directory: URL { root.appendingPathComponent(owner, isDirectory: true) }
    var blockedIDs: Set<String> { Set(snapshot.blockedTags.map(\.id)) }
    static let searchHistoryLimit = 100
    private var searchHistoryFile: URL { directory.appendingPathComponent("recent-searches.json") }
    init(qa: Bool = false, storageRoot: URL? = nil) {
        ephemeral = qa
        root = storageRoot ?? (qa ? FileManager.default.temporaryDirectory.appendingPathComponent("ExViewer-QA-" + UUID().uuidString) : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ExViewer", isDirectory: true))
        load(owner: "guest")
    }
    func load(owner: String) {
        guard owner == "guest" || owner.allSatisfy({ $0.isHexDigit }) else { return }
        self.owner = owner; snapshot = LibrarySnapshot(); error = nil; readLaterNotice = nil
        recentSearches = []; searchHistoryError = nil
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var location = directory; var attributes = URLResourceValues(); attributes.isExcludedFromBackup = true; try location.setResourceValues(attributes)
            let file = directory.appendingPathComponent("library.json")
            if FileManager.default.fileExists(atPath: file.path) {
                let data = try Data(contentsOf: file)
                guard data.count < 12_000_000 else { throw ViewerError.storage }
                let value = try JSONDecoder().decode(LibrarySnapshot.self, from: data)
                guard value.version == 1 else { throw ViewerError.storage }
                snapshot = value
                for i in snapshot.downloads.indices where snapshot.downloads[i].status == .downloading {
                    snapshot.downloads[i].status = .waiting
                }
            }
            let offline = directory.appendingPathComponent("Offline", isDirectory: true)
            if FileManager.default.fileExists(atPath: offline.path) {
                let staged = try FileManager.default.contentsOfDirectory(at: offline, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent.hasSuffix(".pending-removal") }
                for item in staged {
                    let folder = String(item.lastPathComponent.dropFirst().dropLast(".pending-removal".count))
                    if let record = snapshot.downloads.first(where: { $0.id.replacingOccurrences(of: ":", with: "-") == folder }) {
                        let original = offlineDirectory(record.gallery)
                        guard !FileManager.default.fileExists(atPath: original.path) else { throw ViewerError.storage }
                        try FileManager.default.moveItem(at: item, to: original)
                    } else { try FileManager.default.removeItem(at: item) }
                }
            }
        } catch { self.error = "资料库暂时无法读取，原文件已保留。请重试，避免覆盖。" }
        loadSearchHistory()
        if LibrarySelectionQA.seedsBlockedTags(isQA: ephemeral, arguments: ProcessInfo.processInfo.arguments) {
            var qaSnapshot = snapshot
            qaSnapshot.blockedTags = LibrarySelectionQA.blockedTags
            snapshot = qaSnapshot
        }
        if ephemeral && ProcessInfo.processInfo.arguments.contains("--qa-library-sort") {
            snapshot = QASamples.sortingLibrary
        }
        retireReplacedDownloads()
    }

    private func loadSearchHistory() {
        guard FileManager.default.fileExists(atPath: searchHistoryFile.path) else { return }
        do {
            let data = try Data(contentsOf: searchHistoryFile)
            guard data.count < 256_000 else { throw ViewerError.storage }
            let file = try JSONDecoder().decode(RecentSearchFile.self, from: data)
            guard file.version == 1, file.entries.count <= Self.searchHistoryLimit,
                  Set(file.entries.map(\.id)).count == file.entries.count else { throw ViewerError.storage }
            for entry in file.entries {
                // A legacy record may have contained only the retired local
                // sort setting. It still opens the unfiltered gallery feed.
                _ = try entry.query.url(site: entry.site)
            }
            recentSearches = file.entries
        } catch { searchHistoryError = "搜索记录暂时无法读取，原文件已保留；可清空搜索记录后重新记录。" }
    }

    @discardableResult private func saveSearchHistory(_ entries: [RecentSearchRecord], resetting: Bool = false) -> Bool {
        guard searchHistoryError == nil || resetting else { return false }
        do {
            let data = try JSONEncoder().encode(RecentSearchFile(entries: entries))
            guard data.count < 256_000 else { throw ViewerError.storage }
            try data.write(to: searchHistoryFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            recentSearches = entries; searchHistoryError = nil
            return true
        } catch { searchHistoryError = "搜索记录保存失败，原有记录保留；请检查本机空间。"; return false }
    }

    @discardableResult func recordSearch(query: SearchQuery, site: GallerySite, date: Date = Date()) -> Bool {
        guard query.hasSettings, let key = try? RecentSearchRecord.requestKey(site: site, query: query) else { return false }
        var entries = recentSearches
        let existing = entries.firstIndex { (try? RecentSearchRecord.requestKey(site: $0.site, query: $0.query)) == key }
        let id = existing.map { entries.remove(at: $0).id } ?? UUID()
        entries.insert(RecentSearchRecord(id: id, site: site, query: query, date: date), at: 0)
        return saveSearchHistory(Array(entries.prefix(Self.searchHistoryLimit)))
    }

    @discardableResult func deleteRecentSearch(_ id: UUID) -> Bool {
        saveSearchHistory(recentSearches.filter { $0.id != id })
    }

    @discardableResult func clearSearchHistory() -> Bool { saveSearchHistory([], resetting: true) }

    func savedSearch(matching query: SearchQuery, site: GallerySite) -> SavedSearch? {
        guard let key = try? RecentSearchRecord.requestKey(site: site, query: query) else { return nil }
        return snapshot.saved.first { (try? RecentSearchRecord.requestKey(site: $0.site, query: $0.query)) == key }
    }
    @discardableResult private func commit(_ mutate: (inout LibrarySnapshot) -> Void) -> Bool {
        guard error == nil else { return false }
        var copy = snapshot; mutate(&copy)
        do {
            let data = try JSONEncoder().encode(copy)
            guard data.count < 12_000_000 else { throw ViewerError.storage }
            try data.write(to: directory.appendingPathComponent("library.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            snapshot = copy
            return true
        } catch { self.error = "保存失败，当前资料保留。请检查本机空间。"; return false }
    }
    @discardableResult func saveSearch(name: String, site: GallerySite, query: SearchQuery, replacing: UUID? = nil, expectedOwner: String? = nil) -> UUID? {
        guard expectedOwner == nil || expectedOwner == owner else { return nil }
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !name.isEmpty, replacing != nil || snapshot.saved.count < 200 else { return nil }
        if let replacing, !snapshot.saved.contains(where: { $0.id == replacing }) { return nil }
        var record = SavedSearch(name: name, site: site, query: query)
        if let replacing { record.id = replacing }
        let success = commit { value in
            if let index = value.saved.firstIndex(where: { $0.id == record.id }) { value.saved[index] = record }
            else { value.saved.append(record) }
        }
        return success ? record.id : nil
    }
    @discardableResult func moveSavedSearches(from offsets: IndexSet, to destination: Int, expectedOwner: String) -> Bool {
        guard expectedOwner == owner, destination >= 0, destination <= snapshot.saved.count,
              offsets.allSatisfy({ snapshot.saved.indices.contains($0) }) else { return false }
        guard !offsets.isEmpty else { return true }
        let moving = offsets.map { snapshot.saved[$0] }
        var reordered = snapshot.saved.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        let insertion = destination - offsets.filter { $0 < destination }.count
        reordered.insert(contentsOf: moving, at: insertion)
        guard reordered.map(\.id) != snapshot.saved.map(\.id) else { return true }
        return commit { $0.saved = reordered }
    }
    @discardableResult func deleteSearch(_ id: UUID) -> Bool {
        guard snapshot.saved.contains(where: { $0.id == id }) else { return false }
        return commit { $0.saved.removeAll { $0.id == id } }
    }
    func pin(_ tag: GalleryTag) { pin([tag]) }
    @discardableResult func pin(_ tags: [GalleryTag]) -> Bool {
        var seen = Set(snapshot.favoriteTags.map(\.id))
        let additions = tags.filter { seen.insert($0.id).inserted }
        guard !additions.isEmpty else { return true }
        return commit { $0.favoriteTags.append(contentsOf: additions) }
    }
    func unpin(_ tag: GalleryTag) { commit { $0.favoriteTags.removeAll { $0.id == tag.id } } }
    func block(_ tag: GalleryTag) { block([tag]) }
    @discardableResult func block(_ tags: [GalleryTag]) -> Bool {
        var seen = blockedIDs
        let additions = tags.filter { seen.insert($0.id).inserted }
        guard !additions.isEmpty else { return true }
        return commit { $0.blockedTags.append(contentsOf: additions) }
    }
    func unblock(_ tag: GalleryTag) { unblock([tag]) }
    @discardableResult func unblock(_ tags: [GalleryTag]) -> Bool {
        let ids = Set(tags.map(\.id))
        guard !ids.isDisjoint(with: blockedIDs) else { return true }
        return commit { $0.blockedTags.removeAll { ids.contains($0.id) } }
    }
    func containsReadLater(_ gallery: Gallery) -> Bool { snapshot.readLater.contains { $0.id == gallery.id } }
    @discardableResult func addReadLater(_ galleries: [Gallery]) -> Int? {
        guard error == nil else { return nil }
        var existing = Set(snapshot.readLater.map(\.id))
        let additions = galleries.filter { existing.insert($0.id).inserted }.map(\.stored)
        guard !additions.isEmpty else { return 0 }
        return commit { $0.readLater.insert(contentsOf: additions, at: 0) } ? additions.count : nil
    }
    @discardableResult func toggleReadLater(_ gallery: Gallery) -> Bool {
        setReadLater(gallery, included: !containsReadLater(gallery))
    }
    @discardableResult func setReadLater(_ gallery: Gallery, included: Bool) -> Bool {
        let saved = included ? addReadLater([gallery]) != nil : commit { $0.readLater.removeAll { $0.id == gallery.id } }
        readLaterNotice = .init(text: saved ? (included ? "已加入稍后再读" : "已移出稍后再读") : "稍后再读未能保存，请重试")
        return saved
    }
    @discardableResult func removeReadLater(_ ids: Set<String>) -> Bool {
        let saved = commit { $0.readLater.removeAll { ids.contains($0.id) } }
        readLaterNotice = .init(text: saved ? "所选作品已移出稍后再读" : "稍后再读未能保存，请重试")
        return saved
    }
    func dismissReadLaterNotice(_ id: UUID) { if readLaterNotice?.id == id { readLaterNotice = nil } }
    // Compatibility for older callers and saved QA fixtures; one collection.
    func bookmark(_ gallery: Gallery) { toggleReadLater(gallery) }
    func remember(_ gallery: Gallery, page: Int) {
        guard page > 0 else { return }
        commit { value in value.history.removeAll { $0.id == gallery.id }; value.history.insert(.init(gallery: gallery.stored, page: page, date: Date()), at: 0); value.history = Array(value.history.prefix(500)) }
    }
    func updateDownload(_ incoming: DownloadRecord, checkpoint: Bool = true) {
        var record = incoming
        if let old = record.replaces, download(for: old)?.status != .complete { record.replaces = nil }
        if !checkpoint {
            // The files are already durable. Keep the live count responsive
            // while leaving the next atomic snapshot write to the checkpoint.
            guard error == nil, let index = snapshot.downloads.firstIndex(where: { $0.id == record.id }) else { return }
            snapshot.downloads[index] = record
            return
        }
        commit { value in
            if let index = value.downloads.firstIndex(where: { $0.id == record.id }) {
                value.downloads[index] = record
            } else {
                value.downloads.append(record)
            }
        }
    }
    func addDownloadJobs(_ galleries: [Gallery]) -> Int? {
        guard error == nil else { return nil }
        var existing = Set(snapshot.downloads.map(\.id))
        let additions = galleries.filter { existing.insert($0.id).inserted }.map {
            DownloadRecord(gallery: $0.stored, status: .waiting, total: $0.pages)
        }
        guard !additions.isEmpty else { return 0 }
        return commit { $0.downloads.append(contentsOf: additions) } ? additions.count : nil
    }
    func offlineDirectory(_ gallery: Gallery) -> URL { directory.appendingPathComponent("Offline/" + gallery.id.replacingOccurrences(of: ":", with: "-"), isDirectory: true) }
    func download(for reference: GalleryRef) -> DownloadRecord? {
        snapshot.downloads.first { $0.gallery.ref == reference }
    }
    func readableDownload(for gallery: Gallery) -> DownloadRecord? {
        guard let record = download(for: gallery.ref), !record.completed.isEmpty else { return nil }
        let metadata = gallery.tagsComplete ? gallery : record.gallery
        guard TagFilter.decision(tags: metadata.tags, blocked: blockedIDs, complete: metadata.tagsComplete) == .visible else { return nil }
        return record
    }
    func downloadedPage(_ index: Int, in record: DownloadRecord) -> GalleryPage? {
        guard index > 0, let name = record.completed[index], name == "page-\(index).media" else { return nil }
        let url = offlineDirectory(record.gallery).appendingPathComponent(name)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        return GalleryPage(index: index, url: url)
    }

    func downloadedPages(_ record: DownloadRecord) -> [GalleryPage] {
        record.completed.keys.sorted().compactMap { downloadedPage($0, in: record) }
    }

    func pinOfflineReader(_ gallery: GalleryRef, context: UUID) {
        offlineReaders[context] = (owner, gallery)
    }

    func unpinOfflineReader(context: UUID) {
        guard offlineReaders.removeValue(forKey: context)?.owner == owner else { return }
        retireReplacedDownloads()
    }

    /// Persist the replacement before retiring the old directory. A crash
    /// between these operations leaves both copies readable until the next load.
    func retireReplacedDownloads() {
        guard error == nil else { return }
        let retired = Set(snapshot.downloads.compactMap { replacement -> String? in
            guard replacement.status == .complete, let old = replacement.replaces,
                  old.site == replacement.gallery.ref.site, old.gid < replacement.gallery.ref.gid,
                  download(for: old)?.status == .complete,
                  !offlineReaders.values.contains(where: { $0.owner == owner && $0.gallery == old }),
                  let total = replacement.total, total > 0 else { return nil }
            let pages = downloadedPages(replacement)
            guard pages.count == total, pages.first?.index == 1, pages.last?.index == total else { return nil }
            return old.id
        })
        if !retired.isEmpty { _ = removeDownloads(retired) }
    }

    func removeDownloads(_ ids: Set<String>) -> Bool {
        guard error == nil else { return false }
        guard !ids.isEmpty else { return true }
        let manager = FileManager.default
        var moves: [(original: URL, staged: URL)] = []
        do {
            for record in snapshot.downloads where ids.contains(record.id) {
                let path = offlineDirectory(record.gallery)
                guard manager.fileExists(atPath: path.path) else { continue }
                let staged = path.deletingLastPathComponent().appendingPathComponent("." + path.lastPathComponent + ".pending-removal")
                try manager.moveItem(at: path, to: staged)
                moves.append((path, staged))
            }
            guard commit({ value in
                let refs = Set(value.downloads.filter { ids.contains($0.id) }.map(\.gallery.ref))
                value.downloads.removeAll { ids.contains($0.id) }
                for index in value.downloads.indices where value.downloads[index].replaces.map(refs.contains) == true {
                    value.downloads[index].replaces = nil
                }
            }) else { throw ViewerError.storage }
        } catch {
            for move in moves.reversed() { try? manager.moveItem(at: move.staged, to: move.original) }
            self.error = "本机副本未能移除，请重试。"
            return false
        }
        do {
            for move in moves { try manager.removeItem(at: move.staged) }
        } catch {
            self.error = "下载记录已移除，文件清理将在重试时完成。"
        }
        return true
    }
}


enum SearchPresentation {
    private static let headerCatalog = TagTranslationCatalog.bundled
    private enum ConditionStyle { case full, header, preset }

    static func headerTitle(_ query: SearchQuery, savedName: String?) -> String {
        if !query.hasSettings { return "关键词、标签与条件" }
        if !query.text.isEmpty { return query.text }
        if let savedName { return savedName }
        if !query.artist.isEmpty { return "作者 \(query.artist)" }
        return "筛选结果"
    }

    /// Compact previews and their counters share the same filter items.
    /// Keywords have their own input/title and are excluded from filter badges.
    static func headerDetails(_ query: SearchQuery) -> String {
        let value = compactConditions(query)
        return value.isEmpty ? (query.text.isEmpty ? "全部画廊" : "关键词搜索") : value
    }

    static func compactConditions(_ query: SearchQuery) -> String {
        let values = conditionItems(query, includeText: false, style: .header)
        let preview = values.prefix(2).joined(separator: " · ")
        return values.count > 2 ? "\(preview) · 另\(values.count - 2)项条件" : preview
    }

    static func presetPreview(_ query: SearchQuery, includeText: Bool = true) -> (conditions: String, limits: String) {
        let items = conditionItems(query, includeText: includeText, style: .preset)
        let limits = ratingAndPageItems(query, compact: true).joined(separator: " · ")
        let summary = items.prefix(2).joined(separator: " · ")
        if summary.isEmpty { return (limits.isEmpty ? "全部画廊" : "", limits) }
        return (items.count > 2 ? summary + "…" : summary, limits)
    }

    static func conditionCount(_ query: SearchQuery, includeText: Bool = false) -> Int {
        conditionItems(query, includeText: includeText).count
    }

    static func summary(_ query: SearchQuery, site: GallerySite) -> String {
        let scope = site == .ex ? "EX" : "EH"
        let detail = conditions(query)
        return detail.isEmpty ? scope : "\(scope) · \(detail)"
    }

    static func recordTitle(_ query: SearchQuery) -> String {
        if !query.text.isEmpty { return query.text }
        if !query.artist.isEmpty { return "作者 \(query.artist)" }
        if let rule = query.rules.first { return "\(rule.match.name) \(rule.tag.label)" }
        return "筛选搜索"
    }

    static func conditions(_ query: SearchQuery, includeText: Bool = true) -> String {
        conditionItems(query, includeText: includeText).joined(separator: " · ")
    }

    private static func conditionItems(_ query: SearchQuery, includeText: Bool,
                                       style: ConditionStyle = .full) -> [String] {
        var values: [String] = []
        if includeText && !query.text.isEmpty { values.append(query.text) }
        if query.titleOnly { values.append("仅标题") }
        if query.matchPhrase { values.append("完整短语") }
        if !query.artist.isEmpty { values.append("作者 \(query.artist)") }
        for rule in query.rules {
            let translated = style == .full ? nil : headerCatalog?.translation(for: rule.tag)
            let name = translated.flatMap { $0.isEmpty ? nil : $0 } ?? (style == .preset ? rule.tag.name : rule.tag.label)
            values.append(style == .preset && rule.match == .all ? name : "\(rule.match.name) \(name)")
        }
        let categories = GalleryCategory.all.filter { query.excludedCategories.contains($0.id) }.map(\.name)
        if !categories.isEmpty { values.append("排除分类 \(categories.joined(separator: "、"))") }
        if style != .preset { values += ratingAndPageItems(query) }
        if !query.uploader.isEmpty { values.append("上传者 \(query.uploader)") }
        if query.requireTorrent { values.append("torrent") }
        return values
    }

    private static func ratingAndPageItems(_ query: SearchQuery, compact: Bool = false) -> [String] {
        var values: [String] = []
        if let rating = query.minRating { values.append(compact ? "≥\(rating) 星" : "≥\(rating)星") }
        switch (query.minPages, query.maxPages) {
        case let (minimum?, maximum?): values.append("\(minimum)–\(maximum) 页")
        case let (minimum?, nil): values.append(compact ? "≥\(minimum) 页" : "至少 \(minimum) 页")
        case let (nil, maximum?): values.append(compact ? "≤\(maximum) 页" : "最多 \(maximum) 页")
        case (nil, nil): break
        }
        return values
    }
}
