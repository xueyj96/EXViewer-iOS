import Foundation
import ExViewerCore

struct SearchDraft: Equatable {
    var query: SearchQuery
    var site: GallerySite
    // A stored query already contains literal keywords. Only new field edits are syntax.
    private var editedInput: String?
    var inputText: String {
        get { editedInput ?? query.text }
        set {
            let text = Self.singleLine(newValue)
            editedInput = text == query.text ? nil : text
        }
    }
    var minimumPagesText: String
    var maximumPagesText: String

    init(query: SearchQuery, site: GallerySite) {
        self.query = query
        self.site = site
        minimumPagesText = query.minPages.map(String.init) ?? ""
        maximumPagesText = query.maxPages.map(String.init) ?? ""
        self.query.text = Self.singleLine(query.text)
        self.query.minPages = nil
        self.query.maxPages = nil
    }

    mutating func clear() {
        self = SearchDraft(query: SearchQuery(), site: site)
    }

    mutating func parseInlineFilters() throws {
        guard let editedInput else { return }
        query = try SearchInputParser.parse(editedInput, preserving: query).query
        self.editedInput = nil
    }

    private static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    var hasConditions: Bool {
        var filters = query
        filters.text = ""
        return !inputText.isEmpty || filters.hasSettings || filters.titleOnly || filters.matchPhrase ||
            !minimumPagesText.isEmpty || !maximumPagesText.isEmpty
    }

    func queryWithPageRange() throws -> SearchQuery {
        func page(_ text: String) throws -> Int? {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty { return nil }
            guard let number = Int(value), number >= 0 else { throw ViewerError.invalidQuery("页数须为非负整数") }
            return number
        }
        var proposed = query
        proposed.minPages = try page(minimumPagesText)
        proposed.maxPages = try page(maximumPagesText)
        return proposed
    }

    func validatedQuery() throws -> SearchQuery {
        var proposed = try queryWithPageRange()
        proposed.artist = proposed.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        proposed.uploader = proposed.uploader.trimmingCharacters(in: .whitespacesAndNewlines)
        if let editedInput { proposed = try SearchInputParser.parse(editedInput, preserving: proposed).query }
        _ = try proposed.url(site: site)
        return proposed
    }
}
