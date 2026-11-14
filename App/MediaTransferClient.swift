import Foundation

/// Owns one reusable, private media session. Individual transfers supply their
/// own task delegate so concurrent downloads keep independent response state.
final class MediaTransferClient: @unchecked Sendable {
    // Four cover transfers are isolated from the existing download/reader budget.
    // Lookahead uses at most three; a newly visible cover can start immediately.
    static let coverCapacity = 4
    static let maxConnections = max(ReaderLoadPolicy.maxConcurrency, DownloadLoadPolicy.concurrencyRange.upperBound + 1) + coverCapacity
    static let shared = MediaTransferClient()

    private let session: URLSession

    init(configuration suppliedConfiguration: URLSessionConfiguration? = nil) {
        let configuration = suppliedConfiguration?.copy() as? URLSessionConfiguration ?? .ephemeral
        configuration.httpMaximumConnectionsPerHost = Self.maxConnections
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: nil, delegateQueue: queue)
    }

    func dataTask(with request: URLRequest, delegate: URLSessionDataDelegate) -> URLSessionDataTask {
        let task = session.dataTask(with: request)
        task.delegate = delegate
        return task
    }

    deinit {
        session.invalidateAndCancel()
    }
}
