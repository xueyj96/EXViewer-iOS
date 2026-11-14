import Foundation
import CryptoKit
import ImageIO
import ExViewerCore

actor TransferGate {
    static func mediaTransfers() -> TransferGate {
        TransferGate(limit: ReaderLoadPolicy.maxConcurrency,
                     prefetchLimit: ReaderLoadPolicy.maxConcurrency - 1,
                     allowFullWithForeground: true, totalLimit: MediaTransferClient.maxConnections,
                     reservedCoverCapacity: MediaTransferClient.coverCapacity)
    }

    private let browsingLimit: Int
    private var permits: Int
    private let prefetchLimit: Int
    private let thumbnailLimit: Int
    private let reservedCoverCapacity: Int
    private let allowFullWithForeground: Bool
    private var foregroundInUse = 0
    private var prefetchInUse = 0
    private var thumbnailsInUse = 0
    private var coverPrefetchInUse = 0
    init(limit: Int = 3, prefetchLimit: Int = 1, allowFullWithForeground: Bool = false,
         totalLimit: Int? = nil, reservedCoverCapacity: Int = 0) {
        let readerLimit = max(1, limit)
        let total = max(readerLimit, totalLimit ?? readerLimit)
        let covers = min(max(0, reservedCoverCapacity), total - 1)
        browsingLimit = readerLimit
        permits = total
        self.prefetchLimit = min(max(1, prefetchLimit), max(1, readerLimit - 1))
        self.reservedCoverCapacity = covers
        thumbnailLimit = covers > 0 ? covers : min(2, max(0, readerLimit - 1))
        self.allowFullWithForeground = allowFullWithForeground
    }

    // Reader/preload/download traffic cannot spend unused dedicated cover slots.
    // Small standalone gates retain their shared-budget behavior for other users.
    private var unusedCoverCapacity: Int { max(0, reservedCoverCapacity - thumbnailsInUse) }
    private var browsingPermits: Int {
        let sharedCovers = reservedCoverCapacity == 0 ? thumbnailsInUse : 0
        return min(permits - unusedCoverCapacity, browsingLimit - foregroundInUse - prefetchInUse - sharedCovers)
    }
    private struct Waiter {
        let id: UUID
        let request: MediaRequestDemand
        let observer: UUID
        let continuation: CheckedContinuation<MediaRequestPriority, Error>
    }
    private var waiting: [Waiter] = []
    var queuedCount: Int { waiting.count }
    func acquire(priority: MediaRequestPriority = .foreground) async throws {
        _ = try await acquire(request: MediaRequestDemand(priority: priority))
    }
    /// The returned priority is the permit's original lease. Promotion changes
    /// scheduling, never how an already-acquired permit must be released.
    func acquire(request: MediaRequestDemand) async throws -> MediaRequestPriority {
        try Task.checkCancellation()
        if request.priority == .foreground, browsingPermits > 0,
           !waiting.contains(where: { $0.request.priority == .foreground }) {
            permits -= 1
            foregroundInUse += 1
            if Task.isCancelled { release(); throw CancellationError() }
            return .foreground
        }
        guard waiting.count < 64 else { throw RequestFailure.queueFull }
        let id = UUID()
        let lease: MediaRequestPriority = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let observer = request.observe { [weak self] in Task { await self?.resumeWaiting() } }
                waiting.append(Waiter(id: id, request: request, observer: observer, continuation: continuation))
                resumeWaiting()
            }
        } onCancel: { Task { await self.cancel(id) } }
        if Task.isCancelled { release(priority: lease); throw CancellationError() }
        return lease
    }
    private func cancel(_ id: UUID) {
        if let index = waiting.firstIndex(where: { $0.id == id }) {
            let waiter = waiting.remove(at: index)
            waiter.request.removeObserver(waiter.observer)
            waiter.continuation.resume(throwing: CancellationError())
            resumeWaiting()
        }
    }
    func release(priority: MediaRequestPriority = .foreground) {
        permits += 1
        switch priority {
        case .foreground: foregroundInUse -= 1
        case .prefetch: prefetchInUse -= 1
        case .thumbnail: thumbnailsInUse -= 1
        case .thumbnailPrefetch: thumbnailsInUse -= 1; coverPrefetchInUse -= 1
        case .download: break
        }
        resumeWaiting()
    }
    private func resumeWaiting() {
        while permits > 0 {
            let selected: (Int, MediaRequestPriority)?
            let browse = browsingPermits
            let allowsBackgroundBrowse = browse > 1 || (browse > 0 && allowFullWithForeground && foregroundInUse > 0)
            let allowsCover = thumbnailsInUse < thumbnailLimit
                && (reservedCoverCapacity > 0 || allowsBackgroundBrowse)
            let allowsCoverPrefetch = reservedCoverCapacity > 0
                ? coverPrefetchInUse < max(1, thumbnailLimit - 1)
                : thumbnailsInUse == 0
            if browse > 0, let foreground = waiting.firstIndex(where: { $0.request.priority == .foreground }) { selected = (foreground, .foreground) }
            else if allowsCover, let thumbnail = waiting.firstIndex(where: { $0.request.priority == .thumbnail }) {
                selected = (thumbnail, .thumbnail)
            }
            else if allowsBackgroundBrowse, prefetchInUse < prefetchLimit,
                    let prefetch = waiting.firstIndex(where: { $0.request.priority == .prefetch }) { selected = (prefetch, .prefetch) }
            else if allowsCover, allowsCoverPrefetch,
                    let upcoming = waiting.firstIndex(where: { $0.request.priority == .thumbnailPrefetch }) {
                selected = (upcoming, .thumbnailPrefetch)
            }
            else if permits > 1 + unusedCoverCapacity,
                    let download = waiting.firstIndex(where: { $0.request.priority == .download }) { selected = (download, .download) }
            else { selected = nil }
            guard let (index, lease) = selected else { return }
            let waiter = waiting.remove(at: index)
            permits -= 1
            switch lease {
            case .foreground: foregroundInUse += 1
            case .prefetch: prefetchInUse += 1
            case .thumbnail: thumbnailsInUse += 1
            case .thumbnailPrefetch: thumbnailsInUse += 1; coverPrefetchInUse += 1
            case .download: break
            }
            waiter.request.removeObserver(waiter.observer)
            waiter.continuation.resume(returning: lease)
        }
    }
}

final class FileTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var networkTask: URLSessionDataTask?
    private var traceID: UUID?
    private var networkStarted: TimeInterval?
    private var handle: FileHandle?
    private var bytes = 0
    private var totalBytes: Int64?
    private var lastProgressBytes = 0
    private var lastProgressTime: TimeInterval = 0
    private var progressDemand: MediaRequestDemand?
    private var cancelled = false
    private var receivedResponse = false
    private var firstResponseTask: Task<Void, Never>?
    private let firstResponseTimeout: TimeInterval
    private let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private let limit: Int64?
    private let client: MediaTransferClient
    init(limit: Int64?, configuration: URLSessionConfiguration? = nil, client: MediaTransferClient? = nil,
         firstResponseTimeout: TimeInterval = 10) {
        self.limit = limit
        self.firstResponseTimeout = max(0.001, firstResponseTimeout)
        self.client = client ?? (configuration == nil ? .shared : MediaTransferClient(configuration: configuration))
    }
    func fetch(_ url: URL, request demand: MediaRequestDemand? = nil) async throws -> URL {
        let observer = demand?.observe { [weak self, weak demand] in
            guard let demand else { return }; self?.applyPriority(demand.priority)
        }
        defer { if let observer { demand?.removeObserver(observer) } }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                progressDemand = demand
                do {
                    guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else { throw ViewerError.storage }
                    handle = try FileHandle(forWritingTo: file)
                    var request = URLRequest(url: url)
                    request.setValue("image/*,application/octet-stream;q=0.5", forHTTPHeaderField: "Accept")
                    let task = client.dataTask(with: request, delegate: self)
                    task.priority = demand?.priority == .foreground || demand == nil ? URLSessionTask.highPriority : URLSessionTask.lowPriority
                    networkTask = task
                    traceID = demand?.id; networkStarted = ProcessInfo.processInfo.systemUptime
                    lock.unlock()
                    // The gate has granted a slot. Waiting for response headers is
                    // network connection work, not time spent in our download queue.
                    if let trace = demand?.id { ReaderNetworkMetrics.record(trace, phase: "transfer-start", priority: demand?.priority) }
                    demand?.reportProgress(MediaLoadProgress(phase: .connecting))
                    updateFirstResponseDeadline(priority: demand?.priority)
                    task.resume()
                } catch { lock.unlock(); finish(.failure(ViewerError.storage)) }
            }
        } onCancel: { self.cancel() }
    }
    private func applyPriority(_ priority: MediaRequestPriority) {
        lock.lock(); let task = networkTask; lock.unlock()
        task?.priority = priority == .foreground ? URLSessionTask.highPriority : URLSessionTask.lowPriority
        updateFirstResponseDeadline(priority: priority)
    }
    /// Bound only a visible reader's wait for HTTP headers. Promotion of a
    /// stalled prefetch uses the elapsed connection time; body transfer and
    /// downloads keep the existing URLSession timeout policy.
    private func updateFirstResponseDeadline(priority: MediaRequestPriority?) {
        lock.lock(); defer { lock.unlock() }
        firstResponseTask?.cancel(); firstResponseTask = nil
        guard priority == .foreground, continuation != nil, !receivedResponse,
              let started = networkStarted else { return }
        let remaining = max(0, firstResponseTimeout - (ProcessInfo.processInfo.systemUptime - started))
        firstResponseTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            self?.expireFirstResponse()
        }
    }
    private func expireFirstResponse() {
        lock.lock()
        let shouldExpire = continuation != nil && !receivedResponse && progressDemand?.priority == .foreground
        let trace = traceID, started = networkStarted
        lock.unlock()
        guard shouldExpire else { return }
        if finish(.failure(RequestFailure.transport(.media, URLError.timedOut.rawValue))), let trace {
            ReaderNetworkMetrics.record(trace, phase: "first-response-timeout", started: started, outcome: "timeout")
        }
    }
    func cancel() { lock.lock(); cancelled = true; lock.unlock(); finish(.failure(CancellationError())) }
    @discardableResult private func finish(_ result: Result<URL, Error>) -> Bool {
        lock.lock()
        guard let continuation else { lock.unlock(); return false }
        self.continuation = nil
        firstResponseTask?.cancel(); firstResponseTask = nil
        try? handle?.close(); handle = nil
        let task = networkTask; networkTask = nil
        let trace = traceID, started = networkStarted, byteCount = bytes
        let progress = MediaLoadProgress(phase: .transferring, completedBytes: Int64(bytes), totalBytes: totalBytes)
        let progressDemand = self.progressDemand
        self.progressDemand = nil
        traceID = nil; networkStarted = nil
        lock.unlock()
        if case .success = result { progressDemand?.reportProgress(progress) }
        if case .failure = result { task?.cancel() }
        if let trace {
            let outcome: String
            switch result {
            case .success: outcome = "ok"
            case .failure(let error): outcome = error is CancellationError ? "cancelled" : "failed"
            }
            ReaderNetworkMetrics.record(trace, phase: "transfer", started: started, outcome: outcome, bytes: byteCount)
        }
        if case .failure = result { try? FileManager.default.removeItem(at: file) }
        continuation.resume(with: result)
        return true
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        guard continuation != nil else { lock.unlock(); completionHandler(.cancel); return }
        receivedResponse = true; firstResponseTask?.cancel(); firstResponseTask = nil; lock.unlock()
        guard let response = response as? HTTPURLResponse, let url = response.url, URLPolicy.media(url) else { completionHandler(.cancel); finish(.failure(ViewerError.restricted)); return }
        if response.statusCode == 509 { completionHandler(.cancel); finish(.failure(ViewerError.imageLimit)); return }
        if response.value(forHTTPHeaderField: "cf-mitigated")?.lowercased() == "challenge" {
            completionHandler(.cancel); finish(.failure(ViewerError.challenge)); return
        }
        if response.statusCode == 401 { completionHandler(.cancel); finish(.failure(ViewerError.authentication)); return }
        guard (200...299).contains(response.statusCode) else { completionHandler(.cancel); finish(.failure(RequestFailure.http(.media, response.statusCode))); return }
        if let limit, response.expectedContentLength > limit { completionHandler(.cancel); finish(.failure(ViewerError.tooLarge)); return }
        let mime = response.mimeType?.lowercased() ?? ""
        guard mime.hasPrefix("image/") || mime == "application/octet-stream" else { completionHandler(.cancel); finish(.failure(RequestFailure.nonImage)); return }
        lock.lock()
        totalBytes = response.expectedContentLength > 0 ? response.expectedContentLength : nil
        let received = Int64(bytes), total = totalBytes, demand = progressDemand
        lastProgressBytes = bytes; lastProgressTime = ProcessInfo.processInfo.systemUptime
        lock.unlock()
        demand?.reportProgress(MediaLoadProgress(phase: .transferring, completedBytes: received, totalBytes: total))
        if let trace = demand?.id { ReaderNetworkMetrics.record(trace, phase: "response-headers") }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard continuation != nil else { lock.unlock(); return }
        bytes += data.count
        if let limit, Int64(bytes) > limit { lock.unlock(); finish(.failure(ViewerError.tooLarge)); return }
        do {
            try handle?.write(contentsOf: data)
            let now = ProcessInfo.processInfo.systemUptime
            let shouldReport = bytes - lastProgressBytes >= 65_536 || now - lastProgressTime >= 0.1
            let received = Int64(bytes), total = totalBytes, demand = progressDemand
            if shouldReport { lastProgressBytes = bytes; lastProgressTime = now }
            lock.unlock()
            if shouldReport { demand?.reportProgress(MediaLoadProgress(phase: .transferring, completedBytes: received, totalBytes: total)) }
        }
        catch { lock.unlock(); finish(.failure(ViewerError.storage)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let error = error as NSError
            if error.domain == NSURLErrorDomain && error.code == URLError.cancelled.rawValue { finish(.failure(CancellationError())) }
            else { finish(.failure(RequestFailure.transport(.media, error.domain == NSURLErrorDomain ? error.code : URLError.unknown.rawValue))) }
        } else { finish(.success(file)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, URLPolicy.media(url) else { completionHandler(nil); finish(.failure(RequestFailure.redirectRejected)); return }
        var safe = request; safe.setValue(nil, forHTTPHeaderField: "Cookie"); safe.setValue(nil, forHTTPHeaderField: "Referer"); completionHandler(safe)
    }
}

actor MediaRepository {
    static let shared = MediaRepository()
    private let gate = TransferGate.mediaTransfers()
    nonisolated let root: URL
    private nonisolated let browseCachePins = BrowseCachePinRegistry()
    private let transferClient: MediaTransferClient
    private let budget: Int64
    private var cacheIndexes: [String: BrowseCacheIndex] = [:]
    private var pendingCacheTouches: [String: [String: Date]] = [:]
    private var epochs: [String: UUID] = [:]
    private struct FlightKey: Hashable { let owner: String; let url: URL; let epoch: UUID }
    private struct Consumer {
        let demand: MediaRequestDemand
        let observer: UUID
        let progressObserver: UUID
        let progressBindingToken: UUID
        let continuation: CheckedContinuation<URL, Error>
    }
    private final class Flight {
        let id = UUID()
        let demand: MediaRequestDemand
        var consumers: [UUID: Consumer] = [:]
        var task: Task<Void, Never>?
        init(priority: MediaRequestPriority) { demand = MediaRequestDemand(priority: priority) }
    }
    private var flights: [FlightKey: Flight] = [:]
    private struct PageCacheKey: Hashable { let scope: PageReadScope; let page: URL }
    private struct PageSource { let image: URL; let epoch: UUID; let date: Date }
    private var pageSources: [PageCacheKey: PageSource] = [:]
    init(root: URL? = nil, configuration: URLSessionConfiguration? = nil, browseCacheBudget: Int64 = 2_000_000_000) {
        self.root = root ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ExViewerMedia", isDirectory: true)
        self.transferClient = configuration == nil ? .shared : MediaTransferClient(configuration: configuration)
        self.budget = max(0, browseCacheBudget)
    }
    func directory(owner: String) -> URL { root.appendingPathComponent(owner, isDirectory: true) }

    nonisolated func setPinnedFiles(_ files: Set<URL>, owner: String, context: UUID) {
        browseCachePins.setPinnedFiles(files, owner: owner, context: context, root: root)
    }

    nonisolated func releasePinnedFiles(context: UUID) {
        browseCachePins.releasePinnedFiles(context: context)
    }
    func file(for url: URL, owner: String, priority: MediaRequestPriority = .foreground) async throws -> URL {
        try await file(for: url, owner: owner, request: MediaRequestDemand(priority: priority))
    }
    func file(for url: URL, owner: String, request: MediaRequestDemand) async throws -> URL {
        guard URLPolicy.media(url) else { throw ViewerError.restricted }
        try Task.checkCancellation()
        let epoch = epochs[owner] ?? UUID(); epochs[owner] = epoch
        let key = FlightKey(owner: owner, url: url, epoch: epoch)
        let target = target(for: url, owner: owner)
        if Self.cachedImageExists(at: target) {
            touch(target, owner: owner)
            request.reportProgress(MediaLoadProgress(phase: .ready))
            ReaderNetworkMetrics.record(request.id, phase: "cache-hit", priority: request.priority)
            return target
        }
        guard flights[key] != nil || flights.count < 80 else { throw RequestFailure.queueFull }
        let consumerID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                let flight = flights[key] ?? Flight(priority: request.priority)
                guard flight.consumers.count < 64 else { continuation.resume(throwing: RequestFailure.queueFull); return }
                flights[key] = flight
                let flightID = flight.id, sharedDemand = flight.demand
                ReaderNetworkMetrics.record(request.id, phase: "media-consumer", sharedRequest: sharedDemand.id, priority: request.priority)
                let observer = request.observe { [weak self] in Task { await self?.refreshPriority(key: key, flightID: flightID) } }
                let progressBindingToken = consumerID
                request.beginProgressForwarding(source: sharedDemand.id, token: progressBindingToken)
                let progressObserver = sharedDemand.observeProgressSnapshot { [weak request] snapshot in
                    request?.acceptForwardedProgress(snapshot, token: progressBindingToken)
                }
                flight.consumers[consumerID] = Consumer(demand: request, observer: observer,
                                                        progressObserver: progressObserver,
                                                        progressBindingToken: progressBindingToken,
                                                        continuation: continuation)
                refreshPriority(key: key, flightID: flight.id)
                if flight.task == nil {
                    flight.task = Task {
                        let result: Result<URL, Error>
                        do { result = .success(try await self.transfer(url: url, owner: owner, epoch: epoch, request: sharedDemand)) }
                        catch { result = .failure(error) }
                        self.complete(key: key, flightID: flightID, result: result)
                    }
                }
            }
        } onCancel: { Task { await self.cancelConsumer(key: key, id: consumerID) } }
    }
    private func refreshPriority(key: FlightKey, flightID: UUID) {
        guard let flight = flights[key], flight.id == flightID,
              let priority = flight.consumers.values.map({ $0.demand.priority }).min(by: { $0.rawValue < $1.rawValue }) else { return }
        flight.demand.setPriority(priority)
    }
    private func cancelConsumer(key: FlightKey, id: UUID) {
        guard let flight = flights[key], let consumer = flight.consumers.removeValue(forKey: id) else { return }
        consumer.demand.removeObserver(consumer.observer)
        consumer.demand.endProgressForwarding(token: consumer.progressBindingToken)
        flight.demand.removeProgressObserver(consumer.progressObserver)
        consumer.continuation.resume(throwing: CancellationError())
        if flight.consumers.isEmpty { flights.removeValue(forKey: key); flight.task?.cancel() }
        else { refreshPriority(key: key, flightID: flight.id) }
    }
    private func complete(key: FlightKey, flightID: UUID, result: Result<URL, Error>) {
        guard let flight = flights[key], flight.id == flightID else { return }
        flights.removeValue(forKey: key)
        for consumer in flight.consumers.values {
            consumer.demand.removeObserver(consumer.observer)
            consumer.demand.endProgressForwarding(token: consumer.progressBindingToken)
            flight.demand.removeProgressObserver(consumer.progressObserver)
            consumer.continuation.resume(with: result)
        }
        flight.consumers.removeAll()
    }
    private func target(for url: URL, owner: String) -> URL {
        let directory = directory(owner: owner)
        let key = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(key)
    }
    private static func cachedImageExists(at file: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return false }
        return CGImageSourceGetCount(source) > 0
    }

    func discardUndecodableBrowseFile(_ file: URL, owner: String) {
        let file = file.standardizedFileURL
        guard file.deletingLastPathComponent() == directory(owner: owner).standardizedFileURL,
              StaticCoverImageCache.decodeThumbnail(file: file, maxPixelSize: 64) == nil,
              let result = try? browseCachePins.removeIfUnpinned(file, owner: owner, root: root),
              case .removed = result else { return }
        cacheIndexes[owner]?.confirmRemoved(file)
        pendingCacheTouches[owner]?.removeValue(forKey: file.path)
    }
    private func touch(_ file: URL, owner: String) {
        let now = Date()
        if let index = cacheIndexes[owner], index.isBootstrapped, index.contains(file) {
            let due = index.touch(file, at: now)
            if due, browseCachePins.persistAccessDateIfUnpinned(file, owner: owner, root: root, date: now) {
                index.markAccessWriteAttempted(file, at: now)
            }
            cacheIndexes[owner] = index
            return
        }

        // Cache hits before the first miss commit remain O(1) and do not scan
        // the directory just to update recency.
        let path = file.standardizedFileURL.path
        let prior = pendingCacheTouches[owner]?[path]
        if let prior, now.timeIntervalSince(prior) < 45 {
            pendingCacheTouches[owner]?[path] = now
            return
        }
        if !browseCachePins.persistAccessDateIfUnpinned(file, owner: owner, root: root, date: now) {
            pendingCacheTouches[owner, default: [:]][path] = now
            return
        }
        pendingCacheTouches[owner, default: [:]][path] = now
    }
    private func transfer(url: URL, owner: String, epoch: UUID, request: MediaRequestDemand) async throws -> URL {
        let queued = ProcessInfo.processInfo.systemUptime
        request.reportProgress(MediaLoadProgress(phase: .queued))
        ReaderNetworkMetrics.record(request.id, phase: "queue-start", priority: request.priority)
        let lease: MediaRequestPriority
        do { lease = try await gate.acquire(request: request) }
        catch { ReaderNetworkMetrics.record(request.id, phase: "queue", started: queued, outcome: error is CancellationError ? "cancelled" : "failed"); throw error }
        ReaderNetworkMetrics.record(request.id, phase: "queue", started: queued, priority: request.priority)
        defer { Task { await gate.release(priority: lease) } }
        try Task.checkCancellation()
        guard epochs[owner] == epoch else { throw CancellationError() }
        let directory = directory(owner: owner), target = target(for: url, owner: owner)
        // Another completed consumer may have filled the cache while queued.
        if Self.cachedImageExists(at: target) {
            touch(target, owner: owner)
            request.reportProgress(MediaLoadProgress(phase: .ready))
            return target
        }
        let temporary = try await FileTransfer(limit: 64_000_000, client: transferClient).fetch(url, request: request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let preview = await StaticCoverImageCache.decode(file: temporary, maxPixelSize: 64)
        try Task.checkCancellation()
        guard epochs[owner] == epoch else { throw CancellationError() }
        guard preview != nil else { throw ViewerError.unsupported }
        try commitBrowseFile(temporary, target: target, directory: directory, owner: owner)
        request.reportProgress(request.progress.replacingPhase(.ready))
        return target
    }

    private func commitBrowseFile(_ temporary: URL, target: URL, directory: URL, owner: String) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: temporary.path)
        guard let incomingNumber = attributes[.size] as? NSNumber else { throw ViewerError.storage }
        let incomingSize = incomingNumber.int64Value
        guard incomingSize >= 0, incomingSize <= budget else { throw ViewerError.storage }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let index = cacheIndexes[owner] ?? BrowseCacheIndex()
        try index.bootstrap(directory: directory)
        if let pending = pendingCacheTouches.removeValue(forKey: owner) {
            for (path, date) in pending.sorted(by: { $0.value < $1.value }) {
                _ = index.touch(URL(fileURLWithPath: path), at: date)
            }
        }
        cacheIndexes[owner] = index
        defer { cacheIndexes[owner] = index }

        // Replace a known corrupt/obsolete target before calculating room.
        if FileManager.default.fileExists(atPath: target.path) {
            do { try FileManager.default.removeItem(at: target) }
            catch {
                guard !FileManager.default.fileExists(atPath: target.path) else { throw ViewerError.storage }
            }
            guard !FileManager.default.fileExists(atPath: target.path) else { throw ViewerError.storage }
        }
        index.confirmRemoved(target)

        while index.usedBytes > budget - incomingSize {
            let pinned = browseCachePins.pinnedPaths(owner: owner)
            guard let oldest = index.oldestEvictable(pinnedPaths: pinned) else { throw ViewerError.storage }
            switch try browseCachePins.removeIfUnpinned(oldest.url, owner: owner, root: root) {
            case .pinned:
                continue
            case .removed:
                index.confirmRemoved(oldest.url)
            }
        }

        try FileManager.default.moveItem(at: temporary, to: target)
        index.record(target, size: incomingSize, at: Date())
    }

    /// Associate the page with its completed image for cache-to-offline promotion.
    /// This bounded hint stays in memory; a miss uses the normal page resolver.
    func pageFile(for image: URL, page: URL, scope: PageReadScope, request: MediaRequestDemand) async throws -> URL {
        let owner = scope.owner
        let epoch = epochs[owner] ?? UUID(); epochs[owner] = epoch
        let file = try await self.file(for: image, owner: owner, request: request)
        if epochs[owner] == epoch {
            pageSources[PageCacheKey(scope: scope, page: page)] = PageSource(image: image, epoch: epoch, date: Date())
            if pageSources.count > 1_024, let oldest = pageSources.min(by: { $0.value.date < $1.value.date })?.key {
                pageSources.removeValue(forKey: oldest)
            }
        }
        return file
    }

    private func cachedPagePath(_ page: URL, scope: PageReadScope) -> URL? {
        let key = PageCacheKey(scope: scope, page: page)
        guard let source = pageSources[key], epochs[scope.owner] == source.epoch else { return nil }
        return target(for: source.image, owner: scope.owner)
    }

    func cachedPage(_ page: URL, scope: PageReadScope) -> URL? {
        guard let cached = cachedPagePath(page, scope: scope), Self.cachedImageExists(at: cached) else { return nil }
        touch(cached, owner: scope.owner)
        return cached
    }

    /// Only copies existing bytes. A missing hint/file never starts a request.
    func copyCachedPage(_ page: URL, scope: PageReadScope, destination: URL) throws -> Bool {
        try Task.checkCancellation()
        if Self.isDecodableImage(at: destination) { return true }
        guard let cached = cachedPagePath(page, scope: scope), Self.isDecodableImage(at: cached) else { return false }
        try persistManualFile(cached, destination: destination, copying: true)
        touch(cached, owner: scope.owner)
        return true
    }

    /// Copies a valid owner-scoped browse file first; otherwise streams to a
    /// durable destination with no browsing-cache size or storage cap.
    func saveManual(url: URL, owner: String, destination: URL, allowNetwork: Bool = true,
                    request: MediaRequestDemand = MediaRequestDemand(priority: .download)) async throws -> URL {
        let paidPaths = Set(["archiver.php", "fullimg.php", "hathdl.php", "home.php"])
        guard URLPolicy.media(url), !url.path.lowercased().split(separator: "/").contains(where: { paidPaths.contains(String($0)) }) else { throw ViewerError.restricted }
        try Task.checkCancellation()
        let cached = target(for: url, owner: owner)
        func useLocalFile() throws -> Bool {
            if Self.isDecodableImage(at: destination) { return true }
            guard Self.isDecodableImage(at: cached) else { return false }
            try persistManualFile(cached, destination: destination, copying: true)
            touch(cached, owner: owner)
            return true
        }
        if try useLocalFile() { return destination }
        guard allowNetwork else { throw ViewerError.imageLimit }
        let lease = try await gate.acquire(request: request)
        defer { Task { await gate.release(priority: lease) } }
        if try useLocalFile() { return destination }
        let temporary = try await FileTransfer(limit: nil, client: transferClient).fetch(url, request: request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        guard Self.isDecodableImage(at: temporary) else { throw ViewerError.unsupported }
        if !Self.isDecodableImage(at: destination) {
            try persistManualFile(temporary, destination: destination, copying: false)
        }
        return destination
    }

    private func persistManualFile(_ source: URL, destination: URL, copying: Bool) throws {
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let staged = directory.appendingPathComponent(".manual-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: staged) }
        if copying { try FileManager.default.copyItem(at: source, to: staged) }
        else { try FileManager.default.moveItem(at: source, to: staged) }
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destination.path) {
            let backup = directory.appendingPathComponent(".manual-\(UUID().uuidString).bak")
            try FileManager.default.moveItem(at: destination, to: backup)
            do {
                try FileManager.default.moveItem(at: staged, to: destination)
                try? FileManager.default.removeItem(at: backup)
            } catch {
                if !FileManager.default.fileExists(atPath: destination.path) { try? FileManager.default.moveItem(at: backup, to: destination) }
                throw error
            }
        } else { try FileManager.default.moveItem(at: staged, to: destination) }
    }

    func hasValidManualFile(at url: URL) -> Bool { Self.isDecodableImage(at: url) }

    func copyOfflinePage(_ source: URL, to destination: URL) throws -> Bool {
        try Task.checkCancellation()
        if Self.isDecodableImage(at: destination) { return true }
        guard Self.isDecodableImage(at: source) else { return false }
        try persistManualFile(source, destination: destination, copying: true)
        return true
    }

    private static func isDecodableImage(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else { return false }
        return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
    }
    func clear(owner: String) throws {
        epochs[owner] = UUID()
        pageSources = pageSources.filter { $0.key.scope.owner != owner }
        for (key, flight) in flights.filter({ $0.key.owner == owner }) {
            flights.removeValue(forKey: key); flight.task?.cancel()
            for consumer in flight.consumers.values {
                consumer.demand.removeObserver(consumer.observer)
                consumer.demand.endProgressForwarding(token: consumer.progressBindingToken)
                flight.demand.removeProgressObserver(consumer.progressObserver)
                consumer.continuation.resume(throwing: CancellationError())
            }
            flight.consumers.removeAll()
        }
        let directory = directory(owner: owner)
        try browseCachePins.withOwnerCleared(owner: owner) {
            if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        }
        cacheIndexes.removeValue(forKey: owner)
        pendingCacheTouches.removeValue(forKey: owner)
    }
}
