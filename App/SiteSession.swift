import Foundation
import Security
import WebKit
import CryptoKit
import ExViewerCore

struct SessionCookie: Codable, Equatable {
    var name: String
    var value: String
    var domain: String
    var path: String
    var expires: Date?
    var secure: Bool
    init(_ cookie: HTTPCookie) {
        name = cookie.name; value = cookie.value; domain = cookie.domain
        path = cookie.path; expires = cookie.expiresDate; secure = cookie.isSecure
    }
    var cookie: HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path, .secure: "TRUE"]
        if let expires { properties[.expires] = expires }
        return HTTPCookie(properties: properties)
    }
}

struct PageReadScope: Hashable, Sendable {
    let owner: String
    let generation: UUID
    let preferences: UUID
}

enum SessionVault {
    static let service = "com.xueyj.exviewer.session.v1"
    static func read(service: String = SessionVault.service) throws -> [SessionCookie] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "site-session", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw ViewerError.keychain(.read, status) }
        guard let data = result as? Data else { throw ViewerError.sessionRecord }
        do { return try JSONDecoder().decode([SessionCookie].self, from: data) }
        catch { throw ViewerError.sessionRecord }
    }
    static func save(_ cookies: [SessionCookie], service: String = SessionVault.service) throws {
        let key: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "site-session"]
        let data = try JSONEncoder().encode(cookies)
        let values: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let update = SecItemUpdate(key as CFDictionary, values as CFDictionary)
        if update == errSecItemNotFound {
            var record = key; values.forEach { record[$0.key] = $0.value }
            let status = SecItemAdd(record as CFDictionary, nil)
            guard status == errSecSuccess else { throw ViewerError.keychain(.add, status) }
        } else if update != errSecSuccess { throw ViewerError.keychain(.update, update) }
    }
    static func delete(service: String = SessionVault.service) throws {
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "site-session"] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ViewerError.keychain(.remove, status) }
    }
}

final class SafeRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, URLPolicy.account(url) || URLPolicy.media(url) else { completionHandler(nil); return }
        if task.originalRequest?.httpMethod == "POST", ["/favorites.php", "/gallerypopups.php"].contains(task.originalRequest?.url?.path ?? ""),
           task.originalRequest?.url?.host != url.host { completionHandler(nil); return }
        var safe = request
        // A redirect never carries a manually constructed authentication header to another origin.
        if response.url?.host != url.host { safe.setValue(nil, forHTTPHeaderField: "Cookie"); safe.setValue(nil, forHTTPHeaderField: "Referer") }
        completionHandler(safe)
    }
}

@MainActor final class SiteSession: ObservableObject {
    private struct ImagePageKey: Hashable {
        let url: URL
        let scope: PageReadScope
    }
    private struct MetadataKey: Hashable {
        let refs: [GalleryRef]
        let scope: PageReadScope
    }
    private struct GalleryDetailKey: Hashable {
        let reference: GalleryRef
        let url: URL
        let scope: PageReadScope
    }
    static let metadataURL = URL(string: "https://api.e-hentai.org/api.php")!

    @Published private(set) var ehStatus = "未验证"
    @Published private(set) var exStatus = "未验证"
    @Published private(set) var generation = UUID()
    @Published private(set) var owner = "guest"
    @Published private(set) var favoritesRevision = UUID()
    let favoriteStateCache: SiteFavoriteCache
    let favoriteGroups: FavoriteGroupPreferences
    @Published var quota = AccountQuota()
    @Published var error: String?
    let webStore = WKWebsiteDataStore.nonPersistent()
    private var cookies: [SessionCookie] = []
    private var activePageCookies: [SessionCookie] = []
    private var pagePreferences = UUID()
    private let imagePages = SiteReadFlights<ImagePageKey, ImageSource>()
    private let metadataBatches = SiteReadFlights<MetadataKey, GalleryMetadata>()
    private let galleryDetails = SiteReadFlights<GalleryDetailKey, ReaderOpeningDetail>()
    private let quotaReads = SiteReadFlights<UUID, AccountQuota>()
    private var galleryDetailSnapshots: [GalleryDetailKey: ReaderOpeningDetail] = [:]
    private var versionSnapshots: [MetadataKey: (links: GalleryVersionLinks?, expires: TimeInterval)] = [:]
    private let delegate = SafeRedirect()
    private let transportConfiguration: URLSessionConfiguration?
    private let persistsCredentials: Bool
    private let pageScheduler: SiteRequestScheduler
    private let pageConcurrencyLimit: () -> Int
    private lazy var transport = makeTransport()
    private func makeTransport() -> URLSession {
        let config = (transportConfiguration?.copy() as? URLSessionConfiguration) ?? .ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 60
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }
    private var webOperation = UUID()
    private var loggingOut = false
    private let webGate = TransferGate(limit: 1)
    private let allowedNames = Set(["ipb_member_id", "ipb_pass_hash", "igneous", "cf_clearance", "yay", "uconfig"])
    var hasCredentials: Bool { Self.hasSiteCredentials(cookies) }

    private static func hasSiteCredentials(_ values: [SessionCookie]) -> Bool {
        values.contains { $0.name == "ipb_member_id" && !$0.value.isEmpty } &&
            values.contains { $0.name == "ipb_pass_hash" && !$0.value.isEmpty }
    }

    var pageReadScope: PageReadScope {
        let now = Date()
        let active = cookies.filter { cookie in
            cookie.name != "cf_clearance" && (cookie.expires.map { $0 > now } ?? true)
        }
        let unchanged = active.elementsEqual(activePageCookies) { left, right in
            left.name == right.name && left.value == right.value && left.domain == right.domain && left.path == right.path
        }
        if !unchanged {
            activePageCookies = active
            pagePreferences = UUID()
        }
        return PageReadScope(owner: owner, generation: generation, preferences: pagePreferences)
    }

    init(qa: Bool = false, configuration: URLSessionConfiguration? = nil,
         searchInterval: TimeInterval = 3.1, pageConcurrencyLimit: (() -> Int)? = nil,
         favoriteCache: SiteFavoriteCache? = nil, favoritePreferences: FavoriteGroupPreferences? = nil) {
        if qa && ProcessInfo.processInfo.arguments.contains("--qa-reset-favorite-groups") {
            UserDefaults(suiteName: "ExViewer.QA.FavoriteGroups")?.removePersistentDomain(forName: "ExViewer.QA.FavoriteGroups")
        }
        self.favoriteGroups = favoritePreferences ?? FavoriteGroupPreferences(defaults: qa
            ? UserDefaults(suiteName: "ExViewer.QA.FavoriteGroups")! : .standard)
        self.transportConfiguration = configuration
        self.persistsCredentials = !qa
        favoriteStateCache = favoriteCache ?? SiteFavoriteCache(storageRoot: qa ? nil : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ExViewer"))
        self.pageScheduler = SiteRequestScheduler(searchInterval: searchInterval)
        self.pageConcurrencyLimit = pageConcurrencyLimit ?? {
            SiteRequestPolicy.configuredConcurrency(defaults: ReaderPreferenceDefaults.store)
        }
        favoriteStateCache.activate(owner: owner, generation: generation)
        if qa {
            if ProcessInfo.processInfo.arguments.contains("--qa-account-status-preview") {
                ehStatus = "连接失败"
                exStatus = "EX 画廊可访问"
                quota = AccountQuota(tracking: .ip, resetCost: 20_000)
            }
            return
        }
        do { cookies = try SessionVault.read(); updateOwner() }
        catch { self.error = (error as? ViewerError)?.localizedDescription ?? "本机登录记录暂时无法读取，请重试。" }
    }
    private func updateOwner() {
        let member = cookies.first { $0.name == "ipb_member_id" && ($0.domain == ".e-hentai.org" || $0.domain == "e-hentai.org") }?.value
            ?? cookies.first { $0.name == "ipb_member_id" }?.value
        owner = member.map { SHA256.hash(data: Data($0.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined() } ?? "guest"
        favoriteStateCache.activate(owner: owner, generation: generation)
    }
    private func accepted(_ cookie: HTTPCookie) -> Bool {
        let host = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        return URLPolicy.accountHosts.contains(host) && allowedNames.contains(cookie.name) && !cookie.value.isEmpty && (cookie.expiresDate == nil || cookie.expiresDate! > Date())
    }
    func beginWebOperation() throws -> UUID {
        guard !loggingOut else { throw ViewerError.stale }
        webOperation = UUID(); return webOperation
    }
    func endWebOperation(_ operation: UUID) { if webOperation == operation { webOperation = UUID() } }
    func prepareWebSession(operation: UUID) async throws {
        let revision = generation, snapshot = cookies
        try await webGate.acquire(); defer { Task { await webGate.release() } }
        guard !loggingOut, operation == webOperation, revision == generation else { throw ViewerError.stale }
        for cookie in snapshot.compactMap(\.cookie) where accepted(cookie) {
            guard !loggingOut, operation == webOperation, revision == generation else { throw ViewerError.stale }
            await webStore.httpCookieStore.setCookie(cookie)
            guard !loggingOut, operation == webOperation, revision == generation else { throw ViewerError.stale }
        }
    }
    func captureWebSession(operation: UUID) async throws {
        let revision = generation
        try await webGate.acquire(); defer { Task { await webGate.release() } }
        guard !loggingOut, operation == webOperation, revision == generation else { throw ViewerError.stale }
        let values = await webStore.httpCookieStore.allCookies().filter { accepted($0) }.map(SessionCookie.init)
        guard !loggingOut, operation == webOperation, revision == generation else { throw ViewerError.stale }
        guard values.contains(where: { $0.name == "ipb_member_id" }), values.contains(where: { $0.name == "ipb_pass_hash" }) else { throw ViewerError.authentication }
        guard Set(values.filter { $0.name == "ipb_member_id" }.map(\.value)).count == 1 else { throw ViewerError.stale }
        // Only the two site credentials are shared with the site's EX origin, never arbitrary browser cookies.
        var merged = values
        for name in ["ipb_member_id", "ipb_pass_hash"] {
            if !merged.contains(where: { $0.name == name && $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")) == "exhentai.org" }),
               var credential = values.first(where: { $0.name == name }) {
                credential.domain = ".exhentai.org"; credential.path = "/"; merged.append(credential)
            }
        }
        if persistsCredentials { try SessionVault.save(merged) }
        imagePages.cancelAll()
        metadataBatches.cancelAll()
        galleryDetails.cancelAll()
        quotaReads.cancelAll()
        galleryDetailSnapshots.removeAll()
        cookies = merged; generation = UUID(); updateOwner(); quota = AccountQuota(); ehStatus = "待验证"; exStatus = "待验证"
    }
    private func header(for url: URL) -> String? {
        guard URLPolicy.account(url), let host = url.host else { return nil }
        let applicable = cookies.filter { value in
            let domain = value.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return (host == domain || (value.domain.hasPrefix(".") && host.hasSuffix("." + domain))) && url.path.hasPrefix(value.path) && (value.expires == nil || value.expires! > Date())
        }
        return applicable.isEmpty ? nil : applicable.map { $0.name + "=" + $0.value }.joined(separator: "; ")
    }
    func updatePageConcurrency() { pageScheduler.setLimit(pageConcurrencyLimit()) }

    func imageSource(_ url: URL, request: MediaRequestDemand, recoverConnection: Bool = true) async throws -> ImageSource {
        let revision = generation
        for attempt in 0..<2 {
            try Task.checkCancellation()
            guard revision == generation else { throw ViewerError.stale }
            let key = ImagePageKey(url: url, scope: pageReadScope)
            do {
                return try await imagePages.read(key, request: request) { shared in
                    let html = try await self.request(url, method: "GET", body: nil, contentType: "application/x-www-form-urlencoded",
                                                      accept: "text/html,application/xhtml+xml", pacing: .download,
                                                      recoverConnection: false, freshConnection: attempt > 0, demand: shared,
                                                      decode: Self.checkedHTML)
                    return try EHParser.image(html, base: url)
                }
            } catch RequestFailure.transport(.page, URLError.networkConnectionLost.rawValue) where recoverConnection && attempt == 0 {
                try await Task.sleep(nanoseconds: 400_000_000)
            }
        }
        throw ViewerError.network
    }

    func cachedGalleryDetail(for reference: GalleryRef) -> ReaderOpeningDetail? {
        let scope = pageReadScope
        let key = GalleryDetailKey(reference: reference, url: reference.url, scope: scope)
        guard let value = galleryDetailSnapshots[key],
              value.isReusable(for: reference, generation: scope.generation, owner: scope.owner) else { return nil }
        return value
    }

    func galleryDetail(for reference: GalleryRef, pageURL: URL? = nil, refresh: Bool = false,
                       request demand: MediaRequestDemand = MediaRequestDemand()) async throws -> ReaderOpeningDetail {
        try Task.checkCancellation()
        let url = pageURL ?? reference.url
        let firstPage = url == reference.url
        if firstPage, !refresh, let cached = cachedGalleryDetail(for: reference) { return cached }
        let key = GalleryDetailKey(reference: reference, url: url, scope: pageReadScope)
        let result = try await galleryDetails.read(key, request: demand) { shared in
            let favoriteScope = GalleryFavoriteScope(reference: reference, owner: key.scope.owner,
                                                     generation: key.scope.generation)
            let favoriteVersion = self.favoriteStateCache.entry(favoriteScope)?.version
            let html = try await self.html(url, request: shared)
            let parse = Task.detached(priority: .userInitiated) {
                try EHParser.detail(html, reference: reference, pageURL: url)
            }
            let detail = try await withTaskCancellationHandler(operation: { try await parse.value }, onCancel: { parse.cancel() })
            try Task.checkCancellation()
            guard key.scope == self.pageReadScope else { throw ViewerError.stale }
            let value = ReaderOpeningDetail(detail: detail, generation: key.scope.generation, owner: key.scope.owner)
            if detail.favoriteStateKnown {
                self.favoriteStateCache.put(detail.favoriteState, scope: favoriteScope,
                                            expectedVersion: favoriteVersion, conditional: true)
            }
            if firstPage {
                self.galleryDetailSnapshots = self.galleryDetailSnapshots.filter {
                    $0.key.scope == key.scope && $0.value.isReusable(for: $0.key.reference, generation: key.scope.generation,
                                                                   owner: key.scope.owner)
                }
                if self.galleryDetailSnapshots.count >= 24,
                   let oldest = self.galleryDetailSnapshots.min(by: { $0.value.fetchedAt < $1.value.fetchedAt })?.key {
                    self.galleryDetailSnapshots.removeValue(forKey: oldest)
                }
                self.galleryDetailSnapshots[key] = value
            }
            return value
        }
        guard key.scope == pageReadScope else { throw ViewerError.stale }
        return result
    }

    func galleryMetadata(_ galleries: [Gallery], priority: MediaRequestPriority) async throws -> [Gallery] {
        try await readGalleryMetadata(galleries, priority: priority).merging(into: galleries)
    }

    func currentGalleryVersion(_ gallery: Gallery) async throws -> GalleryRef? {
        try await galleryVersionLinks(gallery, priority: .foreground)?.latest
    }

    func galleryVersionLinks(_ gallery: Gallery, priority: MediaRequestPriority, refresh: Bool = false) async throws -> GalleryVersionLinks? {
        let key = MetadataKey(refs: [gallery.ref], scope: pageReadScope)
        let now = ProcessInfo.processInfo.systemUptime
        if !refresh, let saved = versionSnapshots[key], saved.expires > now { return saved.links }
        let links = try await readGalleryMetadata([gallery], priority: priority).versionLinks(of: gallery.ref)
        versionSnapshots = versionSnapshots.filter { $0.key.scope == key.scope && $0.value.expires > now }
        if versionSnapshots.count >= 64, let oldest = versionSnapshots.min(by: { $0.value.expires < $1.value.expires })?.key {
            versionSnapshots.removeValue(forKey: oldest)
        }
        versionSnapshots[key] = (links, now + 300)
        return links
    }

    private func readGalleryMetadata(_ galleries: [Gallery], priority: MediaRequestPriority) async throws -> GalleryMetadata {
        let body = try GalleryMetadata.request(galleries)
        let key = MetadataKey(refs: galleries.map(\.ref), scope: pageReadScope)
        let metadata = try await metadataBatches.read(key, request: MediaRequestDemand(priority: priority)) { shared in
            let data = try await self.request(Self.metadataURL, method: "POST", body: body,
                                   contentType: "application/json", accept: "application/json",
                                   pacing: .metadata, recoverConnection: false, demand: shared) { data in
                let json = data.starts(with: [0xef, 0xbb, 0xbf]) ? data.dropFirst(3) : data
                let first = json.first { ![0x20, 0x09, 0x0a, 0x0d].contains($0) }
                guard first == 0x7b || first == 0x5b else {
                    _ = try Self.checkedHTML(data)
                    throw ViewerError.layoutChanged
                }
                return data
            }
            let parse = Task.detached(priority: .userInitiated) { try GalleryMetadata(data) }
            return try await withTaskCancellationHandler(operation: { try await parse.value }, onCancel: { parse.cancel() })
        }
        try Task.checkCancellation()
        guard key.scope.generation == generation, key.scope.owner == owner else { throw ViewerError.stale }
        return metadata
    }

    func html(_ url: URL, search: Bool = false, method: String = "GET", body: Data? = nil,
              contentType: String = "application/x-www-form-urlencoded",
              searchPriority: SearchRequestPriority = .foreground,
              recoverConnection: Bool = true,
              request demand: MediaRequestDemand? = nil,
              freshConnection: Bool = false) async throws -> String {
        try await request(url, method: method, body: body, contentType: contentType,
                          accept: "text/html,application/xhtml+xml", pacing: search ? .search : nil,
                          recoverConnection: recoverConnection, freshConnection: freshConnection,
                          demand: demand ?? MediaRequestDemand(priority: searchPriority == .prefetch ? .prefetch : .foreground),
                          decode: Self.checkedHTML)
    }

    private func request<Response>(_ url: URL, method: String, body: Data?, contentType: String,
                                   accept: String, pacing: SiteRequestScheduler.Pacing?, recoverConnection: Bool,
                                   freshConnection: Bool = false, demand: MediaRequestDemand,
                                   decode: (Data) throws -> Response) async throws -> Response {
        guard URLPolicy.account(url) else { throw ViewerError.restricted }
        let revision = generation
        for attempt in 0..<2 {
            try Task.checkCancellation()
            guard revision == generation else { throw ViewerError.stale }
            let lease = try await pageScheduler.acquire(request: demand, pacing: pacing, limit: pageConcurrencyLimit())
            let temporary = freshConnection || attempt > 0
            let client = temporary ? makeTransport() : transport
            do {
                let value = try await receive(url, method: method, body: body, contentType: contentType,
                                              accept: accept, client: client, revision: revision, decode: decode)
                pageScheduler.release(lease)
                if temporary { client.finishTasksAndInvalidate() }
                return value
            } catch {
                pageScheduler.release(lease)
                if temporary { client.finishTasksAndInvalidate() }
                // Read-only GETs have one recovery attempt on a fresh connection.
                // PageMediaLoader disables this inner retry to keep its total budget at two.
                guard attempt == 0, recoverConnection, method == "GET", body == nil,
                      case RequestFailure.transport(.page, URLError.networkConnectionLost.rawValue) = error else { throw error }
                try Task.checkCancellation()
                guard revision == generation else { throw ViewerError.stale }
                try await Task.sleep(nanoseconds: 400_000_000)
            }
        }
        throw ViewerError.network
    }

    private static func checkedHTML(_ data: Data) throws -> String {
        guard let html = String(data: data, encoding: .utf8) else { throw ViewerError.layoutChanged }
        try EHParser.check(html)
        return html
    }

    private func receive<Response>(_ url: URL, method: String, body: Data?, contentType: String, accept: String,
                                   client: URLSession, revision: UUID, decode: (Data) throws -> Response) async throws -> Response {
        try Task.checkCancellation()
        guard revision == generation else { throw ViewerError.stale }
        var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = body
        if method == "POST", ["/favorites.php", "/gallerypopups.php"].contains(url.path), let host = url.host, GallerySite.allCases.contains(where: { $0.host == host }) {
            request.setValue("https://" + host, forHTTPHeaderField: "Origin")
            request.setValue(url.absoluteString, forHTTPHeaderField: "Referer")
        }
        request.setValue(header(for: url), forHTTPHeaderField: "Cookie")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if body != nil { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        do {
            let (bytes, response) = try await client.bytes(for: request)
            guard let response = response as? HTTPURLResponse, let finalURL = response.url, URLPolicy.account(finalURL) else { throw ViewerError.network }
            if response.statusCode == 509 { throw ViewerError.imageLimit }
            if response.statusCode == 401 { throw ViewerError.authentication }
            if response.value(forHTTPHeaderField: "cf-mitigated")?.lowercased() == "challenge" { throw ViewerError.challenge }
            guard (200...299).contains(response.statusCode) || response.statusCode == 403 else { throw RequestFailure.http(.page, response.statusCode) }
            guard response.expectedContentLength <= 6_000_000 else { throw ViewerError.tooLarge }
            let data = try await Self.collectPageBytes(bytes)
            try Task.checkCancellation()
            guard revision == generation else { throw ViewerError.stale }
            if response.statusCode == 403 {
                _ = try Self.checkedHTML(data)
                throw RequestFailure.http(.page, 403)
            }
            let value = try decode(data)
            if let headers = response.allHeaderFields as? [String: String], response.value(forHTTPHeaderField: "Set-Cookie") != nil {
                try applyResponseCookies(headers, for: finalURL)
            }
            return value
        } catch let error as ViewerError { throw error }
        catch let error as RequestFailure { throw error }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw RequestFailure.transport(.page, error.code.rawValue)
        }
        catch { throw ViewerError.network }
    }
    private func applyResponseCookies(_ headers: [String: String], for url: URL) throws {
        var updated = cookies
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: headers, for: url) where accepted(cookie) {
            let value = SessionCookie(cookie)
            if let index = updated.firstIndex(where: { $0.name == value.name && $0.domain == value.domain && $0.path == value.path }) {
                updated[index] = value
            } else {
                updated.append(value)
            }
        }
        guard updated != cookies else { return }
        if Self.hasSiteCredentials(updated) { try SessionVault.save(updated) }
        cookies = updated
    }
    nonisolated private static func collectPageBytes(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        // URLSession's bounded stream is consumed off the main actor. A large
        // HTML/metadata response must not hold up selection and scrolling.
        var data = Data(); data.reserveCapacity(64_000)
        for try await byte in bytes { data.append(byte); if data.count > 6_000_000 { throw ViewerError.tooLarge } }
        return data
    }
    func verify() async {
        let revision = generation
        ehStatus = "连接中…"; exStatus = hasCredentials ? "连接中…" : "需要登录"
        for site in GallerySite.allCases {
            do {
                if site == .ex && !hasCredentials { exStatus = "需要登录"; continue }
                let url = try SearchQuery().url(site: site, favorites: site == .eh && hasCredentials)
                let list = try EHParser.list(await html(url, search: true), base: url)
                guard revision == generation else { return }
                let status = hasCredentials ? (site == .eh ? "站点收藏可读取" : "EX 画廊可访问") : "访客可访问"
                if site == .eh { ehStatus = status } else { exStatus = status }
                _ = list
            } catch {
                guard revision == generation else { return }
                let value: String
                if let requestFailure = error as? RequestFailure, case .transport = requestFailure {
                    value = "连接失败"
                } else {
                    value = ErrorMessages.message(error, fallback: "验证未完成")
                }
                if site == .eh { ehStatus = value } else { exStatus = value }
            }
        }
    }
    func changeFavorites(_ references: [GalleryRef], site: GallerySite, action: FavoriteAction) async throws {
        guard hasCredentials else { throw ViewerError.authentication }
        guard !references.isEmpty, references.count <= FavoritesBatchRequest.maxItemCount,
              references.allSatisfy({ $0.site == site }) else {
            throw ViewerError.invalidQuery("每批请选择 1 至 25 个有效收藏。")
        }
        let revision = generation, account = owner
        guard !favoriteStateCache.hasPending(references) else { throw ViewerError.invalidQuery("所选作品仍有收藏更改待处理，请先检查同步结果。") }
        favoriteStateCache.invalidate(references, scopeOwner: account, generation: revision)
        let endpoint = site.baseURL.appendingPathComponent("favorites.php")
        let request = try FavoritesBatchRequest(url: endpoint, site: site, gids: references.map(\.gid), action: action)
        do {
            _ = try await FavoritesSubmissionExecutor.run(isCurrent: { revision == self.generation && account == self.owner }, submit: {
                try await self.html(request.url, method: "POST", body: request.body)
            }, parse: { response in
                try EHParser.list(response, base: request.url)
            })
        } catch let failure as FavoritesSubmissionFailure {
            throw FavoriteMutationFailure(requestMayHaveBeenSent: failure.requestMayHaveBeenSent, underlying: failure.underlying)
        }
    }
    func favoriteChanged() { favoritesRevision = UUID() }
    func refreshQuota() async throws {
        let revision = generation
        do {
            _ = try await quotaReads.read(revision, request: MediaRequestDemand()) { shared in
                let url = URL(string: "https://e-hentai.org/home.php")!
                let result = try EHParser.quota(await self.html(url, request: shared))
                try Task.checkCancellation()
                guard revision == self.generation else { throw CancellationError() }
                self.quota = result
                return result
            }
        } catch {
            guard revision == generation else { throw CancellationError() }
            throw error
        }
    }
    func logout() async throws {
        loggingOut = true; webOperation = UUID(); generation = UUID()
        defer { loggingOut = false }
        imagePages.cancelAll()
        metadataBatches.cancelAll()
        galleryDetails.cancelAll()
        quotaReads.cancelAll()
        galleryDetailSnapshots.removeAll()
        transport.invalidateAndCancel()
        if persistsCredentials { try SessionVault.delete() }
        cookies = []; generation = UUID(); owner = "guest"
        favoriteStateCache.activate(owner: owner, generation: generation)
        quota = AccountQuota(); ehStatus = "未验证"; exStatus = "未验证"
        try await webGate.acquire()
        await webStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        await webGate.release()
        // Replace the invalidated ephemeral transport for a later account.
        transport = makeTransport()
    }
}

/// Shares read-only requests while preserving each caller's cancellation and priority.
@MainActor private final class SiteReadFlights<Key: Hashable, Value> {
    private struct Consumer {
        let request: MediaRequestDemand
        let observer: UUID
        let continuation: CheckedContinuation<Value, Error>
    }

    private final class Flight {
        let id = UUID()
        let demand: MediaRequestDemand
        var consumers: [UUID: Consumer] = [:]
        var task: Task<Void, Never>?

        init(priority: MediaRequestPriority) { demand = MediaRequestDemand(priority: priority) }

        func updatePriority() {
            if let priority = consumers.values.map({ $0.request.priority }).min(by: { $0.rawValue < $1.rawValue }) {
                demand.setPriority(priority)
            }
        }
    }

    private var flights: [Key: Flight] = [:]

    func read(_ key: Key, request: MediaRequestDemand,
              load: @escaping @MainActor (MediaRequestDemand) async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let id = UUID()
        let result: Value = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                guard flights[key] != nil || flights.count < 64 else { continuation.resume(throwing: RequestFailure.pageQueueFull); return }
                let flight = flights[key] ?? Flight(priority: request.priority)
                guard flight.consumers.count < 64 else { continuation.resume(throwing: RequestFailure.pageQueueFull); return }
                let observer = request.observe { [weak flight] in
                    Task { @MainActor in flight?.updatePriority() }
                }
                flight.consumers[id] = Consumer(request: request, observer: observer, continuation: continuation)
                flights[key] = flight
                flight.updatePriority()
                if flight.task == nil {
                    let flightID = flight.id, demand = flight.demand
                    flight.task = Task { [weak self] in
                        let result: Result<Value, Error>
                        do { result = .success(try await load(demand)) }
                        catch { result = .failure(error) }
                        guard let self, self.flights[key]?.id == flightID else { return }
                        self.finish(key, result: result)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancel(key, consumer: id) }
        }
        try Task.checkCancellation()
        return result
    }

    private func cancel(_ key: Key, consumer id: UUID) {
        guard let flight = flights[key], let consumer = flight.consumers.removeValue(forKey: id) else { return }
        consumer.request.removeObserver(consumer.observer)
        consumer.continuation.resume(throwing: CancellationError())
        if flight.consumers.isEmpty {
            flights.removeValue(forKey: key)
            flight.task?.cancel()
        } else {
            flight.updatePriority()
        }
    }

    private func finish(_ key: Key, result: Result<Value, Error>) {
        guard let flight = flights.removeValue(forKey: key) else { return }
        for consumer in flight.consumers.values {
            consumer.request.removeObserver(consumer.observer)
            consumer.continuation.resume(with: result)
        }
    }

    func cancelAll() {
        for key in Array(flights.keys) {
            flights[key]?.task?.cancel()
            finish(key, result: .failure(ViewerError.stale))
        }
    }
}

struct FavoriteMutationFailure: Error, LocalizedError {
    let requestMayHaveBeenSent: Bool
    let underlying: Error
    var errorDescription: String? {
        let status = requestMayHaveBeenSent ? "本次收藏操作可能已提交，结果未确认。" : "本次收藏操作尚未提交。"
        return status + ErrorMessages.message(underlying, fallback: "请刷新收藏检查后再操作。")
    }
}
