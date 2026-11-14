import BackgroundTasks
import UIKit

enum DownloadBackgroundCompletion: Equatable {
    case completed, paused, waiting, foregroundOnly, failed

    var systemSuccess: Bool { self != .failed }
    var title: String {
        switch self {
        case .completed: "下载完成"
        case .paused: "下载暂停"
        case .waiting: "等待继续"
        case .foregroundOnly: "前台下载"
        case .failed: "下载失败"
        }
    }
}

struct DownloadBackgroundEnd: Equatable {
    let completion: DownloadBackgroundCompletion
    let completed: Int
    let total: Int?

    var subtitle: String {
        let saved = total.map { "已保存 \(completed)/\($0) 页" } ?? "已保存 \(completed) 页"
        return switch completion {
        case .completed: saved
        case .paused: saved + " 可继续下载"
        case .waiting: saved + " 返回 App 继续"
        case .foregroundOnly: saved + " 仅在前台继续"
        case .failed: saved + " 可重试"
        }
    }
}

/// Captured by this request's launch handler, even if cancellation wins the
/// race with delivery. A late handler must report the original ending once.
@MainActor final class DownloadBackgroundRequestState {
    let identifier: String
    private(set) var end: DownloadBackgroundEnd?
    init(identifier: String) { self.identifier = identifier }
    func finish(_ completion: DownloadBackgroundCompletion, completed: Int, total: Int?) {
        guard end == nil else { return }
        end = .init(completion: completion, completed: completed, total: total)
    }
}

@MainActor protocol DownloadBackgroundWork {
    var canContinue: Bool { get }
    func beginShort(_ name: String, expired: @escaping @MainActor () -> Void)
    func requestContinuation(stopped: @escaping @MainActor () -> Void)
    func report(completed: Int, total: Int?)
    func finish(_ completion: DownloadBackgroundCompletion)
}

@MainActor final class BackgroundWork: DownloadBackgroundWork {
    private var shortTask = UIBackgroundTaskIdentifier.invalid
    private var shortRevision: UUID?
    private var requestState: DownloadBackgroundRequestState?
    private var continued: BGTask?
    private var pageProgress: (completed: Int, total: Int?) = (0, nil)

    var canContinue: Bool { continued != nil || shortTask != .invalid }

    func beginShort(_ name: String, expired: @escaping @MainActor () -> Void) {
        guard !canContinue else { return }
        let revision = UUID()
        shortRevision = revision
        shortTask = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            guard let self, self.shortRevision == revision else { return }
            let id = self.takeShort()
            expired()
            if id != .invalid { UIApplication.shared.endBackgroundTask(id) }
        }
    }

    func requestContinuation(stopped: @escaping @MainActor () -> Void) {
        guard #available(iOS 26.0, *), requestState == nil, let bundle = Bundle.main.bundleIdentifier else { return }
        let state = DownloadBackgroundRequestState(identifier: "\(bundle).offline-download.\(UUID().uuidString)")
        let scheduler = BGTaskScheduler.shared
        let registered = scheduler.register(forTaskWithIdentifier: state.identifier, using: .main) { [weak self, state] task in
            Task { @MainActor in
                guard let operation = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                if let end = state.end {
                    Self.complete(operation, with: end)
                    return
                }
                guard let self, self.requestState === state else {
                    Self.complete(operation, with: .init(completion: .paused, completed: 0, total: nil))
                    return
                }
                self.continued = operation
                operation.expirationHandler = { [weak self, weak operation] in
                    Task { @MainActor in
                        guard let self, let operation, self.requestState === state,
                              self.continued === operation else { return }
                        // The manager checkpoints and ends this grant. If it
                        // already ended it, never complete the same task twice.
                        stopped()
                        if self.requestState === state { self.finish(.waiting) }
                    }
                }
                self.endShort()
                self.report(completed: self.pageProgress.completed, total: self.pageProgress.total)
            }
        }
        guard registered else { return }
        requestState = state
        let request = BGContinuedProcessingTaskRequest(identifier: state.identifier, title: "离线下载", subtitle: "正在准备图片")
        request.strategy = .fail
        do { try scheduler.submit(request) }
        catch { requestState = nil }
    }

    func report(completed: Int, total: Int?) {
        pageProgress = (completed, total)
        guard #available(iOS 26.0, *), let operation = continued as? BGContinuedProcessingTask else { return }
        Self.progress(operation, completed: completed, total: total)
        let subtitle = total.map { "已保存 \(completed)/\($0) 页" } ?? "已保存 \(completed) 页"
        operation.updateTitle("离线下载", subtitle: subtitle)
    }

    func finish(_ completion: DownloadBackgroundCompletion) {
        // Preserve the current execution grant until the ending has been frozen and reported.
        defer { endShort() }
        let state = requestState
        state?.finish(completion, completed: pageProgress.completed, total: pageProgress.total)
        requestState = nil
        let end = state?.end ?? .init(completion: completion, completed: pageProgress.completed, total: pageProgress.total)
        pageProgress = (0, nil)
        if let continued {
            self.continued = nil
            continued.expirationHandler = nil
            if #available(iOS 26.0, *), let operation = continued as? BGContinuedProcessingTask {
                Self.complete(operation, with: end)
            } else { continued.setTaskCompleted(success: completion.systemSuccess) }
        } else if let state {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: state.identifier)
        }
    }

    @available(iOS 26.0, *)
    private static func complete(_ operation: BGContinuedProcessingTask, with end: DownloadBackgroundEnd) {
        progress(operation, completed: end.completed, total: end.total)
        operation.updateTitle(end.completion.title, subtitle: end.subtitle)
        // App-originated pauses/checkpoints end this grant successfully, not the download.
        // iOS can still classify a system-expired or cancelled grant as unsuccessful.
        operation.setTaskCompleted(success: end.completion.systemSuccess)
    }

    @available(iOS 26.0, *)
    private static func progress(_ operation: BGContinuedProcessingTask, completed: Int, total: Int?) {
        operation.progress.totalUnitCount = Int64(max(1, total ?? completed + 1))
        operation.progress.completedUnitCount = Int64(completed)
    }

    private func endShort() {
        let id = takeShort()
        if id != .invalid { UIApplication.shared.endBackgroundTask(id) }
    }

    private func takeShort() -> UIBackgroundTaskIdentifier {
        let id = shortTask
        shortTask = .invalid
        shortRevision = nil
        return id
    }
}
