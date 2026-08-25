import Darwin
import Foundation

public struct DirectExecutionEnvironmentCapabilities: Equatable, Sendable {
  public let bridgeSandbox: String
  public let sandboxExec: String
  public let nestedSandbox: String
  public let loopback: String
  public let limitations: [String]

  public init(
    bridgeSandbox: String,
    sandboxExec: String,
    nestedSandbox: String,
    loopback: String,
    limitations: [String] = []
  ) {
    self.bridgeSandbox = bridgeSandbox
    self.sandboxExec = sandboxExec
    self.nestedSandbox = nestedSandbox
    self.loopback = loopback
    self.limitations = limitations
  }

  public static func current() -> DirectExecutionEnvironmentCapabilities {
    let sandboxExec = probeSandboxExec()
    let nestedSandbox = probeNestedSandbox(sandboxExec: sandboxExec)
    let loopback = probeLoopbackBind() ? "available" : "unsupported"
    var limitations: [String] = []
    if sandboxExec != "available" { limitations.append("sandbox_exec") }
    if nestedSandbox != "available" { limitations.append("nested_sandbox") }
    if loopback == "unsupported" { limitations.append("loopback") }
    return DirectExecutionEnvironmentCapabilities(
      bridgeSandbox: ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil
        ? "unknown" : "detected",
      sandboxExec: sandboxExec,
      nestedSandbox: nestedSandbox,
      loopback: loopback,
      limitations: limitations
    )
  }

  public func commandEnvironment(denyNetwork: Bool) -> DirectCommandExecutionEnvironment {
    let nested = denyNetwork ? "restricted" : nestedSandbox
    let reportedLoopback = denyNetwork ? "restricted" : loopback
    let xcodebuildNestedSandbox: String
    if denyNetwork || nestedSandbox == "unsupported" {
      xcodebuildNestedSandbox = "unavailable"
    } else {
      xcodebuildNestedSandbox = "unknown"
    }
    let loopbackBind =
      denyNetwork ? "unavailable" : (loopback == "available" ? "available" : "unavailable")
    var commandLimitations = limitations
    if denyNetwork {
      commandLimitations.append(contentsOf: [
        "nested_sandbox_restricted_by_child_network_policy",
        "xcodebuild_nested_sandbox_unavailable",
        "loopback_bind_unavailable",
      ])
    }
    return DirectCommandExecutionEnvironment(
      bridgeSandbox: bridgeSandbox,
      sandboxExec: sandboxExec,
      nestedSandbox: nested,
      loopback: reportedLoopback,
      childNetworkPolicy: denyNetwork ? "denied" : "inherited",
      xcodebuildNestedSandbox: xcodebuildNestedSandbox,
      loopbackBind: loopbackBind,
      limitations: Array(Set(commandLimitations)).sorted()
    )
  }

  private static func probeSandboxExec() -> String {
    guard FileManager.default.isExecutableFile(atPath: sandboxExecPath) else {
      return "unavailable"
    }
    return runSandboxProbe([
      "-p", "(version 1)(allow default)", "--", "/usr/bin/true",
    ])
  }

  private static func probeNestedSandbox(sandboxExec: String) -> String {
    guard sandboxExec == "available" else { return "unavailable" }
    return runSandboxProbe([
      "-p", "(version 1)(allow default)", "--",
      sandboxExecPath, "-p", "(version 1)(allow default)", "--", "/usr/bin/true",
    ])
  }

  private static func runSandboxProbe(_ arguments: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: sandboxExecPath)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    do {
      try process.run()
      process.waitUntilExit()
      return process.terminationReason == .exit && process.terminationStatus == 0
        ? "available" : "restricted"
    } catch {
      return "unknown"
    }
  }

  private static func probeLoopbackBind() -> Bool {
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return false }
    defer { Darwin.close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    return withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
      }
    }
  }

  private static let sandboxExecPath = "/usr/bin/sandbox-exec"
}

public struct DirectCommandExecutionEnvironment: Equatable, Sendable {
  public let bridgeSandbox: String
  public let sandboxExec: String
  public let nestedSandbox: String
  public let loopback: String
  public let childNetworkPolicy: String
  public let xcodebuildNestedSandbox: String
  public let loopbackBind: String
  public let limitations: [String]

  public init(
    bridgeSandbox: String,
    sandboxExec: String,
    nestedSandbox: String,
    loopback: String,
    childNetworkPolicy: String,
    xcodebuildNestedSandbox: String = "unknown",
    loopbackBind: String = "unknown",
    limitations: [String] = []
  ) {
    self.bridgeSandbox = bridgeSandbox
    self.sandboxExec = sandboxExec
    self.nestedSandbox = nestedSandbox
    self.loopback = loopback
    self.childNetworkPolicy = childNetworkPolicy
    self.xcodebuildNestedSandbox = xcodebuildNestedSandbox
    self.loopbackBind = loopbackBind
    self.limitations = limitations
  }
}
