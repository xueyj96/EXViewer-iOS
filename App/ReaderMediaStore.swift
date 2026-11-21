import Foundation
import SwiftUI
import ExViewerCore

enum MediaRequestPriority: Int, Sendable, Equatable {
    case foreground = 0
    case prefetch = 1
    case thumbnail = 2
    case thumbnailPrefetch = 3
    case download = 4
}

struct ReaderMediaScope: Hashable, Sendable {
    var galleryID: String
    var owner: String
    var generation: UUID
    var context: UUID
}

@MainActor final class ReaderMediaStore: ObservableObject {
    typealias Loader = @MainActor @Sendable (GalleryPage, MediaRequestPriority) async throws -> URL
    typealias DemandLoader = @MainActor @Sendable (GalleryPage, MediaRequestDemand) async throws -> URL
    typealias Validity = @MainActor () -> Bool

    @Published private(set) var files: [Int: URL] = [:]
    @Published private(set) var failures: [Int: Error] = [:]
    @Published private(set) var inflight: [Int: MediaRequestPriority] = [:]
    @Published private(set) var progress: [Int: MediaLoadProgress] = [:]
    @Published private(set) var prefetchCount = 0
    @Published private(set) var downloadConcurrency = 2
    @Published private(set) var prefetchPaused = false
    @Published private(set) var currentPage: Int?
    private var requestedNeighbor: Int?
    private var retainedNeighbor: Int?

    private enum PrefetchPauseReason: Equatable {
        case network
        case restricted
    }

    private struct RunningRequest {
        var token: UUID
        var demand: MediaRequestDemand
        var progressObserver: UUID
        var progressThrottle: ReaderProgressThrottle
        var lastProgressDelivery: UInt64 = 0
        var priority: MediaRequestPriority { demand.priority }
        var url: URL
        var task: Task<Void, Never>
    }

    private var scope: ReaderMediaScope?
    private var pages: [Int: GalleryPage] = [:]
    private var requests: [Int: RunningRequest] = [:]
    private var loader: DemandLoader?
    private var failurePriorities: [Int: MediaRequestPriority] = [:]
    private var foregroundRecoveryUsed = Set<Int>()
    private var prefetchPauseReason: PrefetchPauseReason?
    private var networkFailurePages = Set<Int>()
    private var connectivityEpoch: UInt64 = 0
    private var isCurrent: Validity?
    private var revision = UUID()
    private let backgroundWork: BackgroundWork?
    private var isForeground = true

    init(backgroundWork: BackgroundWork? = nil) { self.backgroundWork = backgroundWork }

    func setForeground(_ foreground: Bool) {
        isForeground = foreground
        if foreground { schedule() }
    }

    /// Keeps current demand first, a bounded forward window on disk and up to
    /// sixteen already-loaded preceding pages for fast reverse reading.
    func update(scope newScope: ReaderMediaScope,
                pages newPages: [GalleryPage],
                current newCurrent: Int,
                prefetchCount requestedCount: Int,
                downloadConcurrency requestedConcurrency: Int = 2,
                preview requestedPreview: Int? = nil,
                validateCachedFile: ((URL) -> Bool)? = nil,
                loader newLoader: @escaping Loader,
                isCurrent validity: @escaping Validity) {
        update(scope: newScope, pages: newPages, current: newCurrent, prefetchCount: requestedCount,
               downloadConcurrency: requestedConcurrency, preview: requestedPreview, validateCachedFile: validateCachedFile,
               demandLoader: { page, request in try await newLoader(page, request.priority) },
               isCurrent: validity)
    }

    func update(scope newScope: ReaderMediaScope,
                pages newPages: [GalleryPage],
                current newCurrent: Int,
                prefetchCount requestedCount: Int,
                downloadConcurrency requestedConcurrency: Int = 2,
                preview requestedPreview: Int? = nil,
                validateCachedFile: ((URL) -> Bool)? = nil,
                demandLoader newLoader: @escaping DemandLoader,
                isCurrent validity: @escaping Validity) {
        let count = min(128, max(0, requestedCount))
        let concurrency = min(16, max(2, requestedConcurrency))
        let mapped = Dictionary(newPages.map { ($0.index, $0) }, uniquingKeysWith: { _, latest in latest })
        loader = newLoader
        isCurrent = validity
        let scopeChanged = scope != newScope
        let settingsChanged = prefetchCount != count || downloadConcurrency != concurrency
        let oldPages = pages
        let previousNeighbor = requestedNeighbor

        if scopeChanged {
            invalidateRequests()
            files.removeAll()
            failures.removeAll()
            progress.removeAll()
            failurePriorities.removeAll(); foregroundRecoveryUsed.removeAll()
            clearPrefetchPause(advanceEpoch: true)
            scope = newScope
        }

        pages = mapped
        currentPage = newCurrent
        prefetchCount = count
        downloadConcurrency = concurrency
        requestedNeighbor = requestedPreview.flatMap { abs($0 - newCurrent) == 1 && mapped[$0] != nil ? $0 : nil }

        if scopeChanged || settingsChanged || prefetchPaused { retainedNeighbor = nil }
        if !scopeChanged {
            var desired = desiredRequests(current: newCurrent, count: count, in: mapped)
            if !settingsChanged, !prefetchPaused {
                retainedNeighbor = retainableNeighbor(previous: previousNeighbor, current: newCurrent, desired: desired)
                if let retainedNeighbor { desired[retainedNeighbor] = .prefetch }
            }
            let obsolete = requests.compactMap { index, request -> Int? in
                guard let page = mapped[index], page.url == request.url,
                      let priority = desired[index] else { return index }
                // Change the demand on the same transport without restarting bytes.
                if request.priority != priority {
                    request.demand.setPriority(priority)
                    inflight[index] = priority
                }
                return nil
            }
            for index in obsolete {
                cancelRequest(at: index)
            }

            // Zero disables automatic future requests, not reuse of a completed
            // adjacent page. Retaining file URLs does not decode all images.
            let adjacent = mapped.keys.filter { abs($0 - newCurrent) == 1 }
            let preceding = files.keys.filter { $0 < newCurrent }.sorted(by: >).prefix(16)
            let retained = Set(desired.keys).union(adjacent).union(preceding)
            files = files.filter { index, _ in
                guard retained.contains(index),
                      let oldPage = oldPages[index], let newPage = mapped[index] else { return false }
                // `oldPage.url` / `newPage.url` identify the remote gallery page;
                // `url` is the loader's local cache file and has a different URL.
                return oldPage.url == newPage.url
            }
            failures = failures.filter { index, _ in
                guard retained.contains(index),
                      let oldPage = oldPages[index], let newPage = mapped[index] else { return false }
                return oldPage.url == newPage.url
            }
            let visible = Set([newCurrent, requestedNeighbor].compactMap { $0 })
            progress = progress.filter { index, _ in
                guard visible.contains(index),
                      let oldPage = oldPages[index], let newPage = mapped[index] else { return false }
                return oldPage.url == newPage.url
            }
            failurePriorities = failurePriorities.filter { failures[$0.key] != nil }
            foregroundRecoveryUsed = foregroundRecoveryUsed.filter { oldPages[$0]?.url == mapped[$0]?.url }
        }
        for (index, request) in requests where index == newCurrent || index == requestedNeighbor {
            progress[index] = request.demand.progress
        }
        for index in [newCurrent, requestedNeighbor].compactMap({ $0 }) {
            if files[index] != nil { progress[index] = MediaLoadProgress(phase: .ready) }
            if let file = files[index], let validateCachedFile, !validateCachedFile(file) {
                files.removeValue(forKey: index)
                failures.removeValue(forKey: index); failurePriorities.removeValue(forKey: index)
                progress.removeValue(forKey: index)
            }
            guard failurePriorities[index] == .prefetch,
                  let error = failures[index] as? RequestFailure, error.canRetryWhenVisible,
                  foregroundRecoveryUsed.insert(index).inserted else { continue }
            failures.removeValue(forKey: index); failurePriorities.removeValue(forKey: index)
        }
        schedule()
    }

    /// Explicitly retries a failed visible or prefetched page. Ordinary updates never retry failures.
    func retry(page index: Int) {
        guard scope != nil, pages[index] != nil, isCurrent?() == true else { return }
        failures.removeValue(forKey: index)
        failurePriorities.removeValue(forKey: index)
        clearPrefetchPause(advanceEpoch: true)
        schedule()
    }

    func retryInvalidFile(page index: Int, file: URL) {
        guard files[index] == file else { return }
        files.removeValue(forKey: index)
        retry(page: index)
    }

    func reset() {
        invalidateRequests()
        scope = nil; pages = [:]; loader = nil; isCurrent = nil
        files = [:]; failures = [:]; inflight = [:]; progress = [:]
        failurePriorities = [:]; foregroundRecoveryUsed = []
        currentPage = nil; prefetchCount = 0
        downloadConcurrency = 2
        clearPrefetchPause(advanceEpoch: true)
        requestedNeighbor = nil
        retainedNeighbor = nil
    }

    private func invalidateRequests() {
        revision = UUID()
        for request in requests.values {
            request.demand.removeProgressObserver(request.progressObserver)
            request.progressThrottle.cancel()
            request.task.cancel()
        }
        requests.removeAll()
        retainedNeighbor = nil
        inflight.removeAll()
        progress.removeAll()
        backgroundWork?.finish(.paused)
    }

    private func cancelRequest(at index: Int) {
        guard let request = requests.removeValue(forKey: index) else { return }
        if retainedNeighbor == index { retainedNeighbor = nil }
        request.demand.removeProgressObserver(request.progressObserver)
        request.progressThrottle.cancel()
        request.task.cancel()
        inflight.removeValue(forKey: index)
        progress.removeValue(forKey: index)
        if requests.isEmpty { backgroundWork?.finish(.paused) }
    }

    private func desiredRequests(current: Int, count: Int, in pages: [Int: GalleryPage]) -> [Int: MediaRequestPriority] {
        var desired: [Int: MediaRequestPriority] = [:]
        if pages[current] != nil { desired[current] = .foreground }
        for index in prefetchWindow(after: current, count: count, in: pages) {
            desired[index] = .prefetch
        }
        if let requestedNeighbor, pages[requestedNeighbor] != nil { desired[requestedNeighbor] = .foreground }
        return desired
    }

    /// Hold a request the user already started through gesture release. It can
    /// occupy only unused background capacity and cannot start a new request.
    private func retainableNeighbor(previous: Int?, current: Int, desired: [Int: MediaRequestPriority]) -> Int? {
        guard let candidate = [previous, retainedNeighbor].compactMap({ $0 }).first(where: { index in
            abs(index - current) == 1 && desired[index] == nil &&
                requests[index].map { pages[index]?.url == $0.url } == true
        }) else { return nil }
        let active = requests.filter { index, request in
            pages[index]?.url == request.url && desired[index] != nil
        }
        let background = active.keys.filter { desired[$0] == .prefetch }.count
        let foreground = active.count - background
        return background < downloadConcurrency - max(1, foreground) ? candidate : nil
    }

    private func prefetchWindow(after page: Int, count: Int, in pages: [Int: GalleryPage]) -> ArraySlice<Int> {
        pages.keys.filter { $0 > page }.sorted().prefix(count)
    }

    private func needsRequest(_ page: Int) -> Bool {
        files[page] == nil && failures[page] == nil && requests[page] == nil
    }

    private func schedule() {
        guard isForeground, scope != nil, isCurrent?() == true, let loader else { return }
        let current = currentPage
        if let current { admitForeground(current, loader: loader) }

        // A live preview or a waiting turn has foreground priority even with
        // prefetch disabled. The current page still gets the first slot.
        if let requestedNeighbor, !requests.values.contains(where: { $0.priority == .foreground }) {
            admitForeground(requestedNeighbor, loader: loader)
        }

        guard prefetchCount > 0, !prefetchPaused, let current else { return }
        let foregroundCount = requests.values.filter { $0.priority == .foreground }.count
        let prefetchSlots = max(0, downloadConcurrency - max(1, foregroundCount))
        for index in prefetchWindow(after: current, count: prefetchCount, in: pages) {
            guard requests.count < downloadConcurrency,
                  requests.values.filter({ $0.priority == .prefetch }).count < prefetchSlots else { break }
            if needsRequest(index) {
                start(page: index, priority: .prefetch, loader: loader)
            }
        }
    }

    private func admitForeground(_ index: Int, loader: @escaping DemandLoader) {
        guard pages[index] != nil, needsRequest(index) else { return }
        if requests.count == downloadConcurrency {
            // Evict only when this foreground request is eligible to start.
            let candidate = retainedNeighbor ?? requests.filter { $0.value.priority == .prefetch }.keys.max()
            if let candidate { cancelRequest(at: candidate) }
        }
        guard requests.count < downloadConcurrency else { return }
        start(page: index, priority: .foreground, loader: loader)
    }

    private func start(page index: Int, priority: MediaRequestPriority, loader: @escaping DemandLoader) {
        guard let page = pages[index], let scope, isCurrent?() == true else { return }
        let expectedRevision = revision
        let requestConnectivityEpoch = connectivityEpoch
        let startedAsCurrentForeground = priority == .foreground && index == currentPage
        let token = UUID()
        let demand = MediaRequestDemand(priority: priority)
        let progressThrottle = ReaderProgressThrottle { [weak self, weak demand] delivery in
            Task { @MainActor [weak self, weak demand] in
                guard let self, let demand,
                      self.revision == expectedRevision,
                      self.scope == scope,
                      var request = self.requests[index], request.token == token,
                      delivery.sequence > request.lastProgressDelivery,
                      self.isCurrent?() == true,
                      self.currentPage == index || self.requestedNeighbor == index else { return }
                // A direct phase change can end forwarding while an earlier
                // producer delivery is waiting for MainActor. Do not replay it.
                let latest = demand.progressSnapshot
                guard delivery.snapshot.producerUUID == latest.producerUUID else { return }
                request.lastProgressDelivery = delivery.sequence
                self.requests[index] = request
                // Promotion/update may already have displayed a newer byte
                // value before this actor hop runs. Consume the latest demand
                // snapshot, never rewind it to the coalescer's captured tail.
                if self.progress[index] != latest.value {
                    self.progress[index] = latest.value
                }
            }
        }
        let progressObserver = demand.observeProgressSnapshot { [weak demand] _ in
            guard let demand else { return }
            progressThrottle.receiveLatest(from: demand)
        }
        if index == currentPage || index == requestedNeighbor { progress[index] = demand.progress }
        if requests.isEmpty {
            backgroundWork?.beginShort("阅读缓存") { [weak self] in
                guard let self, !self.isForeground else { return }
                self.invalidateRequests()
            }
        }
        let task = Task { [weak self] in
            defer { progressThrottle.cancel() }
            do {
                try Task.checkCancellation()
                let url = try await loader(page, demand)
                guard let self,
                      self.revision == expectedRevision,
                      self.scope == scope,
                      self.isCurrent?() == true,
                      self.requests[index]?.token == token else { return }
                self.files[index] = url
                self.failures.removeValue(forKey: index)
                self.failurePriorities.removeValue(forKey: index)
                if self.prefetchPauseReason == nil { self.networkFailurePages.removeAll() }
                if startedAsCurrentForeground,
                   self.currentPage == index,
                   self.prefetchPauseReason == .network,
                   self.connectivityEpoch == requestConnectivityEpoch {
                    self.clearPrefetchPause(advanceEpoch: false)
                }
                if self.currentPage == index || self.requestedNeighbor == index {
                    self.progress[index] = demand.progress.replacingPhase(.ready)
                }
            } catch is CancellationError {
                // Cancellation is expected on jumps, scope changes, or prefetch edits.
                guard let self,
                      self.revision == expectedRevision,
                      self.requests[index]?.token == token else { return }
                self.progress.removeValue(forKey: index)
            } catch {
                guard let self,
                      self.revision == expectedRevision,
                      self.scope == scope,
                      self.isCurrent?() == true,
                      self.requests[index]?.token == token else { return }
                self.failures[index] = error
                self.failurePriorities[index] = demand.priority
                self.progress.removeValue(forKey: index)
                if let reason = Self.pauseReason(for: error), self.shouldPause(reason, afterFailureAt: index) {
                    for other in Array(self.requests.keys) where other != index {
                        guard let otherRequest = self.requests[other],
                              otherRequest.priority == .prefetch || otherRequest.priority == .thumbnail else { continue }
                        self.cancelRequest(at: other)
                    }
                }
            }
            guard let self, self.revision == expectedRevision, self.requests[index]?.token == token else { return }
            if let finished = self.requests[index] {
                finished.demand.removeProgressObserver(finished.progressObserver)
                finished.progressThrottle.cancel()
            }
            self.requests.removeValue(forKey: index)
            if self.retainedNeighbor == index { self.retainedNeighbor = nil }
            self.inflight.removeValue(forKey: index)
            self.schedule()
            if self.requests.isEmpty { self.backgroundWork?.finish(.completed) }
        }
        requests[index] = RunningRequest(token: token, demand: demand, progressObserver: progressObserver,
                                         progressThrottle: progressThrottle, url: page.url, task: task)
        inflight[index] = priority
    }

    /// One bad image source must not discard healthy neighboring transfers.
    /// Three different pages failing without a success establish a broader
    /// connectivity failure. Failed pages retain their existing explicit /
    /// visible retry budget; filling the window never retries them.
    private func shouldPause(_ reason: PrefetchPauseReason, afterFailureAt index: Int) -> Bool {
        if reason == .network {
            guard prefetchPauseReason != .restricted else { return false }
            if networkFailurePages.count < 3 { networkFailurePages.insert(index) }
            guard networkFailurePages.count >= 3 else { return false }
        }
        pausePrefetch(reason)
        return true
    }

    private func pausePrefetch(_ reason: PrefetchPauseReason) {
        switch reason {
        case .restricted:
            prefetchPauseReason = .restricted
            prefetchPaused = true
        case .network:
            guard prefetchPauseReason == nil else { return }
            connectivityEpoch &+= 1
            prefetchPauseReason = .network
            prefetchPaused = true
        }
    }

    private func clearPrefetchPause(advanceEpoch: Bool) {
        prefetchPauseReason = nil
        prefetchPaused = false
        networkFailurePages.removeAll()
        if advanceEpoch { connectivityEpoch &+= 1 }
    }

    private static func pauseReason(for error: Error) -> PrefetchPauseReason? {
        if let error = error as? ViewerError {
            switch error {
            case .imageLimit, .challenge, .authentication: return .restricted
            default: break
            }
        }
        if case RequestFailure.http(_, 429) = error { return .restricted }
        if case let RequestFailure.transport(_, code) = error,
           [URLError.networkConnectionLost.rawValue, URLError.timedOut.rawValue, URLError.cannotConnectToHost.rawValue].contains(code) {
            return .network
        }
        return nil
    }
}
