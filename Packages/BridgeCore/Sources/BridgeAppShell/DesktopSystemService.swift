import AppKit
import Foundation

public protocol DesktopSystemServing: Sendable {
  @MainActor func selectProjectDirectory() async -> URL?
  @MainActor func open(_ url: URL) -> Bool
  @MainActor func copyToPasteboard(_ value: String) -> Bool
  @MainActor func showMainWindow()
  @MainActor func terminateApplication()
}

public struct AppKitDesktopSystemService: DesktopSystemServing {
  public init() {}

  @MainActor
  public func selectProjectDirectory() async -> URL? {
    let panel = NSOpenPanel()
    panel.title = "添加 Codex Bridge 项目"
    panel.message = "选择 Bridge 可以读取的项目根目录。"
    panel.prompt = "添加项目"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false
    panel.resolvesAliases = true
    return await panel.begin() == .OK ? panel.url : nil
  }

  @MainActor
  public func open(_ url: URL) -> Bool {
    NSWorkspace.shared.open(url)
  }

  @MainActor
  public func copyToPasteboard(_ value: String) -> Bool {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    return pasteboard.setString(value, forType: .string)
  }

  @MainActor
  public func showMainWindow() {
    NSApplication.shared.activate(ignoringOtherApps: true)
    guard let window = NSApplication.shared.windows.first(where: { $0.canBecomeMain }) else {
      return
    }
    window.makeKeyAndOrderFront(nil)
  }

  @MainActor
  public func terminateApplication() {
    NSApplication.shared.terminate(nil)
  }
}
