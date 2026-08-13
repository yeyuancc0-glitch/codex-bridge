import AppKit
import BridgeAppShell
import SwiftUI

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

    MenuBarExtra("Codex Bridge", systemImage: "link") {
      BridgeMenuBarView(runtime: runtime)
    }
  }
}

@MainActor
private final class CodexBridgeAppDelegate: NSObject, NSApplicationDelegate {
  private weak var runtime: BridgeDesktopRuntime?
  private var isShuttingDown = false
  private var canTerminate = false

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
