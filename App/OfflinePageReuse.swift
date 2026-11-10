import CryptoKit
import Foundation
import ExViewerCore

/// H@H file identifiers contain the digest and byte size of the served image.
/// Other sources and gallery page tokens do not enter the reuse index.
struct OfflineImageFingerprint: Hashable, Sendable {
    let digest: String
    let bytes: Int64

    init?(source: URL) {
        let path = source.pathComponents
        guard URLPolicy.media(source), source.host?.lowercased().hasSuffix(".hath.network") == true,
              path.count == 5, path[1] == "h" else { return nil }
        let fileID = path[2]
        let pattern = #"^[a-f0-9]{40}-[0-9]{1,10}(?:-[0-9]{1,5}-[0-9]{1,5})?-(?:jpg|png|gif|wbp|avf|jxl)$"#
        guard fileID.range(of: pattern, options: .regularExpression) != nil else { return nil }
        let fields = fileID.split(separator: "-")
        guard let bytes = Int64(fields[1]), bytes > 0 else { return nil }
        self.bytes = bytes
        digest = String(fields[0])
    }

    init(file: URL) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var sha = Insecure.SHA1()
        var bytes: Int64 = 0
        while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            sha.update(data: chunk)
            bytes += Int64(chunk.count)
        }
        self.bytes = bytes
        digest = sha.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

actor OfflinePageReuse {
    private var unindexed: [URL]?
    private var candidates: [Int64: [URL]] = [:]
    private var matches: [OfflineImageFingerprint: URL] = [:]

    init(files: [URL]) { unindexed = files }

    func file(for source: URL) throws -> URL? {
        guard let fingerprint = OfflineImageFingerprint(source: source) else { return nil }
        if let unindexed {
            for file in unindexed {
                try Task.checkCancellation()
                guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize else { continue }
                candidates[Int64(size), default: []].append(file)
            }
            self.unindexed = nil
        }
        for file in candidates.removeValue(forKey: fingerprint.bytes) ?? [] {
            try Task.checkCancellation()
            if let key = try? OfflineImageFingerprint(file: file) { matches[key] = file }
        }
        try Task.checkCancellation()
        return matches[fingerprint]
    }
}
