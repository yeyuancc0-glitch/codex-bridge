import AppKit
import BridgeServiceAppShell
import SwiftUI

@main
struct CodexBridgeApp: App {
  @NSApplicationDelegateAdaptor(CodexBridgeAppDelegate.self) private var appDelegate
  @StateObject private var model: BridgeServiceAppModel

  init() {
    let model = BridgeServiceAppModel()
    _model = StateObject(wrappedValue: model)
    appDelegate.install(model)
  }

  var body: some Scene {
    WindowGroup("Codex Bridge") {
      BridgeServiceRootView(model: model)
    }
    .defaultSize(width: 1180, height: 760)

    MenuBarExtra {
      BridgeServiceMenuBarView(model: model)
    } label: {
      Label("Codex Bridge", systemImage: "link")
        .accessibilityLabel("Codex Bridge")
    }
  }
}

@MainActor
private final class CodexBridgeAppDelegate: NSObject, NSApplicationDelegate {
  private weak var model: BridgeServiceAppModel?
  private var isClosingClient = false
  private var canTerminate = false

  func install(_ model: BridgeServiceAppModel) {
    self.model = model
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if canTerminate { return .terminateNow }
    guard !isClosingClient, let model else { return .terminateNow }
    isClosingClient = true
    Task {
      await model.shutdownUI()
      canTerminate = true
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}
