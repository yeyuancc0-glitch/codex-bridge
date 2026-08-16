import XCTest

final class CodexBridgeUITests: XCTestCase {
  @MainActor
  func testFirstRunAndMenuBarRenderAccessibleNativeShell() throws {
    continueAfterFailure = false
    let isolatedHome = FileManager.default.temporaryDirectory.appendingPathComponent(
      "CodexBridgeUITests-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: isolatedHome,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    let app = XCUIApplication()
    app.launchEnvironment["HOME"] = isolatedHome.path
    app.launchEnvironment["CFFIXED_USER_HOME"] = isolatedHome.path
    app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
    app.launch()
    defer {
      app.terminate()
      try? FileManager.default.removeItem(at: isolatedHome)
    }

    let window = app.windows.firstMatch
    XCTAssertTrue(window.waitForExistence(timeout: 15))
    XCTAssertGreaterThanOrEqual(window.frame.width, 760)
    XCTAssertGreaterThanOrEqual(window.frame.height, 520)

    XCTAssertTrue(app.staticTexts["欢迎"].waitForExistence(timeout: 15))
    XCTAssertTrue(app.staticTexts["步骤 1 / 9"].exists)
    XCTAssertTrue(app.progressIndicators["首次设置进度"].exists)
    let continueButton = app.buttons["继续"]
    XCTAssertTrue(continueButton.waitForExistence(timeout: 15))
    XCTAssertFalse(app.buttons["返回"].isEnabled)
    XCTAssertTrue(
      app.staticTexts["Bridge 不运营开发者云服务器。项目路径、审批和任务证据保留在这台 Mac。"].exists
    )
    XCTAssertTrue(app.groups["Codex Bridge 首次设置"].exists)

    let windowFrame = window.frame
    try app.performAccessibilityAudit(for: [.hitRegion, .sufficientElementDescription]) {
      issue in
      guard let element = issue.element else { return false }
      // SwiftUI exposes its noninteractive NSHostingView as an unlabeled full-window group.
      let isWindowHost =
        issue.auditType == .sufficientElementDescription
        && element.elementType == .group
        && element.label.isEmpty
        && element.frame == windowFrame
      let isSystemTouchBar =
        issue.auditType == .sufficientElementDescription
        && element.elementType == .touchBar
      return isWindowHost || isSystemTouchBar
    }

    let statusItem = app.statusItems["Codex Bridge"]
    XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
    statusItem.click()
    XCTAssertTrue(app.menuItems["连接尚未配置"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.menuItems["运行任务：0"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.menuItems["待审批：0"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.menuItems["打开 Codex Bridge"].exists)
    XCTAssertTrue(app.menuItems["暂停接收新任务"].exists)
    XCTAssertTrue(app.menuItems["退出"].exists)
  }
}

final class CodexBridgeAppearanceUITests: XCTestCase {
  /// Verifies the shell renders in both light and dark system appearance using
  /// an isolated HOME, without depending on a real Codex account or store.
  @MainActor
  func testFirstRunRendersInLightAndDarkAppearance() throws {
    for appearance in ["Light", "Dark"] {
      continueAfterFailure = false
      let isolatedHome = FileManager.default.temporaryDirectory.appendingPathComponent(
        "CodexBridgeUITests-\(UUID().uuidString)",
        isDirectory: true
      )
      try FileManager.default.createDirectory(
        at: isolatedHome,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: NSNumber(value: 0o700)]
      )
      let app = XCUIApplication()
      app.launchEnvironment["HOME"] = isolatedHome.path
      app.launchEnvironment["CFFIXED_USER_HOME"] = isolatedHome.path
      app.launchArguments += [
        "-AppleLanguages", "(zh-Hans)",
        "-AppleLocale", "zh_CN",
        "-AppleInterfaceStyle", appearance,
      ]
      app.launch()
      defer {
        app.terminate()
        try? FileManager.default.removeItem(at: isolatedHome)
      }

      let window = app.windows.firstMatch
      XCTAssertTrue(window.waitForExistence(timeout: 15), "\(appearance) window missing")
      XCTAssertTrue(
        app.staticTexts["欢迎"].waitForExistence(timeout: 15),
        "\(appearance) welcome missing"
      )
      XCTAssertTrue(app.staticTexts["步骤 1 / 9"].exists, "\(appearance) step missing")
      XCTAssertTrue(
        app.buttons["继续"].waitForExistence(timeout: 15),
        "\(appearance) continue missing"
      )
    }
  }
}
