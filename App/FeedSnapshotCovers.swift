import Foundation
import ExViewerCore

/// A replacement launch snapshot must not outrun its first screen's cover files.
/// This is background work: visible covers still use the shared higher priority.
enum FeedSnapshotCovers {
    static let count = 12
    typealias Loader = @Sendable (URL) async throws -> Void

    static func prepare(_ galleries: [Gallery], timeout: Duration = .seconds(8),
                        load: @escaping Loader) async -> Bool {
        let first = Array(galleries.prefix(count))
        let urls = first.compactMap(\.cover)
        guard urls.count == first.count else { return false }
        var seen = Set<URL>()
        let unique = urls.filter { seen.insert($0).inserted }
        guard !unique.isEmpty else { return true }
        return await withTaskGroup(of: Bool.self) { race in
            race.addTask {
                await withTaskGroup(of: Bool.self) { group in
                    var next = 0
                    let concurrency = min(unique.count, max(1, MediaTransferClient.coverCapacity - 1))
                    for _ in 0..<concurrency {
                        let url = unique[next]; next += 1
                        group.addTask { do { try await load(url); return !Task.isCancelled } catch { return false } }
                    }
                    while let ready = await group.next() {
                        guard ready, !Task.isCancelled else { group.cancelAll(); return false }
                        if next < unique.count {
                            let url = unique[next]; next += 1
                            group.addTask { do { try await load(url); return !Task.isCancelled } catch { return false } }
                        }
                    }
                    return !Task.isCancelled
                }
            }
            race.addTask {
                do { try await Task.sleep(for: timeout) } catch { }
                return false
            }
            let ready = await race.next() ?? false
            race.cancelAll()
            return ready && !Task.isCancelled
        }
    }
}
