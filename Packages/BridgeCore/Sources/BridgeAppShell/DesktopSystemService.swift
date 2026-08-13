import AppKit
import Darwin
import Foundation
import ServiceManagement
import UniformTypeIdentifiers

public enum DesktopSupportBundleSaveResult: Equatable, Sendable {
  case saved
  case cancelled
  case unavailable
  case failed
}

public enum DesktopLaunchAtLoginStatus: Equatable, Sendable {
  case unavailable
  case disabled
  case enabled
  case requiresApproval
}

public enum DesktopSystemServiceError: LocalizedError, Equatable, Sendable {
  case launchAtLoginUnavailable

  public var errorDescription: String? {
    switch self {
    case .launchAtLoginUnavailable:
      "此 App 构建无法管理登录时启动。"
    }
  }
}

public protocol DesktopSystemServing: Sendable {
  @MainActor var supportsSupportBundleExport: Bool { get }
  @MainActor var launchAtLoginStatus: DesktopLaunchAtLoginStatus { get }
  @MainActor func selectProjectDirectory() async -> URL?
  @MainActor func selectReplacementProjectDirectory(projectName: String) async -> URL?
  @MainActor func open(_ url: URL) -> Bool
  @MainActor func copyToPasteboard(_ value: String) -> Bool
  @MainActor func saveSupportBundle(
    _ data: Data,
    suggestedFileName: String
  ) async -> DesktopSupportBundleSaveResult
  @MainActor func showMainWindow()
  @MainActor func terminateApplication()
  @MainActor func setLaunchAtLoginEnabled(_ enabled: Bool) throws
}

extension DesktopSystemServing {
  @MainActor public var launchAtLoginStatus: DesktopLaunchAtLoginStatus { .unavailable }

  @MainActor public func setLaunchAtLoginEnabled(_ enabled: Bool) throws {
    _ = enabled
    throw DesktopSystemServiceError.launchAtLoginUnavailable
  }

  @MainActor public func selectReplacementProjectDirectory(projectName: String) async -> URL? {
    _ = projectName
    return await selectProjectDirectory()
  }
}

public struct AppKitDesktopSystemService: DesktopSystemServing {
  public init() {}

  @MainActor public var supportsSupportBundleExport: Bool { true }

  @MainActor public var launchAtLoginStatus: DesktopLaunchAtLoginStatus {
    switch SMAppService.mainApp.status {
    case .enabled: .enabled
    case .requiresApproval: .requiresApproval
    case .notRegistered: .disabled
    case .notFound: .unavailable
    @unknown default: .unavailable
    }
  }

  @MainActor
  public func selectProjectDirectory() async -> URL? {
    await selectDirectory(
      title: "添加 Codex Bridge 项目",
      message: "选择 Bridge 可以读取的项目根目录。",
      prompt: "添加项目"
    )
  }

  @MainActor
  public func selectReplacementProjectDirectory(projectName: String) async -> URL? {
    await selectDirectory(
      title: "重新连接“\(projectName)”",
      message: "选择原项目路径以更新卷身份。Bridge 不会移动或删除文件。",
      prompt: "重新连接"
    )
  }

  @MainActor
  private func selectDirectory(title: String, message: String, prompt: String) async -> URL? {
    let panel = NSOpenPanel()
    panel.title = title
    panel.message = message
    panel.prompt = prompt
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
  public func saveSupportBundle(
    _ data: Data,
    suggestedFileName: String
  ) async -> DesktopSupportBundleSaveResult {
    let panel = NSSavePanel()
    panel.title = "导出 Codex Bridge 脱敏支持包"
    panel.message = "支持包只包含脱敏后的结构化诊断事实。"
    panel.nameFieldStringValue = suggestedFileName
    panel.allowedContentTypes = [.json]
    panel.canCreateDirectories = true
    guard await panel.begin() == .OK, let url = panel.url else { return .cancelled }
    return await Task.detached { DesktopSupportBundleWriter.persist(data, at: url) }.value
      ? .saved : .failed
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

  @MainActor
  public func setLaunchAtLoginEnabled(_ enabled: Bool) throws {
    let service = SMAppService.mainApp
    if enabled {
      guard service.status == .notRegistered else { return }
      try service.register()
      return
    }
    guard service.status != .notRegistered, service.status != .notFound else { return }
    try service.unregister()
  }

}

enum DesktopSupportBundleWriter {
  nonisolated static func persist(
    _ data: Data,
    at destination: URL,
    beforeDirectoryOpen: @Sendable () -> Void = {}
  ) -> Bool {
    let fileName = destination.lastPathComponent
    guard destination.isFileURL, !fileName.isEmpty, fileName != ".", fileName != "..",
      !fileName.contains("\0")
    else {
      return false
    }
    guard let parentPath = canonicalDirectory(destination.deletingLastPathComponent()) else {
      return false
    }
    beforeDirectoryOpen()
    let directory = openDirectory(parentPath)
    guard directory >= 0 else { return false }
    defer { Darwin.close(directory) }

    let temporaryName = ".codex-bridge-support-\(UUID().uuidString).tmp"
    let descriptor = openat(
      directory,
      temporaryName,
      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
      S_IRUSR | S_IWUSR
    )
    guard descriptor >= 0 else { return false }
    var temporaryExists = true
    defer {
      Darwin.close(descriptor)
      if temporaryExists { unlinkat(directory, temporaryName, 0) }
    }
    guard writeAll(data, to: descriptor), fsync(descriptor) == 0 else { return false }
    guard renameat(directory, temporaryName, directory, fileName) == 0 else { return false }
    temporaryExists = false
    return fsync(directory) == 0
  }

  nonisolated private static func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
    data.withUnsafeBytes { bytes in
      guard let base = bytes.baseAddress else { return data.isEmpty }
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
        if count > 0 {
          offset += count
        } else if count < 0, errno == EINTR {
          continue
        } else {
          return false
        }
      }
      return true
    }
  }

  nonisolated private static func openDirectory(_ path: String) -> Int32 {
    guard path.hasPrefix("/") else { return -1 }
    var current = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard current >= 0 else { return -1 }
    for component in path.split(separator: "/", omittingEmptySubsequences: true) {
      let name = String(component)
      guard name != ".", name != "..", !name.contains("\0") else {
        Darwin.close(current)
        return -1
      }
      let next = openat(
        current,
        name,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
      )
      Darwin.close(current)
      guard next >= 0 else { return -1 }
      current = next
    }
    return current
  }

  nonisolated private static func canonicalDirectory(_ url: URL) -> String? {
    guard url.isFileURL, let path = Darwin.realpath(url.path, nil) else { return nil }
    defer { Darwin.free(path) }
    return String(cString: path)
  }
}

extension DesktopSystemServing {
  @MainActor public var supportsSupportBundleExport: Bool { false }

  @MainActor
  public func saveSupportBundle(
    _: Data,
    suggestedFileName _: String
  ) async -> DesktopSupportBundleSaveResult {
    .unavailable
  }
}
