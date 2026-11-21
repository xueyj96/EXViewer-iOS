import Foundation

/// Consumer-side byte-progress coalescing, before crossing to MainActor.
/// `lock` protects every mutable field. Timers use a single shared non-main queue;
/// callbacks are always invoked after unlocking. A cancelled timer is also fenced
/// by its epoch. Already-emitted callbacks are fenced by the reader request token
/// and `Delivery.sequence` when they reach MainActor. This is the complete safety
/// invariant for unchecked Sendable; no UIKit/UI-owned state enters this object.
final class ReaderProgressThrottle: @unchecked Sendable {
    struct Delivery: Sendable {
        let sequence: UInt64
        let snapshot: MediaRequestDemand.ProgressSnapshot
    }
    private static let queue = DispatchQueue(label: "ExViewer.reader.progress", qos: .userInitiated)
    private let lock = NSLock()
    private let interval: TimeInterval
    private let deliver: @Sendable (Delivery) -> Void
    private var cancelled = false
    private var terminal = false
    private var lastSequences: [UUID: UInt64] = [:]
    private var lastPhase: MediaLoadPhase?
    private var lastDeliveryTime: TimeInterval?
    private var nextDelivery: UInt64 = 0
    private var pending: MediaRequestDemand.ProgressSnapshot?
    private var timer: DispatchWorkItem?
    private var timerEpoch = UUID()

    init(interval: TimeInterval = 0.1, deliver: @escaping @Sendable (Delivery) -> Void) {
        self.interval = max(0.001, interval)
        self.deliver = deliver
    }

    /// Fetch under this consumer's lock so callbacks which race outside the
    /// producer lock cannot feed an older captured producer binding back in.
    func receiveLatest(from demand: MediaRequestDemand) {
        lock.lock()
        let delivery = receiveLocked(demand.progressSnapshot)
        lock.unlock()
        if let delivery { deliver(delivery) }
    }

    /// Explicit snapshots are useful for deterministic sequence/binding tests.
    func receive(_ snapshot: MediaRequestDemand.ProgressSnapshot) {
        lock.lock()
        let delivery = receiveLocked(snapshot)
        lock.unlock()
        if let delivery { deliver(delivery) }
    }

    private func receiveLocked(_ snapshot: MediaRequestDemand.ProgressSnapshot) -> Delivery? {
        guard !cancelled, !terminal,
              lastSequences[snapshot.producerUUID].map({ snapshot.sequence > $0 }) ?? true else { return nil }
        lastSequences[snapshot.producerUUID] = snapshot.sequence
        let now = ProcessInfo.processInfo.systemUptime
        if snapshot.value.phase != lastPhase || lastDeliveryTime == nil ||
            now - (lastDeliveryTime ?? now) >= interval || snapshot.value.phase == .ready {
            clearTimerLocked()
            if snapshot.value.phase == .ready { terminal = true }
            return makeDeliveryLocked(snapshot, now: now)
        }
        pending = snapshot
        if timer == nil {
            let epoch = UUID(); timerEpoch = epoch
            let work = DispatchWorkItem { [weak self] in self?.flush(epoch: epoch) }
            timer = work
            Self.queue.asyncAfter(deadline: .now() + max(0, interval - (now - (lastDeliveryTime ?? now))), execute: work)
        }
        return nil
    }

    private func makeDeliveryLocked(_ snapshot: MediaRequestDemand.ProgressSnapshot, now: TimeInterval) -> Delivery {
        lastPhase = snapshot.value.phase; lastDeliveryTime = now
        nextDelivery &+= 1
        return Delivery(sequence: nextDelivery, snapshot: snapshot)
    }

    private func flush(epoch: UUID) {
        lock.lock()
        guard !cancelled, !terminal, timerEpoch == epoch, let snapshot = pending else { lock.unlock(); return }
        timer = nil; pending = nil
        let delivery = makeDeliveryLocked(snapshot, now: ProcessInfo.processInfo.systemUptime)
        lock.unlock()
        deliver(delivery)
    }

    private func clearTimerLocked() {
        timerEpoch = UUID(); timer?.cancel(); timer = nil; pending = nil
    }

    func cancel() {
        lock.lock(); cancelled = true; clearTimerLocked(); lock.unlock()
    }

    deinit { timer?.cancel() }
}
