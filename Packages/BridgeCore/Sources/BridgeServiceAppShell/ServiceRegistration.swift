import BridgeServiceAppCore
import Darwin
import Foundation
import ServiceManagement

public enum BridgeServiceRegistrationError: Error, LocalizedError, Sendable {
  case executableNotFound

  public var errorDescription: String? {
    switch self {
    case .executableNotFound:
      "App Bundle 中没有找到 Codex Bridge 后台 Service 可执行文件。"
    }
  }
}

@MainActor
public protocol BridgeServiceRegistrationManaging: AnyObject {
  var status: BridgeServiceRegistrationStatus { get }

  func register() throws
  func unregister() async throws
  func openSystemSettings()
}

@MainActor
public final class SystemBridgeServiceRegistration: BridgeServiceRegistrationManaging {
  private let service: SMAppService
  private let plistName: String
  private let machServiceName: String

  public init(
    plistName: String = "org.codexbridge.service.plist",
    machServiceName: String = "org.codexbridge.service"
  ) {
    precondition(!plistName.isEmpty)
    precondition(!machServiceName.isEmpty)
    self.plistName = plistName
    self.machServiceName = machServiceName
    service = SMAppService.agent(plistName: plistName)
  }

  public var status: BridgeServiceRegistrationStatus {
    if isUserLaunchAgentActive() {
      return .enabled
    }

    switch service.status {
    case .enabled:
      return .enabled
    case .requiresApproval:
      return .requiresApproval
    case .notRegistered, .notFound:
      break
    @unknown default:
      break
    }

    if locateServiceExecutable() != nil {
      return .notRegistered
    }

    return .notFound
  }

  public func register() throws {
    do {
      try service.register()
      if service.status == .enabled || service.status == .requiresApproval {
        return
      }
    } catch {
      // Fall through to user LaunchAgent fallback
    }

    guard let executable = locateServiceExecutable() else {
      throw BridgeServiceRegistrationError.executableNotFound
    }

    try registerUserLaunchAgent(executableURL: executable)
  }

  public func unregister() async throws {
    try? await service.unregister()
    unregisterUserLaunchAgent()
  }

  public func openSystemSettings() {
    SMAppService.openSystemSettingsLoginItems()
  }

  private var userLaunchAgentPlistURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
      .appendingPathComponent(plistName, isDirectory: false)
  }

  private func locateServiceExecutable() -> URL? {
    if let bundled = Bundle.main.url(forResource: "CodexBridgeService", withExtension: nil),
      FileManager.default.isExecutableFile(atPath: bundled.path)
    {
      return bundled
    }
    if let resourceURL = Bundle.main.resourceURL {
      let candidate = resourceURL.appendingPathComponent("CodexBridgeService")
      if FileManager.default.isExecutableFile(atPath: candidate.path) {
        return candidate
      }
    }
    if let executable = Bundle.main.executableURL {
      let bundleRoot = executable.deletingLastPathComponent().deletingLastPathComponent()
      let candidate = bundleRoot.appendingPathComponent("Resources/CodexBridgeService")
      if FileManager.default.isExecutableFile(atPath: candidate.path) {
        return candidate
      }
    }
    return nil
  }

  private func isUserLaunchAgentActive() -> Bool {
    guard FileManager.default.fileExists(atPath: userLaunchAgentPlistURL.path) else {
      return false
    }
    let uid = getuid()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = ["print", "gui/\(uid)/\(machServiceName)"]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    do {
      try process.run()
      process.waitUntilExit()
      return process.terminationStatus == 0
    } catch {
      return false
    }
  }

  private func registerUserLaunchAgent(executableURL: URL) throws {
    let launchAgentsDir = userLaunchAgentPlistURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)

    let plistDict: [String: Any] = [
      "Label": machServiceName,
      "ProgramArguments": [executableURL.path],
      "MachServices": [
        machServiceName: true
      ],
      "RunAtLoad": true,
      "KeepAlive": true,
      "ProcessType": "Interactive",
    ]
    let data = try PropertyListSerialization.data(
      fromPropertyList: plistDict,
      format: .xml,
      options: 0
    )
    try data.write(to: userLaunchAgentPlistURL, options: .atomic)

    let uid = getuid()
    let bootstrap = Process()
    bootstrap.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    bootstrap.arguments = ["bootstrap", "gui/\(uid)", userLaunchAgentPlistURL.path]
    bootstrap.standardOutput = Pipe()
    bootstrap.standardError = Pipe()
    try? bootstrap.run()
    bootstrap.waitUntilExit()

    if bootstrap.terminationStatus != 0 {
      let load = Process()
      load.executableURL = URL(fileURLWithPath: "/bin/launchctl")
      load.arguments = ["load", "-w", userLaunchAgentPlistURL.path]
      load.standardOutput = Pipe()
      load.standardError = Pipe()
      try? load.run()
      load.waitUntilExit()
    }
  }

  private func unregisterUserLaunchAgent() {
    let uid = getuid()
    let bootout = Process()
    bootout.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    bootout.arguments = ["bootout", "gui/\(uid)/\(machServiceName)"]
    bootout.standardOutput = Pipe()
    bootout.standardError = Pipe()
    try? bootout.run()
    bootout.waitUntilExit()

    if bootout.terminationStatus != 0 {
      let unload = Process()
      unload.executableURL = URL(fileURLWithPath: "/bin/launchctl")
      unload.arguments = ["unload", userLaunchAgentPlistURL.path]
      unload.standardOutput = Pipe()
      unload.standardError = Pipe()
      try? unload.run()
      unload.waitUntilExit()
    }

    try? FileManager.default.removeItem(at: userLaunchAgentPlistURL)
  }
}
