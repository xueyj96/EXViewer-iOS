import Foundation
import CryptoKit
import ExViewerCore

/// The sidecar is valid only for the exact durable v1 library it supplements.
/// A later critical library commit therefore invalidates even a late old write.
struct LibraryHistoryJournal: Codable, Sendable {
    var version = 1
    let libraryBasis: String
    let history: [ReadingRecord]

    static func basis(for data: Data?) -> String {
        guard let data else { return "missing" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func restore(from file: URL, libraryBasis: String) throws -> [ReadingRecord]? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size < 12_000_000 else { throw ViewerError.storage }
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
        guard value.version == 1, value.history.count <= 500,
              Set(value.history.map(\.id)).count == value.history.count,
              value.history.allSatisfy({ $0.page > 0 }) else { throw ViewerError.storage }
        // A valid stale sidecar is not corruption. Keep it untouched, but never
        // revive its records after deletion, reset, or a newer metadata commit.
        guard value.libraryBasis == libraryBasis else { return nil }
        return value.history
    }
}

struct LibraryHistoryWrite: Sendable {
    let owner: String
    let scope: UUID
    let revision: UInt64
    let libraryBasis: String
    let file: URL
    let history: [ReadingRecord]
}

/// One LibraryStore owns one writer. Jobs never touch library.json; critical
/// synchronous library transactions retain their existing durable-success API.
actor LibraryHistoryWriter {
    typealias WriteData = @Sendable (Data, URL) throws -> Void
    private var latestAttempt: [URL: UInt64] = [:]
    private let writeData: WriteData

    init(writeData: @escaping WriteData = { data, file in
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }) { self.writeData = writeData }

    /// There is no suspension between the ordering check and atomic write.
    /// A delayed older task cannot overwrite a newer accepted checkpoint.
    func write(_ job: LibraryHistoryWrite) throws {
        guard job.revision >= (latestAttempt[job.file] ?? 0) else { return }
        latestAttempt[job.file] = job.revision
        // Preserve an unreadable/unknown sidecar even if it changed after the
        // account was loaded. All validation remains on this storage actor.
        _ = try LibraryHistoryJournal.restore(from: job.file, libraryBasis: job.libraryBasis)
        let data = try JSONEncoder().encode(LibraryHistoryJournal(libraryBasis: job.libraryBasis, history: job.history))
        guard data.count < 12_000_000 else { throw ViewerError.storage }
        try writeData(data, job.file)
    }
}
