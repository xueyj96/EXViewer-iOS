import Combine
import Foundation
import ExViewerCore

@MainActor
final class FavoriteBatchSubmission: ObservableObject {
    enum Interruption {
        case notSent(Error)
        case needsVerification(Error)
    }

    enum State {
        case idle
        case submitting(total: Int)
        case refreshingList(submitted: Int)
        case listRefreshed
        case listRefreshFailed
        case interrupted(submitted: Int, batchCount: Int, reason: Interruption)
        case preview
    }

    @Published private(set) var state: State = .idle
    private var task: Task<Void, Never>?
    private var revision = UUID()

    var workingCount: Int? {
        if case .submitting(let total) = state { return total }
        return nil
    }

    func start(_ references: [GalleryRef],
               isCurrent: @escaping () -> Bool,
               invalidateCache: @escaping () async -> Void,
               submit: @escaping ([GalleryRef]) async throws -> Void,
               onSubmitted: @escaping ([GalleryRef]) -> Void,
               onComplete: @escaping () -> Void) {
        guard !references.isEmpty, workingCount == nil, isCurrent() else { return }
        let operation = UUID()
        revision = operation
        state = .submitting(total: references.count)
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if revision == operation {
                    task = nil
                    if workingCount != nil { state = .idle }
                }
            }
            @MainActor func active() -> Bool { revision == operation && !Task.isCancelled && isCurrent() }
            guard active() else { return }
            // A lost response can still mean a server-side write.
            await invalidateCache()
            let limit = FavoritesBatchRequest.maxItemCount
            var submitted = 0
            for offset in stride(from: 0, to: references.count, by: limit) {
                guard active() else { return }
                let batch = Array(references[offset..<min(offset + limit, references.count)])
                do {
                    try await submit(batch)
                } catch is CancellationError {
                    return
                } catch {
                    guard active() else { return }
                    let reason: Interruption
                    if let failure = error as? FavoriteMutationFailure {
                        reason = failure.requestMayHaveBeenSent ? .needsVerification(failure.underlying) : .notSent(failure.underlying)
                    } else {
                        reason = .notSent(error)
                    }
                    state = .interrupted(submitted: submitted, batchCount: batch.count, reason: reason)
                    return
                }
                guard active() else { return }
                submitted += batch.count
                onSubmitted(batch)
            }
            guard active() else { return }
            state = .refreshingList(submitted: submitted)
            onComplete()
        }
    }

    func finishListRefresh(succeeded: Bool) {
        guard case .refreshingList = state else { return }
        state = succeeded ? .listRefreshed : .listRefreshFailed
    }

    func showPreview() { state = .preview }

    func dismissNotice() {
        if workingCount == nil { state = .idle }
    }

    func cancel() {
        revision = UUID()
        task?.cancel()
        task = nil
        if workingCount != nil { state = .idle }
    }
}
