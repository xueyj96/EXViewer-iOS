import Foundation
import ExViewerCore

/// Saved galleries deliberately omit transient media URLs. Resolve only covers
/// requested by the feed, sharing a small serial metadata queue.
@MainActor final class StoredCoverResolver {
    static let shared = StoredCoverResolver()
    typealias Fetch = @MainActor ([Gallery]) async throws -> [Gallery]

    enum Failure: LocalizedError {
        case missing, queueFull
        var errorDescription: String? {
            switch self {
            case .missing: return "未能取得封面，请重试。"
            case .queueFull: return "封面正在排队，请稍后重试。"
            }
        }
    }
    private struct Pending {
        var gallery: Gallery
        var waiters: [UUID: CheckedContinuation<URL, Error>]
    }
    private let cacheLimit: Int
    private let batchDelay: UInt64
    private var context: String?
    private var cache: [GalleryRef: URL] = [:]
    private var cacheOrder: [GalleryRef] = []
    private var pending: [GalleryRef: Pending] = [:]
    private var queue: [GalleryRef] = []
    private var worker: Task<Void, Never>?
    private var workerID = UUID()

    init(cacheLimit: Int = 256, batchDelay: UInt64 = 50_000_000) {
        self.cacheLimit = max(1, cacheLimit); self.batchDelay = batchDelay
    }

    func source(for gallery: Gallery, context: String, fetch: @escaping Fetch) async throws -> URL {
        try Task.checkCancellation()
        if self.context != context { reset(context) }
        let key = gallery.ref
        if let cached = cache[key] { return cached }
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                if pending[key] != nil {
                    pending[key]?.waiters[waiter] = continuation
                } else {
                    guard pending.count < 64 else { continuation.resume(throwing: Failure.queueFull); return }
                    pending[key] = Pending(gallery: gallery, waiters: [waiter: continuation]); queue.append(key)
                }
                if worker == nil {
                    let id = UUID(); workerID = id
                    worker = Task { await self.run(context: context, id: id, fetch: fetch) }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(key, waiter: waiter, context: context) }
        }
    }

    func invalidate(_ ref: GalleryRef, context: String) {
        guard self.context == context else { return }
        cache[ref] = nil; cacheOrder.removeAll { $0 == ref }
    }

    private func reset(_ context: String) {
        worker?.cancel(); worker = nil; workerID = UUID()
        for item in pending.values { for waiter in item.waiters.values { waiter.resume(throwing: CancellationError()) } }
        pending = [:]; queue = []; cache = [:]; cacheOrder = []
        self.context = context
    }

    private func cancel(_ key: GalleryRef, waiter: UUID, context: String) {
        guard self.context == context else { return }
        pending[key]?.waiters.removeValue(forKey: waiter)?.resume(throwing: CancellationError())
        if pending[key]?.waiters.isEmpty == true { pending[key] = nil; queue.removeAll { $0 == key } }
        if pending.isEmpty { worker?.cancel(); worker = nil; workerID = UUID() }
    }

    private func finish(_ key: GalleryRef, result: Result<URL, Error>) {
        guard let item = pending.removeValue(forKey: key) else { return }
        for waiter in item.waiters.values { waiter.resume(with: result) }
    }

    private func run(context: String, id: UUID, fetch: @escaping Fetch) async {
        defer { if workerID == id { worker = nil } }
        while self.context == context && workerID == id && !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: batchDelay)
                try Task.checkCancellation()
                guard self.context == context, workerID == id else { return }
                let keys = Array(queue.filter { pending[$0] != nil }.prefix(25))
                guard !keys.isEmpty else { return }
                let batch = keys.compactMap { pending[$0]?.gallery }
                queue.removeAll { keys.contains($0) }
                let galleries = try await fetch(batch)
                try Task.checkCancellation()
                guard self.context == context, workerID == id else { return }
                for key in keys {
                    guard pending[key] != nil else { continue }
                    if let url = galleries.first(where: { $0.ref == key })?.cover {
                        cache[key] = url; cacheOrder.removeAll { $0 == key }; cacheOrder.append(key)
                        while cacheOrder.count > cacheLimit { cache[cacheOrder.removeFirst()] = nil }
                        finish(key, result: .success(url))
                    } else { finish(key, result: .failure(Failure.missing)) }
                }
                if pending.isEmpty { return }
            } catch {
                guard self.context == context, workerID == id else { return }
                // Stop this queue on transport/verification failures. Visible
                // covers expose explicit retry instead of a request storm.
                for key in Array(pending.keys) { finish(key, result: .failure(error)) }
                queue = []; return
            }
        }
    }
}
