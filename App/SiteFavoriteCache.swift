import Foundation
import ExViewerCore

enum FavoriteSyncPhase: String, Codable, Sendable {
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
    private static let pendingLimit = 64
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
        let action: String
        let groupName: String?

        init(id: String, title: String, phase: FavoriteSyncPhase, message: String?, canCheck: Bool,
             action: String = "", groupName: String? = nil) {
            self.id = id; self.title = title; self.phase = phase; self.message = message; self.canCheck = canCheck
            self.action = action; self.groupName = groupName
        }
    }
    struct BatchAddition {
        let scope: GalleryFavoriteScope
        let client: GalleryFavoriteClient
        let title: String
        let groupName: String
        var group: Int? = nil
    }
    private struct Value: Codable, Sendable {
        var known: Bool
        var group: String?
        var groupIndex: Int?
        init(_ state: GalleryFavoriteState, groupIndex: Int? = nil) {
            known = state != .unknown
            if case let .favorited(name) = state { group = name; self.groupIndex = groupIndex }
        }
        var state: GalleryFavoriteState { !known ? .unknown : group.map(GalleryFavoriteState.favorited) ?? .notFavorited }
    }
    private struct Intent: Codable, Sendable {
        var id = UUID()
        var group: Int?
        var groupName: String?
        var note: String?
        var title: String
        var phase = FavoriteSyncPhase.queued
        var message: String?
        var addIfMissing: Bool?
        var optimisticToggle: Bool?
        var action: FavoriteAction { group.map(FavoriteAction.move) ?? .remove }
        var state: GalleryFavoriteState { groupName.map(GalleryFavoriteState.favorited) ?? .notFavorited }
    }
    private struct Record: Codable, Sendable {
        let site: GallerySite
        let gid: Int64
        var confirmed: Value
        var date: Date
        var version = UUID()
        var pending: Intent?
        var id: String { "\(site.rawValue):\(gid)" }
    }
    private struct File: Codable, Sendable { var version = 1; var records: [Record] }
    private struct Runtime { let scope: GalleryFavoriteScope; let client: GalleryFavoriteClient }
    @Published private(set) var revision = UUID()
    @Published private(set) var confirmedRemovals: [String: UUID] = [:]
    private var records: [String: Record] = [:]
    private var forms: [String: (value: GalleryFavoriteForm, date: Date)] = [:]
    private var runtimes: [String: Runtime] = [:]
    private var observers: [UUID: String] = [:]
    private var queue: [String] = []
    private var checks = Set<String>()
    private var lastChecks: [String: Date] = [:]
    private var mutationEpochs: [String: UUID] = [:]
    private var groupNameEpochs: [GallerySite: UUID] = [:]
    private var groupNames: [GallerySite: [String]] = [:]
    private var worker: Task<Void, Never>?
    private var workerID = UUID()
    private var activeKey: String?
    private var owner = ""
    private var generation: UUID?
    private let storageRoot: URL?
    private let clock: () -> Date
    private let limit: Int
    private var storageUnreadable = false
    private var persistenceFailure: String?
    private struct OwnerSnapshot { var records: [String: Record]; var unreadable: Bool }
    private var owners: [String: OwnerSnapshot] = [:]
    private let persistence: Persistence
    private var persistenceTail: Task<Void, Error>?
    private var persistenceID = UUID()
    private var pendingWrites = 0
    var pendingPersistenceWriteCount: Int { pendingWrites }
    private let lifecycleBackgroundWork: DownloadBackgroundWork?
    private var lifecycleFlushTask: Task<Void, Never>?
    private var lifecycleFlushID: UUID?
    private var mutationBusy = false
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

    /// Only immutable value snapshots cross this actor boundary. Encoding,
    /// sorting, file attributes and atomic replacement never run on MainActor.
    private actor Persistence {
        let beforeWrite: (@Sendable () throws -> Void)?
        init(beforeWrite: (@Sendable () throws -> Void)?) { self.beforeWrite = beforeWrite }
        func write(_ values: [String: Record], to file: URL) throws {
            try beforeWrite?()
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
            var location = directory; var attributes = URLResourceValues(); attributes.isExcludedFromBackup = true
            try location.setResourceValues(attributes)
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    init(storageRoot: URL? = nil, capacity: Int = SiteFavoriteCache.capacity, now: @escaping () -> Date = Date.init,
         backgroundWork: DownloadBackgroundWork? = nil,
         beforePersistence: (@Sendable () throws -> Void)? = nil) {
        self.storageRoot = storageRoot; limit = min(Self.capacity, max(1, capacity)); clock = now
        persistence = Persistence(beforeWrite: beforePersistence)
        lifecycleBackgroundWork = backgroundWork ?? (storageRoot == nil ? nil : BackgroundWork())
    }
    func activate(owner: String, generation: UUID) {
        guard self.owner != owner || self.generation != generation else { return }
        guard owner == "guest" || (!owner.isEmpty && owner.count <= 64 && owner.allSatisfy(\.isHexDigit)) else { return }
        worker?.cancel(); worker = nil; workerID = UUID()
        for key in records.keys {
            if records[key]?.pending?.phase == .sending || records[key]?.pending?.phase == .checking { records[key]?.pending?.phase = .uncertain }
        }
        if !self.owner.isEmpty {
            owners[self.owner] = .init(records: records, unreadable: storageUnreadable)
            checkpoint()
        }
        let sameOwner = self.owner == owner
        let wasUnreadable = storageUnreadable
        self.owner = owner; self.generation = generation; persistenceFailure = nil
        forms = [:]; runtimes = [:]; observers = [:]; queue = []; checks = []; lastChecks = [:]; mutationEpochs = [:]; activeKey = nil; storageUnreadable = false
        groupNameEpochs = [:]; groupNames = [:]
        if !sameOwner {
            if let saved = owners[owner] { records = saved.records; storageUnreadable = saved.unreadable }
            else { records = [:]; restore() }
        } else { storageUnreadable = wasUnreadable }
        confirmedRemovals = [:]
        revision = UUID()
    }
    private func valid(_ scope: GalleryFavoriteScope) -> Bool { scope.owner == owner && scope.generation == generation }
    private func ensureInitialScope(_ scope: GalleryFavoriteScope) { if generation == nil { activate(owner: scope.owner, generation: scope.generation) } }
    func entry(_ scope: GalleryFavoriteScope) -> Entry? {
        guard valid(scope), let r = records[scope.reference.id] else { return nil }
        let state = r.pending?.addIfMissing == true && r.pending?.optimisticToggle != true ? r.confirmed.state : r.pending?.state ?? r.confirmed.state
        return .init(state: state, form: forms[r.id]?.value, date: r.date, version: r.version,
                     phase: r.pending?.phase, message: r.pending?.message, pendingGroup: r.pending?.group, pendingNote: r.pending?.note)
    }
    /// A newer confirmed local change takes precedence over a stale list snapshot.
    /// Pending removals still follow the existing server-confirmation contract.
    func includesCachedFavorite(_ scope: GalleryFavoriteScope, category: Int?, savedAt: Date) -> Bool {
        guard valid(scope), let record = records[scope.reference.id], record.date > savedAt else { return true }
        switch record.confirmed.state {
        case .notFavorited: return false
        case .favorited:
            if let category, let confirmed = record.confirmed.groupIndex { return category == confirmed }
            return true
        case .unknown: return true
        }
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
        copy[key] = .init(site: scope.reference.site, gid: scope.reference.gid,
                          confirmed: confirmedValue(state, site: scope.reference.site, form: form, previous: records[key]?.confirmed), date: clock())
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
        // Unsent edits keep their client after the detail view closes.
        let queued = runtimes.keys.filter { records[$0]?.pending?.phase == .queued }
        for key in Set(observers.values).union(queued) where key != activeKey {
            guard let record = records[key] else { continue }
            if record.pending != nil || clock().timeIntervalSince(record.date) >= Self.refreshInterval {
                schedule(key, checkOnly: record.pending?.phase != .queued, force: record.pending?.phase == .queued)
            }
        }
    }
    var changes: [Change] {
        records.values.compactMap { r in
            guard let p = r.pending else { return nil }
            let action: String
            if p.group == nil { action = "取消收藏" }
            else if p.addIfMissing == true || (r.confirmed.known && r.confirmed.group == nil) { action = "加入收藏" }
            else { action = r.confirmed.known ? "调整分组" : "收藏到分组" }
            return .init(id: r.id, title: p.title, phase: p.phase, message: p.message,
                         canCheck: runtimes[r.id]?.client.isCurrent() == true,
                         action: action, groupName: p.groupName)
        }.sorted { $0.id < $1.id }
    }
    var cachedCount: Int { records.count }
    var readFailure: String? { storageUnreadable ? "同步记录暂不可读 原记录保留" : persistenceFailure }
    func check(_ key: String) { schedule(key, checkOnly: true, force: true) }
    func retry(_ key: String) {
        guard records[key]?.pending?.phase == .failed || records[key]?.pending?.phase == .login || records[key]?.pending?.phase == .queued else { check(key); return }
        records[key]?.pending?.phase = .queued; records[key]?.pending?.message = nil
        changed(); schedule(key, checkOnly: false, force: true)
    }
    func enqueue(scope: GalleryFavoriteScope, client: GalleryFavoriteClient, form: GalleryFavoriteForm,
                 action: FavoriteAction, note: String, title: String) async throws {
        await acquireMutation(); defer { releaseMutation() }
        guard valid(scope), client.isCurrent(), form.reference == scope.reference else { throw ViewerError.stale }
        _ = try form.request(action: action, note: note)
        guard records.values.filter({ $0.pending != nil }).count < Self.pendingLimit || records[scope.reference.id]?.pending != nil else { throw ViewerError.invalidQuery("待同步操作较多 请稍后再试") }
        let group: Int?
        if case let .move(index) = action { group = index } else { group = nil }
        let key = scope.reference.id
        let intent = Intent(group: group, groupName: group.flatMap { i in form.groups.first { $0.id == i }?.name },
                            note: action == .remove ? nil : (note == form.note ? nil : note), title: String(title.prefix(300)))
        try await persistResolution(resolve: {
            guard self.valid(scope), client.isCurrent() else { throw ViewerError.stale }
            var copy = self.records
            var record = copy[key] ?? .init(site: scope.reference.site, gid: scope.reference.gid,
                                           confirmed: Value(form.state), date: self.clock())
            record.pending = intent; record.version = UUID()
            copy[key] = record; self.trim(&copy)
            return copy
        }, commit: { saved in
            guard self.valid(scope), client.isCurrent(), let candidate = saved[key] else { throw ViewerError.stale }
            var latest = self.records[key] ?? candidate
            latest.pending = candidate.pending; latest.version = candidate.version
            self.records[key] = latest; self.trim(&self.records)
            if self.forms[key] == nil { self.remember(form, key: key) }
            self.runtimes[key] = .init(scope: scope, client: client)
            self.mutationEpochs[key] = UUID()
            self.revision = UUID()
        })
        schedule(key, checkOnly: false)
    }

    /// The latest local toggle wins, including while an earlier intent is syncing.
    func enqueueToggle(scope: GalleryFavoriteScope, client: GalleryFavoriteClient, group: Int,
                       groupName: String, title: String) async throws {
        await acquireMutation(); defer { releaseMutation() }
        guard valid(scope), client.isCurrent() else { throw ViewerError.stale }
        guard (0...9).contains(group) else { throw ViewerError.invalidQuery("请选择有效的收藏分组") }
        _ = try GalleryFavoriteForm.endpoint(for: scope.reference)
        let key = scope.reference.id
        guard records[key]?.pending != nil || records.values.filter({ $0.pending != nil }).count < Self.pendingLimit else {
            throw ViewerError.invalidQuery("收藏同步队列已满 请稍后再试")
        }
        let removing = if case .favorited? = entry(scope)?.state { true } else { false }
        let intent = Intent(group: removing ? nil : group, groupName: removing ? nil : groupName,
                            title: String(title.prefix(300)), addIfMissing: !removing, optimisticToggle: true)
        try await persistResolution(resolve: {
            guard self.valid(scope), client.isCurrent() else { throw ViewerError.stale }
            var copy = self.records
            var record = copy[key] ?? .init(site: scope.reference.site, gid: scope.reference.gid,
                                           confirmed: Value(.unknown), date: self.clock())
            record.pending = intent; record.version = UUID()
            copy[key] = record; self.trim(&copy)
            return copy
        }, commit: { saved in
            guard self.valid(scope), client.isCurrent(), let candidate = saved[key] else { throw ViewerError.stale }
            var latest = self.records[key] ?? candidate
            latest.pending = candidate.pending; latest.version = candidate.version
            self.records[key] = latest; self.trim(&self.records)
            self.runtimes[key] = .init(scope: scope, client: client)
            self.mutationEpochs[key] = UUID(); self.revision = UUID()
        })
        schedule(key, checkOnly: false)
    }

    /// Store the whole selection before scheduling any requests. The worker
    /// reads each current form and only submits for a gallery without a group.
    func enqueueAdditions(_ additions: [BatchAddition], group: Int) async throws -> Int {
        await acquireMutation(); defer { releaseMutation() }
        guard (0...9).contains(group) else { throw ViewerError.invalidQuery("请选择有效的收藏分组") }
        var seen = Set<String>()
        let eligible = try additions.filter { addition in
            guard valid(addition.scope), addition.client.isCurrent() else { throw ViewerError.stale }
            guard (0...9).contains(addition.group ?? group) else { throw ViewerError.invalidQuery("请选择有效的收藏分组") }
            _ = try GalleryFavoriteForm.endpoint(for: addition.scope.reference)
            let key = addition.scope.reference.id
            return seen.insert(key).inserted && records[key]?.pending == nil
        }
        guard !eligible.isEmpty else { return 0 }
        let available = max(0, Self.pendingLimit - records.values.filter { $0.pending != nil }.count)
        guard eligible.count <= available else {
            throw ViewerError.invalidQuery(available > 0 ? "本次可排队 \(available) 项 请减少选择" : "收藏同步队列已满 请稍后再试")
        }
        try await persistResolution(resolve: {
            guard eligible.allSatisfy({ self.valid($0.scope) && $0.client.isCurrent() }) else { throw ViewerError.stale }
            var copy = self.records
            for addition in eligible {
                let ref = addition.scope.reference
                var record = copy[ref.id] ?? .init(site: ref.site, gid: ref.gid,
                                                 confirmed: Value(.unknown), date: self.clock())
                record.pending = Intent(group: addition.group ?? group, groupName: addition.groupName,
                                        title: String(addition.title.prefix(300)), addIfMissing: true)
                record.version = UUID(); copy[ref.id] = record
            }
            self.trim(&copy)
            return copy
        }, commit: { saved in
            guard eligible.allSatisfy({ self.valid($0.scope) && $0.client.isCurrent() }) else { throw ViewerError.stale }
            for addition in eligible {
                let key = addition.scope.reference.id
                guard let candidate = saved[key] else { continue }
                var latest = self.records[key] ?? candidate
                latest.pending = candidate.pending; latest.version = candidate.version
                self.records[key] = latest
                self.runtimes[key] = .init(scope: addition.scope, client: addition.client)
                self.mutationEpochs[key] = UUID()
            }
            self.trim(&self.records)
            self.revision = UUID()
        })
        for addition in eligible { schedule(addition.scope.reference.id, checkOnly: false) }
        return eligible.count
    }
    func updateGroupNames(site: GallerySite, before: [String], after: [String]) async throws {
        let mutationOwner = owner, mutationGeneration = generation
        await acquireMutation(); defer { releaseMutation() }
        guard owner == mutationOwner, generation == mutationGeneration else { throw ViewerError.stale }
        guard before.count == 10, after.count == 10 else { throw ViewerError.layoutChanged }
        func rename(_ source: [String: Record]) -> [String: Record] {
            var copy = source
            for key in Array(copy.keys) where copy[key]?.site == site {
                guard var record = copy[key] else { continue }
                if let name = record.confirmed.group {
                    let matches = before.indices.filter { before[$0] == name }
                    let group = record.confirmed.groupIndex ?? forms[key]?.value.selectedGroup ?? (matches.count == 1 ? matches.first : nil)
                    if let group, after.indices.contains(group) {
                        record.confirmed.group = after[group]; record.confirmed.groupIndex = group
                    } else if matches.count > 1 {
                        // Older caches did not store category IDs; duplicate names
                        // cannot identify membership. Preserve the favorite itself.
                        record.confirmed.group = "站点收藏"
                    }
                }
                if let group = record.pending?.group, after.indices.contains(group) {
                    record.pending?.groupName = after[group]
                }
                record.version = UUID(); copy[key] = record
            }
            return copy
        }
        try await persistResolution(resolve: {
            guard self.owner == mutationOwner, self.generation == mutationGeneration else { throw ViewerError.stale }
            return rename(self.records)
        }, commit: { _ in
            guard self.owner == mutationOwner, self.generation == mutationGeneration else { throw ViewerError.stale }
            self.records = rename(self.records)
            self.groupNames[site] = after; self.groupNameEpochs[site] = UUID()
            for key in Set(self.records.keys).union(self.runtimes.keys)
                where self.records[key]?.site == site || self.runtimes[key]?.scope.reference.site == site {
                self.mutationEpochs[key] = UUID()
            }
            for key in Array(self.forms.keys) where self.records[key]?.site == site { self.forms.removeValue(forKey: key) }
            self.revision = UUID()
        })
    }

    func invalidate(_ refs: [GalleryRef], scopeOwner: String, generation: UUID) {
        guard owner == scopeOwner, self.generation == generation else { return }
        for ref in refs where records[ref.id]?.pending == nil { records.removeValue(forKey: ref.id); forms.removeValue(forKey: ref.id); mutationEpochs[ref.id] = UUID() }
        changed()
    }
    func hasPending(_ refs: [GalleryRef]) -> Bool { refs.contains { records[$0.id]?.pending != nil } }
    func seedFavorites(_ galleries: [Gallery], categories: [String: String], url: URL, scopeOwner: String, generation: UUID, observedAfter: Date? = nil) {
        guard owner == scopeOwner, self.generation == generation, url.path == "/favorites.php" else { return }
        let category = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "favcat" }?.value
        for gallery in galleries where records[gallery.id]?.pending == nil {
            if let observedAfter, let newer = records[gallery.id]?.date, newer > observedAfter { continue }
            let existing = records[gallery.id]?.confirmed.state
            let named = category.flatMap { categories[$0] }.map(GalleryFavoriteState.favorited)
            let state: GalleryFavoriteState
            if let named { state = named } else if let existing, case .favorited = existing { state = existing } else { state = .favorited("站点收藏") }
            let value = confirmedValue(state, site: gallery.ref.site, previous: records[gallery.id]?.confirmed,
                                       groupIndex: category.flatMap(Int.init))
            records[gallery.id] = .init(site: gallery.ref.site, gid: gallery.ref.gid, confirmed: value, date: clock())
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
        let namesEpoch = groupNameEpochs[runtime.scope.reference.site]
        defer {
            if self.workerID == workerID, records[key]?.pending == nil, !observers.values.contains(key) { runtimes.removeValue(forKey: key) }
        }
        let target = records[key]?.pending, targetID = records[key]?.pending?.id
        var postStarted = false
        func current() -> Bool { self.workerID == workerID && valid(runtime.scope) && runtime.client.isCurrent() && !Task.isCancelled }
        do {
            var form: GalleryFavoriteForm
            if !checkOnly, target?.addIfMissing != true, (target?.note != nil || target?.action == .remove),
               formIsFresh(runtime.scope, now: clock()), let memo = forms[key]?.value { form = memo }
            else { lastChecks[key] = clock(); form = try await runtime.client.read() }
            guard current() else { return }
            guard form.reference == runtime.scope.reference else { throw ViewerError.restricted }
            if let target, !checkOnly {
                guard records[key]?.pending?.id == target.id else { schedule(key, checkOnly: false); return }
                let note = target.note ?? form.note
                if !satisfies(target, form: form) {
                    let request = try form.request(action: target.action, note: note)
                    records[key]?.pending?.phase = .sending
                    try await persistCurrent { current() && self.records[key]?.pending?.id == target.id }
                    guard current(), records[key]?.pending?.id == target.id else { return }
                    revision = UUID()
                    await runtime.client.willSubmit()
                    guard current() else { return }
                    guard records[key]?.pending?.id == target.id else { schedule(key, checkOnly: false); return }
                    var postError: Error?
                    postStarted = true
                    do { try await runtime.client.submit(request) } catch { postError = error }
                    guard current() else { return }
                    if records[key]?.pending?.id == target.id {
                        records[key]?.pending?.phase = .checking
                        try await persistCurrent { current() }
                        guard current() else { return }
                        revision = UUID()
                    }
                    lastChecks[key] = clock()
                    do {
                        form = try await runtime.client.read()
                        guard form.reference == runtime.scope.reference else { throw ViewerError.restricted }
                    }
                    catch {
                        guard current() else { return }
                        if records[key]?.pending?.id == target.id {
                            records[key]?.pending?.phase = (postError as? ViewerError) == .authentication || (error as? ViewerError) == .authentication ? .login : .uncertain
                            records[key]?.pending?.message = "收藏结果待确认 请检查结果"
                        }
                        forms.removeValue(forKey: key); changed()
                        if target.action != .remove { runtime.client.didSubmit() }
                        return
                    }
                }
            }
            guard current() else { return }
            if records[key] != nil {
                let readForm = form
                var committedForm = readForm
                var snapshotVersion: UUID?
                var needsNextIntent = false
                try await persistResolution(resolve: {
                    guard current(), var record = self.records[key] else { throw ViewerError.stale }
                    var resolvedForm = readForm
                    if namesEpoch != self.groupNameEpochs[runtime.scope.reference.site],
                       let names = self.groupNames[runtime.scope.reference.site] {
                        resolvedForm = resolvedForm.replacingGroupNames(names)
                    }
                    committedForm = resolvedForm
                    snapshotVersion = record.version
                    record.confirmed = self.confirmedValue(resolvedForm.state, site: runtime.scope.reference.site, form: resolvedForm)
                    record.date = self.clock(); record.version = UUID()
                    if let target, record.pending?.id == targetID {
                        if self.satisfies(target, form: resolvedForm) { record.pending = nil }
                        else { record.pending?.phase = .failed; record.pending?.message = "同步未完成 本次更改已保留" }
                    }
                    var copy = self.records; copy[key] = record
                    return copy
                }, commit: { saved in
                    guard current(), let record = saved[key] else { throw ViewerError.stale }
                    // Display-only observations can arrive while the actor
                    // writes. Their queued checkpoint will persist that newer
                    // value; a check without an intent must not overwrite it.
                    if target == nil, self.records[key]?.version != snapshotVersion { return }
                    self.records[key] = record
                    self.remember(committedForm, key: key)
                    if target != nil { self.mutationEpochs[key] = UUID() }
                    self.revision = UUID()
                    if let target, record.pending?.id != target.id, record.pending == nil {
                        if target.action == .remove {
                            var confirmed = self.confirmedRemovals
                            confirmed[key] = target.id
                            if confirmed.count > self.limit { confirmed = confirmed.filter { self.records[$0.key] != nil } }
                            self.confirmedRemovals = confirmed
                        } else { runtime.client.didSubmit() }
                    }
                    needsNextIntent = record.pending != nil && record.pending?.id != targetID
                })
                if needsNextIntent { schedule(key, checkOnly: false) }
            }
        } catch {
            guard current() else { return }
            if records[key]?.pending?.id == targetID, targetID != nil {
                let phase = records[key]?.pending?.phase
                let uncertain = postStarted || phase == .checking ||
                    (checkOnly && (target?.phase == .uncertain || target?.phase == .checking || target?.phase == .sending))
                let transport = (error as? URLError).map { [.timedOut, .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains($0.code) } == true
                let unsent = !uncertain && !checkOnly && target?.phase == .queued && (transport || (error as? RequestFailure)?.canRetryWhenVisible == true || (error as? ViewerError) == .network)
                records[key]?.pending?.phase = (error as? ViewerError) == .authentication ? .login : uncertain ? .uncertain : unsent ? .queued : .failed
                records[key]?.pending?.message = (error as? ViewerError) == .authentication ? "请登录站点后继续同步" : uncertain ? "收藏结果待确认 请检查结果" : unsent ? "暂时无法连接 请稍后重试" : "同步未完成 本次更改已保留"
                changed()
            }
        }
    }
    private func satisfies(_ intent: Intent, form: GalleryFavoriteForm) -> Bool {
        if intent.addIfMissing == true { return form.selectedGroup != nil }
        return form.confirms(intent.action, note: intent.note ?? form.note)
    }
    private func confirmedValue(_ state: GalleryFavoriteState, site: GallerySite,
                                form: GalleryFavoriteForm? = nil, previous: Value? = nil, groupIndex: Int? = nil) -> Value {
        guard case let .favorited(name) = state else { return Value(state) }
        let matches = groupNames[site]?.indices.filter { groupNames[site]?[$0] == name } ?? []
        let index = form?.selectedGroup ?? groupIndex ?? (previous?.group == name ? previous?.groupIndex : nil)
            ?? (matches.count == 1 ? matches.first : nil)
        return Value(state, groupIndex: index)
    }
    private func remember(_ form: GalleryFavoriteForm, key: String) {
        forms[key] = (form, clock())
        if forms.count > 64, let old = forms.min(by: { $0.value.date < $1.value.date })?.key { forms.removeValue(forKey: old) }
    }
    private func changed() { checkpoint(); revision = UUID() }

    private func acquireMutation() async {
        if !mutationBusy { mutationBusy = true; return }
        await withCheckedContinuation { mutationWaiters.append($0) }
    }
    private func releaseMutation() {
        if mutationWaiters.isEmpty { mutationBusy = false }
        else { mutationWaiters.removeFirst().resume() }
    }

    /// Chaining jobs includes the MainActor commit before the next job reads
    /// its snapshot. A queued checkpoint can never overwrite a newly accepted
    /// intent with a snapshot captured before that intent became durable.
    /// Build the candidate only after preceding jobs have committed. Keep
    /// pending state visible until the actor has atomically saved this value.
    private func persistResolution(resolve: @escaping @MainActor () throws -> [String: Record],
                                   commit: @escaping @MainActor ([String: Record]) throws -> Void) async throws {
        guard !storageUnreadable else { throw ViewerError.invalidQuery("同步记录暂不可读 原记录保留") }
        let expectedOwner = owner, expectedGeneration = generation
        let destination = file, previous = persistenceTail, persistence = persistence
        pendingWrites += 1
        let task = Task { @MainActor in
            defer { self.pendingWrites -= 1 }
            _ = await previous?.result
            guard self.owner == expectedOwner, self.generation == expectedGeneration else { throw ViewerError.stale }
            let values = try resolve()
            if let destination { try await persistence.write(values, to: destination) }
            guard self.owner == expectedOwner, self.generation == expectedGeneration else { throw ViewerError.stale }
            try commit(values)
        }
        persistenceID = UUID(); persistenceTail = task
        try await task.value
        persistenceFailure = nil
    }

    private func persistCurrent(validate: @escaping @MainActor () -> Bool) async throws {
        try await persistResolution(resolve: {
            guard validate() else { throw ViewerError.stale }
            return self.records
        }, commit: { _ in
            guard validate() else { throw ViewerError.stale }
        })
    }

    private func checkpoint() {
        guard !owner.isEmpty, !storageUnreadable, let destination = file else { return }
        let checkpointOwner = owner, checkpointGeneration = generation
        let previous = persistenceTail, persistence = persistence
        pendingWrites += 1
        let task = Task { @MainActor in
            defer { self.pendingWrites -= 1 }
            _ = await previous?.result
            let saved = self.owner == checkpointOwner
                ? OwnerSnapshot(records: self.records, unreadable: self.storageUnreadable)
                : self.owners[checkpointOwner]
            guard let saved, !saved.unreadable else { return }
            try await persistence.write(saved.records, to: destination)
        }
        persistenceID = UUID(); persistenceTail = task
        Task { @MainActor in
            do { try await task.value }
            catch {
                guard self.owner == checkpointOwner, self.generation == checkpointGeneration else { return }
                self.persistenceFailure = "收藏同步保存失败 请重试"
                self.revision = UUID()
            }
        }
    }

    /// Await at app lifecycle boundaries and before reopening a separate cache
    /// instance. It also waits for jobs appended while the previous job ran.
    func flushPersistence() async throws {
        while let task = persistenceTail {
            let expected = persistenceID
            try await task.value
            if expected == persistenceID {
                owners = owners.filter { $0.key == owner }
                return
            }
        }
    }

    /// Own the short execution grant until the queued file writes settle. The
    /// OS may still expire or kill the process; this does not start/replay POSTs.
    func flushForLifecycle() {
        guard lifecycleFlushTask == nil, pendingWrites > 0 else { return }
        let id = UUID(); lifecycleFlushID = id
        lifecycleBackgroundWork?.beginShort("保存收藏同步记录") { [weak self] in
            guard let self, self.lifecycleFlushID == id else { return }
            self.lifecycleFlushID = nil
            self.lifecycleBackgroundWork?.finish(.waiting)
        }
        lifecycleFlushTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var completion: DownloadBackgroundCompletion = .completed
            do { try await self.flushPersistence() }
            catch {
                completion = .failed
                self.persistenceFailure = "收藏同步保存失败 请重试"
                self.revision = UUID()
            }
            self.lifecycleFlushTask = nil
            guard self.lifecycleFlushID == id else { return }
            self.lifecycleFlushID = nil
            self.lifecycleBackgroundWork?.finish(completion)
        }
    }
    private func trim(_ copy: inout [String: Record]) {
        guard copy.count > limit else { return }
        for r in copy.values.filter({ $0.pending == nil }).sorted(by: { $0.date < $1.date }).prefix(max(0, copy.count - limit)) {
            copy.removeValue(forKey: r.id); forms.removeValue(forKey: r.id)
        }
    }
    private var file: URL? { storageRoot?.appendingPathComponent(owner, isDirectory: true).appendingPathComponent("site-favorites.json") }
    private func restore() {
        guard let file, FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 2_000_000 else { throw ViewerError.storage }
            let saved = try JSONDecoder().decode(File.self, from: Data(contentsOf: file))
            guard saved.version == 1, saved.records.count <= limit, Set(saved.records.map(\.id)).count == saved.records.count,
                  saved.records.allSatisfy({ $0.gid > 0 && ($0.pending?.group.map { (0...9).contains($0) } ?? true)
                      && ($0.confirmed.groupIndex.map { (0...9).contains($0) } ?? true) }) else { throw ViewerError.storage }
            records = Dictionary(uniqueKeysWithValues: saved.records.map { value in
                var value = value
                if value.pending?.phase == .sending || value.pending?.phase == .checking { value.pending?.phase = .uncertain }
                return (value.id, value)
            })
        } catch { storageUnreadable = true }
    }
}
