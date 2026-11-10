import Foundation
import ExViewerCore

struct GalleryOfflineUpdate: Equatable {
    let old: GalleryRef
    let target: GalleryRef
    let owner: String
    let generation: UUID
}

enum DownloadLoadPolicy {
    static let concurrencyKey = "download.pageConcurrency"
    static let defaultConcurrency = 2
    static let concurrencyRange = 1...32

    static func configuredConcurrency(defaults: UserDefaults) -> Int {
        let value = defaults.integer(forKey: concurrencyKey)
        return concurrencyRange.contains(value) ? value : defaultConcurrency
    }
}

@MainActor final class DownloadManager: ObservableObject {
    @Published private var activeRun: Run?
    var running: String? { activeRun?.galleryID }
    private var task: Task<Void, Never>?
    private var settling: Task<Void, Never>?
    private var isInBackground = false
    private let session: SiteSession
    private let library: LibraryStore
    private let repository: MediaRepository
    private let preferences: UserDefaults
    private let backgroundWork: (any DownloadBackgroundWork)?

    private struct Run: Sendable {
        let id = UUID()
        let galleryID: String
        let owner: String
        let generation: UUID
    }

    private struct SavedPage: Sendable {
        let index: Int
        let filename: String
    }

    init(session: SiteSession, library: LibraryStore, repository: MediaRepository = .shared,
         preferences: UserDefaults = ReaderPreferenceDefaults.store, backgroundWork: (any DownloadBackgroundWork)? = nil) {
        self.session = session
        self.library = library
        self.repository = repository
        self.preferences = preferences
        self.backgroundWork = backgroundWork
    }
    @discardableResult func enqueue(_ gallery: Gallery, replacing old: GalleryRef? = nil) -> Bool {
        guard library.error == nil, library.owner == session.owner else { return false }
        if let stored = library.snapshot.downloads.first(where: { $0.id == gallery.id }),
           stored.gallery.ref != gallery.ref { return false }
        let record = library.download(for: gallery.ref)
        guard record?.status != .complete, running != gallery.id else { return false }
        if let old {
            guard old.site == gallery.ref.site, old.gid < gallery.ref.gid,
                  library.download(for: old)?.status == .complete else { return false }
        }
        library.updateDownload(.init(gallery: gallery.stored, status: .waiting,
                                     completed: record?.completed ?? [:], total: record?.total ?? gallery.pages,
                                     replaces: old ?? record?.replaces))
        guard library.error == nil else { return false }
        if running == nil { startNext() }
        if running == gallery.id { requestBackgroundContinuation() }
        return true
    }

    func enqueueNew(_ galleries: [Gallery]) -> Int? {
        guard library.owner == session.owner, let count = library.addDownloadJobs(galleries) else { return nil }
        if count > 0 {
            startNext()
            requestBackgroundContinuation()
        }
        return count
    }

    private func requestBackgroundContinuation() {
        if !isInBackground, let run = activeRun, isCurrent(run) {
            backgroundWork?.requestContinuation { [weak self] in
                self?.backgroundTimeExpired(for: run)
            }
        }
    }

    @discardableResult func enqueueUpdate(_ plan: GalleryOfflineUpdate, from gallery: Gallery) -> Bool {
        guard session.generation == plan.generation, library.owner == plan.owner, session.owner == plan.owner else { return false }
        var target = gallery
        if target.ref != plan.target {
            target.ref = plan.target
            target.pages = nil
        }
        return enqueue(target, replacing: plan.old)
    }
    func pause(_ id: String) {
        if running == id {
            pauseAll()
            startNext()
        } else if var record = library.snapshot.downloads.first(where: { $0.id == id && $0.status == .waiting }) {
            record.status = .paused
            library.updateDownload(record)
        }
    }
    func pauseAll() { stopActive(as: .paused) }
    func suspendForBackground() {
        isInBackground = true
        if let run = activeRun, backgroundWork?.canContinue != true { backgroundTimeExpired(for: run) }
    }
    func resumeQueuedDownloads() {
        isInBackground = false
        if let run = activeRun, isCurrent(run) { beginShortBackgroundTime(for: run) }
        else { startNext() }
    }

    private func beginShortBackgroundTime(for run: Run) {
        backgroundWork?.beginShort("离线下载") { [weak self] in
            self?.backgroundTimeExpired(for: run)
        }
    }

    private func backgroundTimeExpired(for run: Run) {
        guard isCurrent(run) else { return }
        if isInBackground { stopActive(as: .waiting) }
        else { beginShortBackgroundTime(for: run) }
    }

    private func stopActive(as status: DownloadRecord.Status) {
        let stoppedRun = activeRun
        activeRun = nil
        if let task {
            task.cancel()
            let previous = settling
            settling = Task { await previous?.value; await task.value }
        }
        task = nil
        if let stoppedRun, stoppedRun.owner == library.owner,
           var record = library.snapshot.downloads.first(where: { $0.id == stoppedRun.galleryID }) {
            record.status = status
            library.updateDownload(record)
        }
        backgroundWork?.finish(success: false)
    }
    func remove(_ ids: Set<String>) async -> Bool {
        let owner = library.owner, generation = session.generation
        let stoppedActive = running.map(ids.contains) == true
        if stoppedActive { pauseAll() }
        await settling?.value
        guard owner == library.owner, generation == session.generation,
              running.map(ids.contains) != true else { return false }
        let removed = library.removeDownloads(ids)
        if stoppedActive, removed { startNext() }
        return removed
    }
    private func startNext() {
        if AppMode.qa && ProcessInfo.processInfo.arguments.contains("--qa-download-actions") { return }
        guard !isInBackground, library.error == nil, running == nil, library.owner == session.owner,
              let record = library.snapshot.downloads.first(where: { $0.status == .waiting }) else { return }
        let run = Run(galleryID: record.id, owner: library.owner, generation: session.generation)
        activeRun = run
        beginShortBackgroundTime(for: run)
        backgroundWork?.report(completed: record.completed.count, total: record.total)
        let directory = library.offlineDirectory(record.gallery)
        let previous = settling
        task = Task {
            await previous?.value
            await download(record, to: directory, run: run)
        }
    }

    private func isCurrent(_ run: Run) -> Bool {
        activeRun?.id == run.id && run.owner == library.owner && run.owner == session.owner && run.generation == session.generation
    }

    private func checkCurrent(_ run: Run) throws {
        try Task.checkCancellation()
        guard isCurrent(run) else { throw ViewerError.stale }
    }

    private func download(_ record: DownloadRecord, to directory: URL, run: Run) async {
        var current = record
        var failedImageOnly = false
        do {
            try checkCurrent(run)
            settling = nil
            current.status = .downloading
            current.error = nil
            library.updateDownload(current)
            guard library.error == nil else { throw ViewerError.storage }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var cursor: URL? = record.gallery.ref.url
            var seen = Set<URL>()
            var verifiedPages = Set<Int>()
            var pagesSinceCheckpoint = 0
            let reuse = record.replaces.flatMap { library.download(for: $0) }.flatMap { old in
                old.status == .complete ? OfflinePageReuse(files: library.downloadedPages(old).map(\.url)) : nil
            }
            while let url = cursor {
                try checkCurrent(run)
                guard seen.insert(url).inserted, seen.count <= 100 else { throw ViewerError.layoutChanged }
                let html = try await session.html(url, request: MediaRequestDemand(priority: .download))
                try checkCurrent(run)
                let detail = try EHParser.detail(html, reference: record.gallery.ref, pageURL: url)
                current.total = detail.gallery.pages ?? current.total
                if record.replaces != nil {
                    current.gallery = detail.gallery.stored
                } else if !current.gallery.tagsComplete, detail.gallery.tagsComplete, !detail.gallery.tags.isEmpty {
                    let knownIDs = Set(current.gallery.tags.map(\.id))
                    current.gallery.tags += detail.gallery.tags.filter { !knownIDs.contains($0.id) }
                    current.gallery.tagsComplete = true
                }
                backgroundWork?.report(completed: current.completed.count, total: current.total)
                try await savePages(detail.pages, to: directory, run: run, reuse: reuse) { saved in
                    verifiedPages.insert(saved.index)
                    guard current.completed[saved.index] != saved.filename else { return }
                    current.completed[saved.index] = saved.filename
                    pagesSinceCheckpoint += 1
                    let checkpoint = pagesSinceCheckpoint == 8
                    library.updateDownload(current, checkpoint: checkpoint)
                    if library.error != nil { throw ViewerError.storage }
                    backgroundWork?.report(completed: current.completed.count, total: current.total)
                    if checkpoint { pagesSinceCheckpoint = 0 }
                }
                cursor = detail.next
            }
            guard let total = current.total, total > 0, verifiedPages.count == total, current.completed.count == total,
                  current.completed.keys.allSatisfy({ (1...total).contains($0) }) else { throw ViewerError.layoutChanged }
            current.status = .complete
        } catch is CancellationError {
            current.status = .paused
        } catch {
            current.status = .failed
            switch error as? RequestFailure {
            case .http(.media, 404), .http(.media, 410): failedImageOnly = true
            default: failedImageOnly = (error as? ViewerError) == .unsupported
            }
            let fileError = (error as NSError).domain == NSCocoaErrorDomain || (error as NSError).domain == NSPOSIXErrorDomain
            current.error = ErrorMessages.message(error, fallback: (fileError ? ViewerError.storage : ViewerError.network).localizedDescription)
        }
        guard activeRun?.id == run.id else { return }
        let canCommit = isCurrent(run)
        activeRun = nil
        task = nil
        if canCommit {
            library.updateDownload(current)
        } else if library.owner == run.owner {
            // Session cancellation may finish before the app switches libraries.
            current.status = .paused
            current.error = nil
            library.updateDownload(current)
        }
        let success = canCommit && current.status == .complete && library.error == nil
        if success, current.replaces != nil { library.retireReplacedDownloads() }
        backgroundWork?.finish(success: success)
        if success || (canCommit && failedImageOnly) { startNext() }
    }

    private func savePages(_ pages: [GalleryPage], to directory: URL, run: Run, reuse: OfflinePageReuse?,
                           onSave: (SavedPage) throws -> Void) async throws {
        try await withThrowingTaskGroup(of: SavedPage.self) { group in
            var remaining = pages.makeIterator()
            var inFlight = 0
            func submitAvailable() {
                let limit = DownloadLoadPolicy.configuredConcurrency(defaults: preferences)
                while inFlight < limit, let page = remaining.next() {
                    inFlight += 1
                    group.addTask(priority: .utility) { try await self.savePage(page, to: directory, run: run, reuse: reuse) }
                }
            }
            submitAvailable()
            while let saved = try await group.next() {
                try checkCurrent(run)
                inFlight -= 1
                try onSave(saved)
                submitAvailable()
            }
        }
    }

    private func savePage(_ page: GalleryPage, to directory: URL, run: Run, reuse: OfflinePageReuse?) async throws -> SavedPage {
        try checkCurrent(run)
        let filename = "page-\(page.index).media"
        let destination = directory.appendingPathComponent(filename)
        let scope = session.pageReadScope
        guard scope.owner == run.owner else { throw ViewerError.stale }
        // The local copy also covers files that finished after the last checkpoint.
        if try await repository.copyCachedPage(page.url, scope: scope, destination: destination) {
            return SavedPage(index: page.index, filename: filename)
        }
        let demand = MediaRequestDemand(priority: .download)
        _ = try await PageMediaLoader.file(resolvePage: {
            try await session.imageSource(page.url, request: demand, recoverConnection: false)
        }, loadMedia: { url in
            if let source = try await reuse?.file(for: url) {
                try checkCurrent(run)
                if try await repository.copyOfflinePage(source, to: destination) { return destination }
            }
            return try await repository.saveManual(url: url, owner: run.owner, destination: destination,
                                                   allowNetwork: session.quota.remaining != 0, request: demand)
        }, isCurrent: { isCurrent(run) })
        return SavedPage(index: page.index, filename: filename)
    }
}
