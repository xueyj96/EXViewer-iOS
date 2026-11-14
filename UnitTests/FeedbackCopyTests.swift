import XCTest
import ExViewerCore
@testable import ExViewer

@MainActor
final class FeedbackCopyTests: XCTestCase {
    func testLegacyFeedbackUsesPlainPhrasesWithoutChangingTagSyntaxOrNumbers() {
        let center = AppToastCenter()
        let owner = UUID()
        center.show("\n请求失败，请重试。\nHTTP 503；language:chinese 评分 2.8!", owner: owner,
                    identifier: "feedback.test", onDismiss: nil)
        XCTAssertEqual(center.presentation?.message, "请求失败 请重试 HTTP 503 language:chinese 评分 2.8!")
        XCTAssertEqual(center.presentation?.owner, owner)
        XCTAssertEqual(center.presentation?.identifier, "feedback.test")
    }

    func testNoEmptyToastOrCrossOwnerDismissal() {
        let center = AppToastCenter()
        let owner = UUID()
        center.show("。\n；", owner: owner, identifier: "feedback.empty", onDismiss: nil)
        XCTAssertNil(center.presentation)
        var dismissed = false
        center.show("已保存", owner: owner, identifier: "feedback.saved", onDismiss: { dismissed = true })
        center.dismiss(owner: UUID())
        XCTAssertFalse(dismissed)
        XCTAssertEqual(center.presentation?.message, "已保存")
        center.dismiss(owner: owner)
        XCTAssertTrue(dismissed)
        XCTAssertNil(center.presentation)
    }

    func testFailureCopyPreservesCauseAndSubmissionCertainty() {
        let failures: [ViewerError] = [.authentication, .challenge, .imageLimit, .restricted, .network,
            .layoutChanged, .tagsUnavailable, .ratingUnavailable, .storage, .sessionRecord, .stale]
        for failure in failures {
            let message = failure.localizedDescription
            XCTAssertLessThanOrEqual(message.count, 30, message)
            XCTAssertFalse(message.contains("。"), message)
            XCTAssertFalse(message.contains("，"), message)
            XCTAssertFalse(message.contains("\n"), message)
        }
        let longInput = String(repeating: "unexpected", count: 100)
        XCTAssertEqual(SearchInputError.invalidQuotedValue(longInput).localizedDescription, "引号后的内容无法解析")
        XCTAssertEqual(SearchInputError.unsupportedScope(longInput).localizedDescription, "暂不支持此搜索范围")
        XCTAssertTrue(ViewerError.keychain(.update, -34018).localizedDescription.contains("-34018"))
        XCTAssertTrue(RequestFailure.http(.media, 429).localizedDescription.contains("429"))
        let unsent = FavoriteMutationFailure(requestMayHaveBeenSent: false, underlying: URLError(.networkConnectionLost))
        let unknown = FavoriteMutationFailure(requestMayHaveBeenSent: true, underlying: URLError(.networkConnectionLost))
        XCTAssertTrue(unsent.localizedDescription.contains("尚未提交"))
        XCTAssertTrue(unknown.localizedDescription.contains("待确认"))
        XCTAssertFalse(unknown.localizedDescription.contains("失败"))
    }

    func testBackgroundPauseKeepsProgressAndDoesNotReportFailure() {
        let end = DownloadBackgroundEnd(completion: .paused, completed: 3, total: 10)
        XCTAssertEqual(end.subtitle, "已保存 3/10 页 可继续下载")
        XCTAssertTrue(end.completion.systemSuccess)
        XCTAssertFalse(end.subtitle.contains("失败"))
    }
}
