import WebKit
import XCTest

@testable import BridgeServiceAppShell

final class ChatGPTWebViewDelegateTests: XCTestCase {
  private let policySelector = NSSelectorFromString(
    "webView:decidePolicyForNavigationAction:preferences:decisionHandler:")
  private let createWebViewSelector = NSSelectorFromString(
    "webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:")
  private let responsePolicySelector = NSSelectorFromString(
    "webView:decidePolicyForNavigationResponse:decisionHandler:")
  private let actionDownloadSelector = NSSelectorFromString(
    "webView:navigationAction:didBecomeDownload:")
  private let responseDownloadSelector = NSSelectorFromString(
    "webView:navigationResponse:didBecomeDownload:")
  private let destinationSelector = NSSelectorFromString(
    "download:decideDestinationUsingResponse:suggestedFilename:completionHandler:")

  @MainActor
  func testCoordinatorImplementsWKNavigationDelegatePolicySelectors() {
    let coordinator = ChatGPTWebView.Coordinator(ChatGPTWebView())

    XCTAssertTrue(
      coordinator.responds(to: policySelector),
      "decidePolicyForNavigationAction:preferences: selector missing")
    XCTAssertTrue(
      coordinator.responds(to: createWebViewSelector),
      "createWebViewWith selector missing")
    XCTAssertTrue(
      coordinator.responds(to: responsePolicySelector),
      "decidePolicyForNavigationResponse selector missing")
    XCTAssertTrue(
      coordinator.responds(to: actionDownloadSelector),
      "navigationAction didBecomeDownload selector missing")
    XCTAssertTrue(
      coordinator.responds(to: responseDownloadSelector),
      "navigationResponse didBecomeDownload selector missing")
    XCTAssertTrue(
      coordinator.responds(to: destinationSelector),
      "WKDownload destination selector missing")
  }

  @MainActor
  func testSafeFilenameStripsPathComponents() {
    XCTAssertEqual(ChatGPTWebView.Coordinator.safeFilename("../../report.pdf"), "report.pdf")
    XCTAssertEqual(ChatGPTWebView.Coordinator.safeFilename("  "), "下载文件")
  }

  @MainActor
  func testDownloadResponsePolicyRecognizesAttachmentsAndUnsupportedContent() throws {
    let url = try XCTUnwrap(URL(string: "https://chatgpt.com/files/report.pdf"))
    let attachment = try XCTUnwrap(
      HTTPURLResponse(
        url: url,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Disposition": "attachment; filename=report.pdf"]))
    let inline = try XCTUnwrap(
      HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [:]))

    XCTAssertTrue(
      ChatGPTWebView.Coordinator.shouldDownload(
        canShowMIMEType: true,
        response: attachment))
    XCTAssertTrue(
      ChatGPTWebView.Coordinator.shouldDownload(
        canShowMIMEType: false,
        response: inline))
    XCTAssertFalse(
      ChatGPTWebView.Coordinator.shouldDownload(
        canShowMIMEType: true,
        response: inline))
  }
}
