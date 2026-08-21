import XCTest

@testable import BridgeServiceAppShell

final class WorkbenchThreadTitlePresentationTests: XCTestCase {
  func testShortTitleRemainsUnchanged() {
    XCTAssertEqual(
      WorkbenchThreadTitlePresentation.compact("短会话", maximumCharacters: 28),
      "短会话"
    )
  }

  func testWhitespaceIsCollapsedForSingleLinePresentation() {
    XCTAssertEqual(
      WorkbenchThreadTitlePresentation.compact(
        "第一行\n  第二行\t第三行",
        maximumCharacters: 48
      ),
      "第一行 第二行 第三行"
    )
  }

  func testLongTitleIsCappedWithEllipsis() {
    let compact = WorkbenchThreadTitlePresentation.compact(
      String(repeating: "长", count: 30),
      maximumCharacters: 8
    )

    XCTAssertEqual(compact, "长长长长长长长…")
    XCTAssertEqual(compact.count, 8)
  }

  func testWhitespaceOnlyTitleUsesFallback() {
    XCTAssertEqual(
      WorkbenchThreadTitlePresentation.compact(" \n\t ", maximumCharacters: 28),
      "未命名会话"
    )
  }
}
