import Foundation

/// Schedules site-page work and paced search and metadata dispatches.
/// Leases remain active until explicitly released, even if the limit changes.
@MainActor final class SiteRequestScheduler {
    enum Pacing: Hashable { case search, metadata, download }

    private final class Waiter {
        let id: UUID
        let demand: MediaRequestDemand
        let pacing: Pacing?
        let order: UInt64
        let continuation: CheckedContinuation<UUID, Error>
        var observer: UUID?

        init(id: UUID, demand: MediaRequestDemand, pacing: Pacing?, order: UInt64,
             continuation: CheckedContinuation<UUID, Error>) {
            self.id = id; self.demand = demand; self.pacing = pacing
            self.order = order; self.continuation = continuation
        }
    }

    private struct Active {
        let demand: MediaRequestDemand
    }

    private let searchInterval: TimeInterval
    private var limit = SiteRequestPolicy.defaultConcurrency
    private var waiters: [Waiter] = []
    private var active: [UUID: Active] = [:]
    private var nextOrder: UInt64 = 0
    private var lastStarts: [Pacing: TimeInterval] = [:]
    private var timer: Task<Void, Never>?

    init(searchInterval: TimeInterval = 3.1) {
        self.searchInterval = max(0, searchInterval)
    }

    var activeCount: Int { active.count }
    var queuedCount: Int { waiters.count }

    func setLimit(_ requestedLimit: Int) {
        limit = SiteRequestPolicy.clampedConcurrency(requestedLimit)
        pump()
    }

    func acquire(request: MediaRequestDemand, pacing: Pacing?, limit requestedLimit: Int) async throws -> UUID {
        try Task.checkCancellation()
        limit = SiteRequestPolicy.clampedConcurrency(requestedLimit)
        let id = UUID()
        do {
            let lease = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let dispatchPacing = effectivePacing(pacing, for: request)
                    if canGrantImmediately(request: request, pacing: dispatchPacing) {
                        active[id] = Active(demand: request)
                        if let dispatchPacing { lastStarts[dispatchPacing] = ProcessInfo.processInfo.systemUptime }
                        continuation.resume(returning: id)
                        return
                    }
                    guard waiters.count < 64 else {
                        continuation.resume(throwing: RequestFailure.pageQueueFull)
                        return
                    }
                    nextOrder &+= 1
                    let waiter = Waiter(id: id, demand: request, pacing: pacing,
                                        order: nextOrder, continuation: continuation)
                    waiter.observer = request.observe { [weak self] in
                        Task { @MainActor [weak self] in self?.pump() }
                    }
                    waiters.append(waiter)
                    pump()
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.cancel(id) }
            }
            try Task.checkCancellation()
            return lease
        } catch {
            // Cancellation can race continuation resumption. Releasing is
            // idempotent and ensures a granted-but-unreturned lease is freed.
            cancel(id)
            throw error
        }
    }

    func release(_ lease: UUID) {
        guard active.removeValue(forKey: lease) != nil else { return }
        pump()
    }

    private func cancel(_ id: UUID) {
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            let waiter = waiters.remove(at: index)
            if let observer = waiter.observer { waiter.demand.removeObserver(observer) }
            waiter.continuation.resume(throwing: CancellationError())
        }
        // The ID is also the lease ID, covering cancellation between grant and
        // return from acquire. A caller that already received it owns release.
        if active.removeValue(forKey: id) != nil { pump() }
        if waiters.isEmpty { timer?.cancel(); timer = nil }
    }

    private func pump() {
        guard !waiters.isEmpty else { timer?.cancel(); timer = nil; return }
        while active.count < limit {
            let ordered = waiters.sorted {
                if $0.demand.priority.rawValue != $1.demand.priority.rawValue {
                    return $0.demand.priority.rawValue < $1.demand.priority.rawValue
                }
                return $0.order < $1.order
            }
            let foregroundLeaseActive = activeForegroundCount > 0
            let backgroundActive = activeBackgroundCount
            let canStartBackground = limit == 1 || foregroundLeaseActive || backgroundActive < limit - 1

            var selected: Waiter?
            var pacedWait: TimeInterval?
            let now = ProcessInfo.processInfo.systemUptime
            for waiter in ordered {
                let isForeground = waiter.demand.priority == .foreground
                if !isForeground && !canStartBackground { continue }
                let delay = remainingDelay(effectivePacing(waiter.pacing, for: waiter.demand), now: now)
                if delay > 0 {
                    pacedWait = min(pacedWait ?? delay, delay)
                    continue
                }
                selected = waiter
                break
            }
            guard let waiter = selected else {
                schedulePump(after: pacedWait)
                return
            }
            if let index = waiters.firstIndex(where: { $0.id == waiter.id }) {
                waiters.remove(at: index)
            } else { continue }
            if let observer = waiter.observer { waiter.demand.removeObserver(observer) }
            active[waiter.id] = Active(demand: waiter.demand)
            if let pacing = effectivePacing(waiter.pacing, for: waiter.demand) { lastStarts[pacing] = ProcessInfo.processInfo.systemUptime }
            waiter.continuation.resume(returning: waiter.id)
        }
    }

    private var activeForegroundCount: Int { active.values.filter { $0.demand.priority == .foreground }.count }
    private var activeBackgroundCount: Int { active.count - activeForegroundCount }

    private func canGrantImmediately(request: MediaRequestDemand, pacing: Pacing?) -> Bool {
        guard active.count < limit else { return false }
        let foreground = request.priority == .foreground
        if foreground {
            guard !waiters.contains(where: { $0.demand.priority == .foreground }) else { return false }
        } else {
            guard limit == 1 || activeForegroundCount > 0 || activeBackgroundCount < limit - 1 else { return false }
        }
        return remainingDelay(pacing, now: ProcessInfo.processInfo.systemUptime) <= 0
    }

    private func remainingDelay(_ pacing: Pacing?, now: TimeInterval) -> TimeInterval {
        guard let pacing, let last = lastStarts[pacing] else { return 0 }
        let interval: TimeInterval = switch pacing {
        case .search: searchInterval
        case .metadata: 1.3
        case .download: 0.75
        }
        return interval - (now - last)
    }

    private func effectivePacing(_ pacing: Pacing?, for demand: MediaRequestDemand) -> Pacing? {
        // A reader joining an offline page request can promote it immediately.
        pacing == .download && demand.priority != .download ? nil : pacing
    }

    private func schedulePump(after delay: TimeInterval?) {
        timer?.cancel()
        timer = nil
        guard let delay, delay.isFinite, delay > 0 else { return }
        timer = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }
            guard !Task.isCancelled, let self else { return }
            self.timer = nil
            self.pump()
        }
    }
}
