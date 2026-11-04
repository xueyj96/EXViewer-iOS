import Foundation
import ExViewerCore

enum FavoriteSyncPhase: String, Codable {
    case queued, sending, checking, uncertain, failed, login
    var label: String {
        switch self {
        case .queued: return "待同步"
        case .sending, .checking: return "同步中"
        case .uncertain: return "结果待确认"
        case .failed: return "同步失败"
        case .login: return "需要登录"
        }
    }
}

/// Persist display state and latest intentions, never credentials, gallery
/// tokens or server forms. Requests use references supplied by active views.
@MainActor final class SiteFavoriteCache: ObservableObject {
    static let refreshInterval: TimeInterval = 600
    static let capacity = 5_000
    struct Entry {
        let state: GalleryFavoriteState
        let form: GalleryFavoriteForm?
        let date: Date
        let version: UUID
        let phase: FavoriteSyncPhase?
        let message: String?
        let pendingGroup: Int?
        let pendingNote: String?
    }
    struct Change: Identifiable {
        let id: String
        let title: String
        let phase: FavoriteSyncPhase
        let message: String?
        let canCheck: Bool
    }
    private struct Value: Codable {
        var known: Bool
        var group: String?
        init(_ state: GalleryFavoriteState) {
            known = state != .unknown
            if case let .favorited(name) = state { group = name }
        }
        var state: GalleryFavoriteState { !known ? .unknown : group.map(GalleryFavoriteState.favorited) ?? .notFavorited }
    }
    private struct Intent: Codable {
        var id = UUID()
        var group: Int?
        var groupName: String?
        var note: String?
        var title: String
        var phase = FavoriteSyncPhase.queued
        var message: String?
        var action: FavoriteAction { group.map(FavoriteAction.move) ?? .remove }
        var state: GalleryFavoriteState { groupName.map(GalleryFavoriteState.favorited) ?? .notFavorited }
    }
    private struct Record: Codable {
        let site: GallerySite
        let gid: Int64
        var confirmed: Value
        var date: Date
        var version = UUID()
        var pending: Intent?
        var id: String { "\(site.rawValue):\(gid)" }
    }
    private struct File: Codable { var version = 1; var records: [Record] }
    private struct Runtime { let scope: GalleryFavoriteScope; let client: GalleryFavoriteClient }
    @Published private(set) var revision = UUID()
    private var records: [String: Record] = [:]
    private var forms: [String: (value: GalleryFavoriteForm, date: Date)] = [:]
    private var runtimes: [String: Runtime] = [:]
    private var observers: [UUID: String] = [:]
    private var queue: [String] = []
    private var checks = Set<String>()
    private var lastChecks: [String: Date] = [:]
    private var mutationEpochs: [String: UUID] = [:]
    private var worker: Task<Void, Never>?
    private var workerID = UUID()
    private var activeKey: String?
    private var owner = ""
    private var generation: UUID?
    private let storageRoot: URL?
    private let clock: () -> Date
    private let limit: Int
    private var storageUnreadable = false

    init(storageRoot: URL? = nil, capacity: Int = SiteFavoriteCache.capacity, now: @escaping () -> Date = Date.init) {
        self.storageRoot = storageRoot; limit = min(Self.capacity, max(1, capacity)); clock = now
    }
    func activate(owner: String, generation: UUID) {
        guard self.owner != owner || self.generation != generation else { return }
        guard owner == "guest" || (!owner.isEmpty && owner.count <= 64 && owner.allSatisfy(\.isHexDigit)) else { return }
        worker?.cancel(); worker = nil; workerID = UUID()
        for key in records.keys {
            if records[key]?.pending?.phase == .sending || records[key]?.pending?.phase == .checking { records[key]?.pending?.phase = .uncertain }
        }
        try? persist(records)
        let sameOwner = self.owner == owner
        let wasUnreadable = storageUnreadable
        self.owner = owner; self.generation = generation
        forms = [:]; runtimes = [:]; observers = [:]; queue = []; checks = []; lastChecks = [:]; mutationEpochs = [:]; activeKey = nil; storageUnreadable = false
        if !sameOwner { records = [:]; restore() } else { storageUnreadable = wasUnreadable }
        revision = UUID()
    }
    private func valid(_ scope: GalleryFavoriteScope) -> Bool { scope.owner == owner && scope.generation == generation }
    private func ensureInitialScope(_ scope: GalleryFavoriteScope) { if generation == nil { activate(owner: scope.owner, generation: scope.generation) } }
    func entry(_ scope: GalleryFavoriteScope) -> Entry? {
        guard valid(scope), let r = records[scope.reference.id] else { return nil }
        return .init(state: r.pending?.state ?? r.confirmed.state, form: forms[r.id]?.value, date: r.date, version: r.version,
                     phase: r.pending?.phase, message: r.pending?.message, pendingGroup: r.pending?.group, pendingNote: r.pending?.note)
    }
    func recent(_ scope: GalleryFavoriteScope, now: Date = Date()) -> Entry? {
        guard let value = entry(scope), value.state != .unknown,
              (0..<Self.refreshInterval).contains(now.timeIntervalSince(forms[scope.reference.id]?.date ?? value.date)) else { return nil }
        return value
    }
    func formIsFresh(_ scope: GalleryFavoriteScope, now: Date = Date()) -> Bool {
        guard valid(scope), let date = forms[scope.reference.id]?.date else { return false }
        return (0..<Self.refreshInterval).contains(now.timeIntervalSince(date))
    }
    func mutationEpoch(_ scope: GalleryFavoriteScope) -> UUID? { valid(scope) ? mutationEpochs[scope.reference.id] : nil }
    @discardableResult func put(_ state: GalleryFavoriteState, form: GalleryFavoriteForm? = nil,
                               scope: GalleryFavoriteScope, expectedVersion: UUID? = nil, conditional: Bool = false, force: Bool = false) -> Bool {
        ensureInitialScope(scope)
        let key = scope.reference.id
        guard valid(scope), !conditional || records[key]?.version == expectedVersion, records[key]?.pending == nil else { return false }
        if let form, form.reference != scope.reference || form.state != state { return false }
        if force { mutationEpochs[key] = UUID() }
        if let form { remember(form, key: key) }
        else if state == .unknown { forms.removeValue(forKey: key) }
        var copy = records
        copy[key] = .init(site: scope.reference.site, gid: scope.reference.gid, confirmed: Value(state), date: clock())
        trim(&copy); records = copy; changed(); return true
    }
    func register(_ id: UUID, scope: GalleryFavoriteScope, client: GalleryFavoriteClient) {
        ensureInitialScope(scope)
        guard valid(scope), client.isCurrent() else { return }
        observers[id] = scope.reference.id; runtimes[scope.reference.id] = .init(scope: scope, client: client)
        if let pending = records[scope.reference.id]?.pending, pending.phase != .failed && pending.phase != .login {
            schedule(scope.reference.id, checkOnly: pending.phase != .queued)
        }
    }
    func unregister(_ id: UUID) {
        if let key = observers.removeValue(forKey: id), !observers.values.contains(key), records[key]?.pending == nil { runtimes.removeValue(forKey: key) }
    }
    func refreshActive() {
        for key in Set(observers.values) {
            guard let record = records[key] else { continue }
            if record.pending != nil || clock().timeIntervalSince(record.date) >= Self.refreshInterval {
                schedule(key, checkOnly: record.pending?.phase != .queued, force: record.pending?.phase == .queued)
            }
        }
    }
    var changes: [Change] {
        records.values.compactMap { r in
            guard let p = r.pending else { return nil }
            return .init(id: r.id, title: p.title, phase: p.phase, message: p.message, canCheck: runtimes[r.id]?.client.isCurrent() == true)
        }.sorted { $0.id < $1.id }
    }
    var cachedCount: Int { records.count }
    var readFailure: String? { storageUnreadable ? "收藏同步记录暂时无法读取，原记录已保留。" : nil }
    func check(_ key: String) { schedule(key, checkOnly: true, force: true) }
    func retry(_ key: String) {
        guard records[key]?.pending?.phase == .failed || records[key]?.pending?.phase == .login || records[key]?.pending?.phase == .queued else { check(key); return }
        records[key]?.pending?.phase = .queued; records[key]?.pending?.message = nil
        changed(); schedule(key, checkOnly: false, force: true)
    }
    func enqueue(scope: GalleryFavoriteScope, client: GalleryFavoriteClient, form: GalleryFavoriteForm,
                 action: FavoriteAction, note: String, title: String) throws {
        guard valid(scope), client.isCurrent(), form.reference == scope.reference else { throw ViewerError.stale }
        _ = try form.request(action: action, note: note)
        guard records.values.filter({ $0.pending != nil }).count < 64 || records[scope.reference.id]?.pending != nil else { throw ViewerError.invalidQuery("待同步操作较多，请稍后再试。") }
        let group: Int?
        if case let .move(index) = action { group = index } else { group = nil }
        let key = scope.reference.id
        var record = records[key] ?? .init(site: scope.reference.site, gid: scope.reference.gid, confirmed: Value(form.state), date: clock())
        record.pending = Intent(group: group, groupName: group.flatMap { i in form.groups.first { $0.id == i }?.name },
                                note: action == .remove ? nil : (note == form.note ? nil : note), title: String(title.prefix(300)))
        record.version = UUID()
        var copy = records; copy[key] = record; trim(&copy)
        try persist(copy)
        records = copy; if forms[key] == nil { remember(form, key: key) }; runtimes[key] = .init(scope: scope, client: client)
        mutationEpochs[key] = UUID()
        revision = UUID(); schedule(key, checkOnly: false)
    }
    func invalidate(_ refs: [GalleryRef], scopeOwner: String, generation: UUID) {
        guard owner == scopeOwner, self.generation == generation else { return }
        for ref in refs where records[ref.id]?.pending == nil { records.removeValue(forKey: ref.id); forms.removeValue(forKey: ref.id); mutationEpochs[ref.id] = UUID() }
        changed()
    }
    func hasPending(_ refs: [GalleryRef]) -> Bool { refs.contains { records[$0.id]?.pending != nil } }
    func seedFavorites(_ galleries: [Gallery], categories: [String: String], url: URL, scopeOwner: String, generation: UUID) {
        guard owner == scopeOwner, self.generation == generation, url.path == "/favorites.php" else { return }
        let category = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "favcat" }?.value
        for gallery in galleries where records[gallery.id]?.pending == nil {
            let existing = records[gallery.id]?.confirmed.state
            let named = category.flatMap { categories[$0] }.map(GalleryFavoriteState.favorited)
            let state: GalleryFavoriteState
            if let named { state = named } else if let existing, case .favorited = existing { state = existing } else { state = .favorited("站点收藏") }
            records[gallery.id] = .init(site: gallery.ref.site, gid: gallery.ref.gid, confirmed: Value(state), date: clock())
        }
        trim(&records); changed()
    }
    private func schedule(_ key: String, checkOnly: Bool, force: Bool = false) {
        guard runtimes[key]?.client.isCurrent() == true else { return }
        if activeKey == key && checkOnly { return }
        if checkOnly, !force, let checked = lastChecks[key], clock().timeIntervalSince(checked) < Self.refreshInterval { return }
        if !checkOnly, !force, records[key]?.pending?.message != nil, let checked = lastChecks[key], clock().timeIntervalSince(checked) < Self.refreshInterval { return }
        if checkOnly { checks.insert(key) } else { checks.remove(key) }
        if !queue.contains(key) { queue.append(key) }
        guard worker == nil else { return }
        let id = UUID(); workerID = id
        worker = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, id == self.workerID, !self.queue.isEmpty {
                let key = self.queue.removeFirst(), onlyCheck = self.checks.remove(key) != nil
                self.activeKey = key
                await self.run(key, checkOnly: onlyCheck, workerID: id)
                if id == self.workerID { self.activeKey = nil }
            }
            if id == self.workerID { self.worker = nil }
        }
    }
    private func run(_ key: String, checkOnly: Bool, workerID: UUID) async {
        guard let runtime = runtimes[key], valid(runtime.scope), runtime.client.isCurrent() else { return }
        defer {
            if self.workerID == workerID, records[key]?.pending == nil, !observers.values.contains(key) { runtimes.removeValue(forKey: key) }
        }
        let target = records[key]?.pending, targetID = records[key]?.pending?.id
        func current() -> Bool { self.workerID == workerID && valid(runtime.scope) && runtime.client.isCurrent() && !Task.isCancelled }
        do {
            var form: GalleryFavoriteForm
            if !checkOnly, formIsFresh(runtime.scope, now: clock()), let memo = forms[key]?.value { form = memo }
            else { lastChecks[key] = clock(); form = try await runtime.client.read() }
            guard current() else { return }
            if let target, !checkOnly {
                guard records[key]?.pending?.id == target.id else { schedule(key, checkOnly: false); return }
                let note = target.note ?? form.note
                if !form.confirms(target.action, note: note) {
                    let request = try form.request(action: target.action, note: note)
                    records[key]?.pending?.phase = .sending
                    try persist(records); revision = UUID()
                    await runtime.client.willSubmit()
                    guard current() else { return }
                    var postError: Error?
                    do { try await runtime.client.submit(request) } catch { postError = error }
                    guard current() else { return }
                    if records[key]?.pending?.id == target.id { records[key]?.pending?.phase = .checking; changed() }
                    lastChecks[key] = clock()
                    do { form = try await runtime.client.read() }
                    catch {
                        guard current() else { return }
                        if records[key]?.pending?.id == target.id {
                            records[key]?.pending?.phase = (postError as? ViewerError) == .authentication || (error as? ViewerError) == .authentication ? .login : .uncertain
                            records[key]?.pending?.message = "暂时无法确认是否已生效，请检查结果。"
                        }
                        forms.removeValue(forKey: key); changed(); runtime.client.didSubmit(); return
                    }
                    runtime.client.didSubmit()
                }
            }
            guard current() else { return }
            remember(form, key: key)
            if var record = records[key] {
                record.confirmed = Value(form.state); record.date = clock(); record.version = UUID()
                if let target, record.pending?.id == targetID {
                    if form.confirms(target.action, note: target.note ?? form.note) { record.pending = nil }
                    else { record.pending?.phase = .failed; record.pending?.message = "未能同步，已保留本次更改。" }
                }
                records[key] = record
                if target != nil { mutationEpochs[key] = UUID() }
                changed()
                if record.pending != nil && record.pending?.id != targetID { schedule(key, checkOnly: false) }
            }
        } catch {
            guard current() else { return }
            if records[key]?.pending?.id == targetID, targetID != nil {
                let uncertain = checkOnly && (target?.phase == .uncertain || target?.phase == .checking || target?.phase == .sending)
                let transport = (error as? URLError).map { [.timedOut, .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains($0.code) } == true
                let unsent = !checkOnly && target?.phase == .queued && (transport || (error as? RequestFailure)?.canRetryWhenVisible == true || (error as? ViewerError) == .network)
                records[key]?.pending?.phase = (error as? ViewerError) == .authentication ? .login : uncertain ? .uncertain : unsent ? .queued : .failed
                records[key]?.pending?.message = (error as? ViewerError) == .authentication ? "站点要求登录，请登录后继续同步。" : uncertain ? "暂时无法确认是否已生效，请检查结果。" : unsent ? "暂时无法连接，请稍后重试。" : "未能同步，已保留本次更改。"
                changed()
            }
        }
    }
    private func remember(_ form: GalleryFavoriteForm, key: String) {
        forms[key] = (form, clock())
        if forms.count > 64, let old = forms.min(by: { $0.value.date < $1.value.date })?.key { forms.removeValue(forKey: old) }
    }
    private func changed() { try? persist(records); revision = UUID() }
    private func trim(_ copy: inout [String: Record]) {
        for r in copy.values.filter({ $0.pending == nil }).sorted(by: { $0.date < $1.date }).prefix(max(0, copy.count - limit)) {
            copy.removeValue(forKey: r.id); forms.removeValue(forKey: r.id)
        }
    }
    private var file: URL? { storageRoot?.appendingPathComponent(owner, isDirectory: true).appendingPathComponent("site-favorites.json") }
    private func persist(_ values: [String: Record]) throws {
        guard let file, !owner.isEmpty else { return }
        guard !storageUnreadable else { throw ViewerError.invalidQuery("收藏同步记录暂时无法读取，原记录已保留。") }
        var saved = values.values.sorted { $0.date < $1.date }
        var data = try JSONEncoder().encode(File(records: saved))
        while data.count > 2_000_000 {
            let removable = Set(saved.filter { $0.pending == nil }.prefix(max(1, saved.count / 4)).map(\.id))
            guard !removable.isEmpty else { throw ViewerError.storage }
            saved.removeAll { removable.contains($0.id) }
            data = try JSONEncoder().encode(File(records: saved))
        }
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var location = directory; var attributes = URLResourceValues(); attributes.isExcludedFromBackup = true; try location.setResourceValues(attributes)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    private func restore() {
        guard let file, FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 2_000_000 else { throw ViewerError.storage }
            let saved = try JSONDecoder().decode(File.self, from: Data(contentsOf: file))
            guard saved.version == 1, saved.records.count <= limit, Set(saved.records.map(\.id)).count == saved.records.count,
                  saved.records.allSatisfy({ $0.gid > 0 && ($0.pending?.group.map { (0...9).contains($0) } ?? true) }) else { throw ViewerError.storage }
            records = Dictionary(uniqueKeysWithValues: saved.records.map { value in
                var value = value
                if value.pending?.phase == .sending || value.pending?.phase == .checking { value.pending?.phase = .uncertain }
                return (value.id, value)
            })
        } catch { storageUnreadable = true }
    }
}
