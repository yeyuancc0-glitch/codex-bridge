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
    let sandboxExec = FileManager.default.isExecutableFile(atPath: sandboxExecPath)
    let nestedSandbox = probeNestedSandbox(sandboxExecAvailable: sandboxExec)
    let loopback = probeLoopbackBind() ? "available" : "unsupported"
    var limitations: [String] = []
    if nestedSandbox == "unsupported" { limitations.append("nested_sandbox") }
    if loopback == "unsupported" { limitations.append("loopback") }
    return DirectExecutionEnvironmentCapabilities(
      bridgeSandbox: ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil
        ? "unknown" : "detected",
      sandboxExec: sandboxExec ? "available" : "unavailable",
      nestedSandbox: nestedSandbox,
      loopback: loopback,
      limitations: limitations
    )
  }

  public func commandEnvironment(denyNetwork: Bool) -> DirectCommandExecutionEnvironment {
    DirectCommandExecutionEnvironment(
      bridgeSandbox: bridgeSandbox,
      sandboxExec: sandboxExec,
      nestedSandbox: nestedSandbox,
      loopback: loopback,
      childNetworkPolicy: denyNetwork ? "denied" : "inherited",
      limitations: limitations
    )
  }

  private static func probeNestedSandbox(sandboxExecAvailable: Bool) -> String {
    guard sandboxExecAvailable else { return "unsupported" }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: sandboxExecPath)
    process.arguments = [
      "-p", "(version 1)(allow default)", "--",
      sandboxExecPath, "-p", "(version 1)(allow default)", "--", "/usr/bin/true",
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    do {
      try process.run()
      process.waitUntilExit()
      return process.terminationReason == .exit && process.terminationStatus == 0
        ? "available" : "unsupported"
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
  public let limitations: [String]

  public init(
    bridgeSandbox: String,
    sandboxExec: String,
    nestedSandbox: String,
    loopback: String,
    childNetworkPolicy: String,
    limitations: [String] = []
  ) {
    self.bridgeSandbox = bridgeSandbox
    self.sandboxExec = sandboxExec
    self.nestedSandbox = nestedSandbox
    self.loopback = loopback
    self.childNetworkPolicy = childNetworkPolicy
    self.limitations = limitations
  }
}
