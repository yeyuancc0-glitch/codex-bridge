import XCTest

@testable import BridgeServiceAppShell

final class WorkbenchApprovalPresentationTests: XCTestCase {
  func testFirstPendingApprovalRequestsReveal() {
    XCTAssertTrue(
      WorkbenchApprovalPresentation.shouldReveal(
        previous: [],
        current: ["codex:approval-1"]
      )
    )
  }

  func testAdditionalPendingApprovalRequestsReveal() {
    XCTAssertTrue(
      WorkbenchApprovalPresentation.shouldReveal(
        previous: ["codex:approval-1"],
        current: ["codex:approval-1", "direct:approval-1"]
      )
    )
  }

  func testUnchangedOrResolvedApprovalsDoNotRequestReveal() {
    XCTAssertFalse(
      WorkbenchApprovalPresentation.shouldReveal(
        previous: ["codex:approval-1"],
        current: ["codex:approval-1"]
      )
    )
    XCTAssertFalse(
      WorkbenchApprovalPresentation.shouldReveal(
        previous: ["codex:approval-1"],
        current: []
      )
    )
  }
}
