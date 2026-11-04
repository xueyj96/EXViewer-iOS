import Foundation
import CryptoKit
import SwiftSoup

public struct GalleryTorrent: Identifiable, Sendable {
    public let title: String
    public let downloadURL: URL
    public let infoHash: String
    public let size: String?
    public let seeds: Int?
    public let peers: Int?
    public var id: String { infoHash }
    public init(title: String, downloadURL: URL, infoHash: String, size: String? = nil, seeds: Int? = nil, peers: Int? = nil) {
        self.title = title; self.downloadURL = downloadURL; self.infoHash = infoHash.lowercased()
        self.size = size; self.seeds = seeds; self.peers = peers
    }
    public func magnet(galleryID: Int64) -> String {
        var url = URLComponents(); url.scheme = "magnet"
        url.queryItems = [.init(name: "xt", value: "urn:btih:" + infoHash), .init(name: "dn", value: title),
                          .init(name: "tr", value: "http://ehtracker.org/\(galleryID)/announce")]
        return url.string ?? ""
    }
}

public enum GalleryTorrentParser {
    public static func listURL(_ reference: GalleryRef) throws -> URL {
        guard reference.gid > 0, var value = URLComponents(url: reference.url, resolvingAgainstBaseURL: false) else { throw ViewerError.restricted }
        value.path = "/gallerytorrents.php"
        value.queryItems = [.init(name: "gid", value: String(reference.gid)), .init(name: "t", value: reference.token)]
        value.fragment = nil
        guard let url = value.url, URLPolicy.account(url) else { throw ViewerError.restricted }
        return url
    }

    /// Export only canonical anonymous tracker links, never a personalized
    /// query string from the logged-in listing.
    public static func publicDownloadURL(_ url: URL) -> URL? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.lowercased() == "ehtracker.org",
              url.user == nil, url.password == nil, url.port == nil || [80, 443].contains(url.port!),
              url.path.range(of: #"^/get/[0-9]+/[a-fA-F0-9]{40}\.torrent$"#, options: .regularExpression) != nil,
              var value = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        value.scheme = "https"; value.host = "ehtracker.org"; value.port = nil; value.query = nil; value.fragment = nil
        return value.url
    }

    public static func parse(_ html: String, base: URL) throws -> [GalleryTorrent] {
        try EHParser.check(html)
        let document = try SwiftSoup.parse(html, base.absoluteString)
        var output: [GalleryTorrent] = [], seen = Set<String>()
        for form in try document.select("form") {
            let text = try form.text()
            for link in try form.select("a[href]") {
                guard let candidate = URL(string: try link.attr("href"), relativeTo: base)?.absoluteURL,
                      let url = publicDownloadURL(candidate) else { continue }
                let hash = String(url.deletingPathExtension().lastPathComponent).lowercased()
                let name = try link.text().trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, seen.insert(hash).inserted else { continue }
                func capture(_ pattern: String) -> String? {
                    guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                          let range = Range(match.range(at: 1), in: text) else { return nil }
                    return String(text[range])
                }
                func count(_ label: String) -> Int? { capture(label + #":\s*([0-9,]+)"#).flatMap { Int($0.replacingOccurrences(of: ",", with: "")) } }
                output.append(.init(title: name, downloadURL: url, infoHash: hash,
                                    size: capture(#"Size:\s*([0-9.,]+\s*[KMGT]?i?B)"#), seeds: count("Seeds"), peers: count("Peers")))
            }
        }
        if !output.isEmpty { return output }
        // An unrecognized response is not an empty torrent list.
        let messages = try document.select("body > p, #torrentinfo p").map { try $0.text().trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        if messages.contains(where: { ["no torrents found.", "no torrents found for this gallery.", "there are no torrents for this gallery."].contains($0) }) { return [] }
        throw ViewerError.layoutChanged
    }
}

/// Retain the byte-exact info dictionary and replace all outer metadata with
/// the public gallery tracker. Account-specific tracker queries and web seeds
/// are never written into an exported file.
public enum PublicTorrentFile {
    public static let maximumBytes = 2_000_000
    public static func sanitize(_ data: Data, expectedHash: String, galleryID: Int64) throws -> Data {
        guard galleryID > 0, data.count <= maximumBytes, expectedHash.range(of: #"^[a-fA-F0-9]{40}$"#, options: .regularExpression) != nil else { throw ViewerError.layoutChanged }
        let bytes = Array(data)
        var parser = Bencode(bytes: bytes)
        let fields = try parser.dictionary(depth: 0)
        guard parser.position == bytes.count, let info = fields["info"], bytes[info.lowerBound] == 100 else { throw ViewerError.layoutChanged }
        let original = Data(bytes[info])
        let hash = Insecure.SHA1.hash(data: original).map { String(format: "%02x", $0) }.joined()
        guard hash == expectedHash.lowercased() else { throw ViewerError.layoutChanged }
        var details = Bencode(bytes: bytes, position: info.lowerBound)
        let keys = try details.dictionary(depth: 0)
        guard keys["name"] != nil, keys["piece length"] != nil, keys["pieces"] != nil,
              keys["length"] != nil || keys["files"] != nil else { throw ViewerError.layoutChanged }
        let tracker = "http://ehtracker.org/\(galleryID)/announce"
        var result = Data("d8:announce\(tracker.utf8.count):\(tracker)4:info".utf8)
        result.append(original); result.append(101)
        return result
    }

    private struct Bencode {
        let bytes: [UInt8]
        var position = 0
        var items = 0
        mutating func dictionary(depth: Int) throws -> [String: Range<Int>] {
            guard depth < 32, position < bytes.count, bytes[position] == 100 else { throw ViewerError.layoutChanged }
            position += 1
            var fields: [String: Range<Int>] = [:]
            while position < bytes.count, bytes[position] != 101 {
                let keyBytes = try string()
                guard let key = String(bytes: bytes[keyBytes], encoding: .utf8), fields[key] == nil else { throw ViewerError.layoutChanged }
                let start = position; try value(depth: depth + 1); fields[key] = start..<position
            }
            guard position < bytes.count, bytes[position] == 101 else { throw ViewerError.layoutChanged }
            position += 1; return fields
        }
        mutating func string() throws -> Range<Int> {
            let start = position
            while position < bytes.count, (48...57).contains(bytes[position]) { position += 1 }
            guard position > start, position - start <= 7, position < bytes.count, bytes[position] == 58,
                  let count = Int(String(bytes: bytes[start..<position], encoding: .ascii) ?? ""), count <= maximumBytes,
                  position + 1 + count <= bytes.count else { throw ViewerError.layoutChanged }
            position += 1; let content = position..<(position + count); position += count; return content
        }
        mutating func value(depth: Int) throws {
            items += 1
            guard depth < 32, items < 100_000, position < bytes.count else { throw ViewerError.layoutChanged }
            switch bytes[position] {
            case 100: _ = try dictionary(depth: depth)
            case 108:
                position += 1
                while position < bytes.count, bytes[position] != 101 { try value(depth: depth + 1) }
                guard position < bytes.count else { throw ViewerError.layoutChanged }; position += 1
            case 105:
                position += 1; let start = position
                while position < bytes.count, bytes[position] != 101 { position += 1 }
                let raw = String(bytes: bytes[start..<position], encoding: .ascii) ?? ""
                guard position < bytes.count, raw.range(of: #"^(0|-?[1-9][0-9]*)$"#, options: .regularExpression) != nil else { throw ViewerError.layoutChanged }
                position += 1
            default: _ = try string()
            }
        }
    }
}
