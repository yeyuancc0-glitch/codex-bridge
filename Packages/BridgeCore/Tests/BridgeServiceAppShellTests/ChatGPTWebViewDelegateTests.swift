import WebKit
import XCTest

@testable import BridgeServiceAppShell

final class ChatGPTWebViewDelegateTests: XCTestCase {
  @MainActor
  func testReusedWebViewReattachesCurrentCoordinatorDelegates() {
    let webView = WKWebView()
    let coordinator = ChatGPTWebView.Coordinator(ChatGPTWebView())

    ChatGPTWebView.attachDelegates(to: webView, coordinator: coordinator)

    XCTAssertTrue(webView.navigationDelegate === coordinator)
    XCTAssertTrue(webView.uiDelegate === coordinator)
  }

  @MainActor
  func testCoordinatorConsumesEachReloadRequestOnce() {
    let coordinator = ChatGPTWebView.Coordinator(ChatGPTWebView(reloadRequest: 4))

    XCTAssertFalse(coordinator.consumeReloadRequest(4))
    XCTAssertTrue(coordinator.consumeReloadRequest(5))
    XCTAssertFalse(coordinator.consumeReloadRequest(5))
  }

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
  func testDownloadDestinationDoesNotDeleteAnExistingTarget() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("bridge-webview-download-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }

    let target = root.appendingPathComponent("report.pdf")
    try Data("old".utf8).write(to: target)

    let temporary = try XCTUnwrap(ChatGPTWebView.Coordinator.temporaryDestination(for: target))
    XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
    XCTAssertEqual(try Data(contentsOf: target), Data("old".utf8))

    try Data("new".utf8).write(to: temporary)
    try ChatGPTWebView.Coordinator.replaceDownloadedFile(
      temporary: temporary,
      target: target
    )

    XCTAssertEqual(try Data(contentsOf: target), Data("new".utf8))
    XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
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
