import Foundation

public struct ServiceRuntimeStatusSnapshot: Equatable, Sendable {
  public let mcpState: String
  public let tunnelState: String
  public let codexVersion: String?
  public let loginMode: String?
  public let degradations: [String]

  public init(
    mcpState: String = "stopped",
    tunnelState: String = "stopped",
    codexVersion: String? = nil,
    loginMode: String? = nil,
    degradations: [String] = []
  ) {
    self.mcpState = mcpState
    self.tunnelState = tunnelState
    self.codexVersion = codexVersion
    self.loginMode = loginMode
    self.degradations = degradations
  }
}

public actor ServiceRuntimeStatus {
  private var snapshot: ServiceRuntimeStatusSnapshot

  public init(initial: ServiceRuntimeStatusSnapshot = .init()) {
    snapshot = initial
  }

  public func current() -> ServiceRuntimeStatusSnapshot {
    snapshot
  }

  public func update(_ snapshot: ServiceRuntimeStatusSnapshot) {
    self.snapshot = snapshot
  }
}
