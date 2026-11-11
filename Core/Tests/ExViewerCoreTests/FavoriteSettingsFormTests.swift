import XCTest
@testable import ExViewerCore

final class FavoriteSettingsFormTests: XCTestCase {
    private func html(action: String = "") -> String {
        let groups = (0...9).map { "<input name='favorite_\($0)' value='Group \($0)' maxlength='20'>" }.joined()
        return """
        <form id='profile_form' method='post'><input name='profile_set' value='1'></form>
        <form method='post' action='\(action)'>
          \(groups)
          <input type='hidden' name='future_option' value='A&amp;B'>
          <input type='radio' name='fs' value='0'><input type='radio' name='fs' value='1' checked>
          <input type='checkbox' name='oi' checked><input type='checkbox' name='disabled_option' disabled checked>
          <select name='dm'><option value='compact'>Compact</option><option value='extended' selected>Extended</option></select>
          <select name='rc'><option value='25'>25</option><option value='50'>50</option></select>
          <textarea name='xu'>one\ntwo</textarea><input name='apply' type='submit' value='Apply'>
        </form>
        """
    }

    func testRenameChangesOnlyOneNameAndPreservesSuccessfulFormControls() throws {
        let form = try FavoriteSettingsForm.read(html(), site: .ex)
        let request = try form.requestRenaming(group: 3, to: "  画集 & +  ")
        XCTAssertEqual(request.url.absoluteString, "https://exhentai.org/uconfig.php")
        let query = String(decoding: request.body, as: UTF8.self).replacingOccurrences(of: "+", with: "%20")
        let pairs = URLComponents(string: "https://example.invalid/?" + query)!.queryItems!
        let values = Dictionary(uniqueKeysWithValues: pairs.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(values["favorite_3"], "画集 & +")
        for index in (0...9) where index != 3 { XCTAssertEqual(values["favorite_\(index)"], "Group \(index)") }
        XCTAssertEqual(values["future_option"], "A&B")
        XCTAssertEqual(values["fs"], "1")
        XCTAssertEqual(values["oi"], "on")
        XCTAssertEqual(values["dm"], "extended")
        XCTAssertEqual(values["rc"], "25")
        XCTAssertEqual(values["xu"], "one\ntwo")
        XCTAssertEqual(values["apply"], "Apply")
        XCTAssertNil(values["profile_set"])
        XCTAssertNil(values["disabled_option"])
    }

    func testRejectsPartialFormsInvalidNamesAndForeignActions() throws {
        let form = try FavoriteSettingsForm.read(html(), site: .eh)
        for name in ["", "\n", "bad\nname", String(repeating: "a", count: 21)] {
            XCTAssertThrowsError(try form.requestRenaming(group: 0, to: name))
        }
        XCTAssertThrowsError(try form.requestRenaming(group: 10, to: "Name"))
        XCTAssertThrowsError(try FavoriteSettingsForm.read(html(action: "https://example.invalid/uconfig.php"), site: .eh))
        XCTAssertThrowsError(try FavoriteSettingsForm.read(html().replacingOccurrences(of: "name='favorite_9'", with: "name='missing'"), site: .eh))
        XCTAssertThrowsError(try FavoriteSettingsForm.read(html().replacingOccurrences(of: "name='favorite_9'", with: "name='favorite_8'"), site: .eh))
    }
}
