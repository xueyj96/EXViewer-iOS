import Foundation

public struct GalleryVersionLinks: Equatable, Sendable {
    public let latest: GalleryRef?
    public let earlier: [GalleryRef]

    public init(latest: GalleryRef?, earlier: [GalleryRef]) {
        self.latest = latest
        self.earlier = earlier
    }
}

public struct GalleryMetadata: Sendable {
    private struct Response: Decodable { var gmetadata: [Entry] }
    private struct VersionID: Decodable, Sendable {
        let value: Int64?

        init(from decoder: Decoder) throws {
            let field = try decoder.singleValueContainer()
            value = (try? field.decode(Int64.self)) ?? (try? field.decode(String.self)).flatMap(Int64.init)
        }
    }

    private struct VersionKey: Decodable, Sendable {
        let value: String?

        init(from decoder: Decoder) throws {
            value = try? decoder.singleValueContainer().decode(String.self)
        }
    }

    private struct Entry: Decodable, Sendable {
        var gid: Int64
        var token: VersionKey?
        var current_gid: VersionID?
        var current_key: VersionKey?
        var parent_gid: VersionID?
        var parent_key: VersionKey?
        var first_gid: VersionID?
        var first_key: VersionKey?
        var title: String?
        var title_jpn: String?
        var category: String?
        var uploader: String?
        var filecount: String?
        var rating: String?
        var tags: [String]?
        var thumb: URL?
        var error: String?
    }
    private let records: [Int64: Entry]

    public init(_ data: Data) throws {
        let response = try JSONDecoder().decode(Response.self, from: data)
        var records: [Int64: Entry] = [:]
        for entry in response.gmetadata { records[entry.gid] = entry }
        self.records = records
    }

    public static func request(_ galleries: [Gallery]) throws -> Data {
        guard !galleries.isEmpty, galleries.count <= 25 else { throw ViewerError.invalidQuery("元数据每批最多 25 项。") }
        let list: [[Any]] = galleries.map { [$0.ref.gid, $0.ref.token] }
        return try JSONSerialization.data(withJSONObject: ["method": "gdata", "gidlist": list, "namespace": 1])
    }
    public static func merge(_ data: Data, into galleries: [Gallery]) throws -> [Gallery] {
        try GalleryMetadata(data).merging(into: galleries)
    }

    public func currentVersion(of reference: GalleryRef) -> GalleryRef? {
        versionLinks(of: reference)?.latest
    }

    public func versionLinks(of reference: GalleryRef) -> GalleryVersionLinks? {
        guard let entry = records[reference.gid], entry.error == nil, entry.token?.value == reference.token else { return nil }
        func link(_ id: VersionID?, _ token: VersionKey?) -> GalleryRef? {
            guard let gid = id?.value, gid > 0, let key = token?.value, !key.isEmpty, key.count <= 128,
                  key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
            return GalleryRef(site: reference.site, gid: gid, token: key)
        }
        let current = link(entry.current_gid, entry.current_key)
        let latest = current.flatMap { $0.gid > reference.gid || $0 == reference ? $0 : nil }
        let earlier = Set([link(entry.parent_gid, entry.parent_key), link(entry.first_gid, entry.first_key)]
            .compactMap { $0 }.filter { $0.gid < reference.gid })
        return GalleryVersionLinks(latest: latest, earlier: earlier.sorted { $0.gid > $1.gid })
    }

    public func merging(into galleries: [Gallery]) -> [Gallery] {
        galleries.map { gallery in
            guard let entry = records[gallery.ref.gid], entry.error == nil else { return gallery }
            var value = gallery
            if let title = entry.title { value.title = title }
            if let title = entry.title_jpn { value.japaneseTitle = title }
            if let category = entry.category { value.category = category }
            if let uploader = entry.uploader { value.uploader = uploader }
            if let count = entry.filecount.flatMap(Int.init) { value.pages = count }
            value.rating = GalleryRatingFilter.average(entry.rating.flatMap(Double.init))
            if let tags = entry.tags { value.tags = tags.compactMap(GalleryTag.init); value.tagsComplete = true }
            if let thumb = entry.thumb, URLPolicy.media(thumb) { value.cover = thumb }
            return value
        }
    }
}
