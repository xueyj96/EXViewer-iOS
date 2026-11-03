import XCTest
@testable import ExViewerCore

final class SearchRequestContractTests: XCTestCase {
    func testDeprecatedLocalOrderDoesNotChangeSearchFiltersOrEmitARequestOption() throws {
        var query = SearchQuery(); query.text = "coast"; query.titleOnly = true
        query.artist = "preview studio"; query.uploader = "Preview"
        query.minRating = 4; query.minPages = 20; query.maxPages = 200
        query.excludedCategories = [1, 32]; query.requireTorrent = true
        query.rules = [.init(tag: .init(namespace: "language", name: "chinese")),
                       .init(tag: .init(namespace: "other", name: "watercolor"), match: .exclude)]
        let expected = try query.url(site: .ex)
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(query)) as? [String: Any])
        for order in ["siteDefault", "ratingDescending", "pagesDescending", "pagesAscending", "title"] {
            fields["sortOrder"] = order
            let restored = try JSONDecoder().decode(SearchQuery.self, from: JSONSerialization.data(withJSONObject: fields))
            XCTAssertEqual(restored, query)
            XCTAssertEqual(try restored.url(site: .ex), expected)
            let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(restored)) as? [String: Any])
            XCTAssertNil(encoded["sortOrder"])
        }
        let parameters = try XCTUnwrap(URLComponents(url: expected, resolvingAgainstBaseURL: false)?.queryItems)
        let values = Dictionary(uniqueKeysWithValues: parameters.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(Set(values.keys), ["f_search", "inline_set", "f_cats", "f_sr", "f_srdd", "f_sp", "f_spf", "f_spt", "f_sto"])
        XCTAssertEqual(values["f_sr"], "on"); XCTAssertEqual(values["f_srdd"], "4")
        XCTAssertEqual(values["f_spf"], "20"); XCTAssertEqual(values["f_spt"], "200")
        XCTAssertEqual(values["f_cats"], "33")
        XCTAssertEqual(values["f_sto"], "on"); XCTAssertNil(values["f_storr"])
    }

    func testLegacySortOnlyQueryBecomesAnUnfilteredRequestAndInputStillPreservesRealFilters() throws {
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(SearchQuery())) as? [String: Any])
        fields["sortOrder"] = "ratingDescending"
        let query = try JSONDecoder().decode(SearchQuery.self, from: JSONSerialization.data(withJSONObject: fields))
        XCTAssertEqual(query, SearchQuery()); XCTAssertFalse(query.hasSettings)
        var filters = query; filters.minRating = 3; filters.maxPages = 200
        let mixed = try SearchInputParser.parse("coast language:chinese -other:watercolor", preserving: filters).query
        XCTAssertEqual(mixed.minRating, 3); XCTAssertEqual(mixed.maxPages, 200)
        XCTAssertEqual(mixed.rules.map(\.match), [.all, .exclude])
        XCTAssertEqual(mixed.text, "coast")
    }
}
