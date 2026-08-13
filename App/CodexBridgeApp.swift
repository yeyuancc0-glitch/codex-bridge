import AppKit
import BridgeAppShell
import SwiftUI
@preconcurrency import UserNotifications

@main
struct CodexBridgeApp: App {
  @NSApplicationDelegateAdaptor(CodexBridgeAppDelegate.self) private var appDelegate
  @StateObject private var runtime: BridgeDesktopRuntime

  init() {
    let runtime = BridgeDesktopRuntime()
    _runtime = StateObject(wrappedValue: runtime)
    appDelegate.install(runtime)
  }

  var body: some Scene {
    WindowGroup("Codex Bridge") {
      BridgeDesktopRootView(runtime: runtime)
    }
    .defaultSize(width: 1180, height: 760)

    MenuBarExtra {
      BridgeMenuBarView(runtime: runtime)
    } label: {
      Label("Codex Bridge", systemImage: "link")
        .accessibilityLabel("Codex Bridge")
    }
  }
}

@MainActor
private final class CodexBridgeAppDelegate: NSObject, NSApplicationDelegate {
  private weak var runtime: BridgeDesktopRuntime?
  private var isShuttingDown = false
  private var canTerminate = false

  override init() {
    super.init()
    UNUserNotificationCenter.current().delegate = self
  }

  func install(_ runtime: BridgeDesktopRuntime) {
    self.runtime = runtime
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if canTerminate { return .terminateNow }
    guard !isShuttingDown, let runtime else { return .terminateNow }
    isShuttingDown = true
    Task {
      await runtime.shutdown()
      canTerminate = true
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}

extension CodexBridgeAppDelegate: UNUserNotificationCenterDelegate {
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    _ = center
    _ = notification
    completionHandler([.banner, .sound])
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    _ = center
    let route = DesktopTaskNotificationRoute(
      userInfo: response.notification.request.content.userInfo
    )
    completionHandler()
    guard let route else { return }
    Task { @MainActor [weak self] in
      self?.runtime?.openTaskFromNotification(route.taskID)
    }
  }
}
