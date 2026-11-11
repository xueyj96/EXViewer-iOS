import BackgroundTasks
import UIKit

@MainActor protocol DownloadBackgroundWork {
    var canContinue: Bool { get }
    func beginShort(_ name: String, expired: @escaping @MainActor () -> Void)
    func requestContinuation(stopped: @escaping @MainActor () -> Void)
    func report(completed: Int, total: Int?)
    func finish(success: Bool)
}

@MainActor final class BackgroundWork: DownloadBackgroundWork {
    private var shortTask = UIBackgroundTaskIdentifier.invalid
    private var shortRevision: UUID?
    private var continuedID: String?
    private var continued: BGTask?
    private var pageProgress: (completed: Int, total: Int?) = (0, nil)

    var canContinue: Bool { continued != nil || shortTask != .invalid }

    func beginShort(_ name: String, expired: @escaping @MainActor () -> Void) {
        guard !canContinue else { return }
        let revision = UUID()
        shortRevision = revision
        shortTask = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            guard let self, self.shortRevision == revision else { return }
            // The foreground download can acquire a new grant before we end the expired one.
            let id = self.takeShort()
            expired()
            if id != .invalid { UIApplication.shared.endBackgroundTask(id) }
        }
    }

    func requestContinuation(stopped: @escaping @MainActor () -> Void) {
        guard #available(iOS 26.0, *), continuedID == nil, let bundle = Bundle.main.bundleIdentifier else { return }
        let id = "\(bundle).offline-download.\(UUID().uuidString)"
        let scheduler = BGTaskScheduler.shared
        let registered = scheduler.register(forTaskWithIdentifier: id, using: .main) { [weak self] task in
            Task { @MainActor in
                guard let self, self.continuedID == id, let operation = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.continued = operation
                operation.expirationHandler = { [weak self] in
                    Task { @MainActor in
                        guard let self, self.continuedID == id, let operation = self.continued else { return }
                        self.continuedID = nil
                        self.continued = nil
                        stopped()
                        operation.setTaskCompleted(success: false)
                    }
                }
                self.endShort()
                self.report(completed: self.pageProgress.completed, total: self.pageProgress.total)
            }
        }
        guard registered else { return }
        continuedID = id
        let request = BGContinuedProcessingTaskRequest(identifier: id, title: "离线下载", subtitle: "正在准备图片")
        request.strategy = .fail
        do { try scheduler.submit(request) }
        catch { continuedID = nil }
    }

    func report(completed: Int, total: Int?) {
        pageProgress = (completed, total)
        guard #available(iOS 26.0, *), let operation = continued as? BGContinuedProcessingTask else { return }
        operation.progress.totalUnitCount = Int64(max(1, total ?? completed + 1))
        operation.progress.completedUnitCount = Int64(completed)
        let subtitle = total.map { "已保存 \(completed)/\($0) 页" } ?? "已保存 \(completed) 页"
        operation.updateTitle("离线下载", subtitle: subtitle)
    }

    func finish(success: Bool) {
        endShort()
        let id = continuedID
        continuedID = nil
        pageProgress = (0, nil)
        if let continued {
            self.continued = nil
            continued.expirationHandler = nil
            continued.setTaskCompleted(success: success)
        } else if let id {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: id)
        }
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
