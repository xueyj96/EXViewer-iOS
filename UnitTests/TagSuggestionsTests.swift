import XCTest
import ExViewerCore
@testable import ExViewer

final class TagSuggestionsTests: XCTestCase {
    func testSuggestionAndExactRequestsIgnoreCaseAndOuterWhitespace() {
        XCTAssertEqual(TagSuggestionRequest.text(prefix: " EnGLISh ", namespace: " ALL "), "english")
        XCTAssertEqual(TagSuggestionRequest.text(prefix: " GLI ", namespace: " LANGUAGE "), "language:gli")
        XCTAssertEqual(TagSuggestionRequest.exactText(for: .init(namespace: "LANGUAGE", name: "EnGLISh")), "language:english$")
        let item = TagSuggestion(tag: .init(namespace: "language", name: "English"), source: .site, chineseName: nil, matchedAlias: nil)
        XCTAssertEqual(TagSuggestionRequest.matching([item], namespace: " LANGUAGE "), [item])
    }

    func testLocalMixedCaseFragmentsKeepOriginalNamesAndChineseTranslations() {
        let catalog = TagTranslationCatalog(version: "fixture", source: "test", commit: "fixture", license: "test", updatedAt: nil,
                                            namespaces: ["language": ["English": "英语"], "artist": ["Sample Artist": "样例作者"]])
        for text in ["GLI", "gli", "gLi"] {
            let matches = catalog.matches(text, namespace: "LANGUAGE")
            XCTAssertEqual(matches.map(\.tag.name), ["English"])
            XCTAssertEqual(matches.first?.chineseName, "英语")
            XCTAssertEqual(matches.first?.source, .dictionary)
        }
        XCTAssertEqual(catalog.matches("aMpLe", namespace: "all").first?.tag.name, "Sample Artist")
        XCTAssertEqual(catalog.matches("英语", namespace: "all").first?.tag.name, "English")
        XCTAssertTrue(catalog.matches("gli", namespace: "artist").isEmpty)
    }

    @MainActor func testCaseInsensitiveExactCandidateSurvivesMergedPrefixResults() async throws {
        let artists = Dictionary(uniqueKeysWithValues: (0..<24).map { ("english author \($0)", "样例作者\($0)") })
        let catalog = TagTranslationCatalog(version: "fixture", source: "test", commit: "fixture", license: "test", updatedAt: nil,
                                            namespaces: ["language": ["English": "英语"], "artist": artists])
        let model = TagSuggestionModel(catalog: catalog)
        model.update(prefix: "EnGLISH", namespace: "all", session: SiteSession(qa: true), qa: true, arguments: ["--qa-tags-offline"])
        for _ in 0..<100 {
            if model.items.first?.source == .qaFixture { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(model.items.first?.id, "language:english", "An exact tag must not disappear behind 20 alphabetical prefix matches")
        XCTAssertEqual(model.items.count, 20)
        XCTAssertEqual(Set(model.items.map(\.id)).count, model.items.count)
    }

    @MainActor func testCancellingRemoteSuggestionsClearsLoadingAndKeepsLocalCandidates() async throws {
        let catalog = TagTranslationCatalog(version: "fixture", source: "test", commit: "fixture", license: "test",
                                            updatedAt: nil, namespaces: ["language": ["English": "英语"]])
        let model = TagSuggestionModel(catalog: catalog)
        model.update(prefix: "eng", namespace: "language", session: SiteSession(qa: true), qa: true,
                     arguments: ["--qa-tags-delayed"])
        for _ in 0..<100 where model.items.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.state, .loading)
        XCTAssertEqual(model.items.map(\.id), ["language:english"])
        model.cancel()
        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.items.map(\.id), ["language:english"])
    }

    func testMergedCandidatesRankExactThenPrefixThenInteriorFragment() {
        let names = ["learn english", "English reader", "ENGLISH"]
        let items = names.map { TagSuggestion(tag: .init(namespace: "other", name: $0), source: .dictionary, chineseName: nil, matchedAlias: nil) }
        XCTAssertEqual(TagSuggestionRequest.ranked(items, prefix: "eNgLiSh").map(\.tag.name), ["ENGLISH", "English reader", "learn english"])
    }

    @MainActor func testConcurrentVerificationsStayPacedWhenOneWaiterIsCancelled() async throws {
        let pacer = TagSuggestionPacer(interval: 0.08)
        try await pacer.wait()
        let tasks = (0..<3).map { _ in
            Task { @MainActor () -> TimeInterval? in
                do { try await pacer.wait(); return ProcessInfo.processInfo.systemUptime }
                catch { return nil }
            }
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        tasks[1].cancel()
        var starts: [TimeInterval] = []
        for task in tasks { if let time = await task.value { starts.append(time) } }
        let cancelled = await tasks[1].value
        XCTAssertNil(cancelled)
        XCTAssertEqual(starts.count, 2)
        try await pacer.wait()
        starts.append(ProcessInfo.processInfo.systemUptime)
        starts.sort()
        for index in 1..<starts.count {
            XCTAssertGreaterThanOrEqual(starts[index] - starts[index - 1], 0.075,
                                        "Actual releases must stay separated after concurrent waits")
        }
    }

    @MainActor func testSiteAliasRanksByMatchedNameAndKeepsCanonicalTagInCache() throws {
        let payload = Data(#"{"tags":{"1":{"ns":"temp","tn":"deformation","mns":"female","mtn":"defloration"},"2":{"ns":"female","tn":"defloration"},"3":{"ns":"female","tn":"stomach deformation"},"4":{"ns":"temp","tn":"skin deformation","mns":"female","mtn":"defloration"}}}"#.utf8)
        let items = try EHTagSuggestionResponse.parse(payload)
        let results = TagSuggestionRequest.ranked(items, prefix: "DeFORMATION", limit: 2)
        XCTAssertEqual(results.map(\.id), ["female:defloration", "female:stomach deformation"])
        let first = try XCTUnwrap(results.first)
        XCTAssertEqual(first.matchedAlias?.id, "temp:deformation")
        let cached = TagSuggestionModel.cached(first)
        XCTAssertEqual(cached.source, .cached)
        XCTAssertEqual(cached.id, first.id)
        XCTAssertEqual(cached.matchedAlias, first.matchedAlias)
        let direct = TagSuggestionRequest.ranked(items, prefix: "defloration").first
        XCTAssertEqual(direct?.id, first.id)
        XCTAssertNil(direct?.matchedAlias)

        var search = SearchQuery()
        search.rules = [TagRule(tag: cached.tag, match: .exclude)]
        XCTAssertEqual(try search.expression(), #"-female:"defloration"$"#)
    }
    func testOfficialPayloadUsesNumericMapKeysAndOptionalSlaveMetadata() throws {
        let data = Data(#"{"tags":{"1058":{"ns":"language","tn":"english"},"7":{"tn":"sample","mns":"other","mtn":"root"}}}"#.utf8)
        let values = try EHTagSuggestionResponse.parse(data)
        XCTAssertEqual(values.map(\.tag.id), ["language:english", "other:root"])
        XCTAssertNil(values.first?.matchedAlias)
        XCTAssertEqual(values.last?.matchedAlias, GalleryTag(namespace: "other", name: "sample"))
    }

    func testEmptyArrayIsValidNoResultsPayload() throws {
        XCTAssertTrue(try EHTagSuggestionResponse.parse(Data(#"{"tags":[]}"#.utf8)).isEmpty)
        XCTAssertTrue(try EHTagSuggestionResponse.parse(Data("[]".utf8)).isEmpty)
    }

    func testSiteErrorPayloadNeverSurfacesServerText() {
        let data = Data(#"{"error":"private diagnostic example"}"#.utf8)
        XCTAssertThrowsError(try EHTagSuggestionResponse.parse(data)) { error in
            XCTAssertEqual(error as? TagSuggestionFailure, .site)
            XCTAssertFalse(error.localizedDescription.contains("private diagnostic example"))
        }
    }

    func testAllNamespaceRequestUsesPlainPrefixAndHidesUnusableCandidates() throws {
        let payload = Data(#"{"tags":{"1":{"ns":"language","tn":"english"},"2":{"ns":"temp","tn":"temporary"},"3":{"ns":"temp","tn":"sample","mns":"artist","mtn":"primary artist"},"4":{"ns":"artist","tn":"broken link","mns":"temp","mtn":"unsupported"},"5":{"ns":"temp","tn":"incomplete","mns":"artist","mtn":" "}}}"#.utf8)
        let parsed = try EHTagSuggestionResponse.parse(payload)
        XCTAssertEqual(TagSuggestionRequest.text(prefix: "english", namespace: "all"), "english")
        XCTAssertEqual(TagSuggestionRequest.text(prefix: "eng", namespace: "language"), "language:eng")
        XCTAssertEqual(TagSuggestionRequest.matching(parsed, namespace: "all").map(\.id), ["artist:primary artist", "language:english"])
        XCTAssertEqual(TagSuggestionRequest.matching(parsed, namespace: "language").map(\.tag.namespace), ["language"])
        XCTAssertEqual(TagSuggestionRequest.matching(parsed, namespace: "artist").map(\.id), ["artist:primary artist"])
        XCTAssertTrue(TagSuggestionRequest.isSelectable(GalleryTag(namespace: "language", name: "english")))
        XCTAssertFalse(TagSuggestionRequest.isSelectable(GalleryTag(namespace: "temp", name: "temporary")))
    }

    func testLocalChineseAndOriginalNameMatchesRemainUnverifiedDictionaryResults() {
        let catalog = TagTranslationCatalog(
            version: "fixture-v1", source: "EhTagTranslation/Database", commit: "fixture-commit",
            license: "CC BY-NC-SA 3.0 CN", updatedAt: nil,
            namespaces: ["language": ["english": "英语", "japanese": "日语"], "artist": ["sample artist": "样例作者"]]
        )
        let chinese = catalog.matches("英语", namespace: "all")
        XCTAssertEqual(chinese.map(\.tag.id), ["language:english"])
        XCTAssertEqual(chinese.first?.source, .dictionary)
        XCTAssertEqual(chinese.first?.chineseName, "英语")
        XCTAssertEqual(catalog.matches("sample", namespace: "artist").first?.tag.name, "sample artist")
        XCTAssertTrue(catalog.matches("英语", namespace: "artist").isEmpty)
        XCTAssertTrue(catalog.information.contains("非全站标签目录"))
    }

    @MainActor func testDelayedQACandidateFromPriorQueryCannotReplaceCurrentResults() async throws {
        let model = TagSuggestionModel(catalog: nil)
        let session = SiteSession(qa: true)
        model.update(prefix: "english", namespace: "all", session: session, qa: true, arguments: ["--qa-tags-delayed"])
        try await Task.sleep(nanoseconds: 100_000_000)
        model.update(prefix: "prev", namespace: "all", session: session, qa: true, arguments: ["--qa-tags-delayed"])
        for _ in 0..<180 {
            if model.items.first?.tag.id == "artist:preview" { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(model.items.map(\.tag.id), ["artist:preview"])
        XCTAssertEqual(model.items.first?.source, .qaFixture)
    }

    func testCancelledLocalWorkerReturnsNoPartialResults() async {
        let values = Dictionary(uniqueKeysWithValues: (0..<4_000).map { ("tag-\($0)", "中文标签\($0)") })
        let catalog = TagTranslationCatalog(version: "fixture-v1", source: "test", commit: "fixture", license: "test", updatedAt: nil, namespaces: ["other": values])
        let worker = Task.detached { () -> [TagSuggestion] in
            withUnsafeCurrentTask { $0?.cancel() }
            return catalog.matches("中文", namespace: "all")
        }
        let matches = await worker.value
        XCTAssertTrue(matches.isEmpty)
    }

    func testLargeLocalMatchSetIsCappedBeforeReturning() {
        let values = Dictionary(uniqueKeysWithValues: (0..<4_000).map { ("tag-\($0)", "中文标签\($0)") })
        let catalog = TagTranslationCatalog(version: "fixture-v1", source: "test", commit: "fixture", license: "test", updatedAt: nil, namespaces: ["other": values])
        XCTAssertEqual(catalog.matches("tag", namespace: "all").count, 20)
    }
}
