import WebKit
import XCTest

@testable import BridgeServiceAppShell

final class ChatGPTWebViewDelegateTests: XCTestCase {
  private let policySelector = NSSelectorFromString(
    "webView:decidePolicyForNavigationAction:preferences:decisionHandler:")
  private let createWebViewSelector = NSSelectorFromString(
    "webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:")

  @MainActor
  func testCoordinatorImplementsWKNavigationDelegatePolicySelectors() {
    let coordinator = ChatGPTWebView.Coordinator(ChatGPTWebView())

    XCTAssertTrue(
      coordinator.responds(to: policySelector),
      "decidePolicyForNavigationAction:preferences: selector missing")
    XCTAssertTrue(
      coordinator.responds(to: createWebViewSelector),
      "createWebViewWith selector missing")
  }
}
