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

  public func updateMCP(state: String, degradation: String? = nil) {
    snapshot = replacing(
      mcpState: state,
      tunnelState: snapshot.tunnelState,
      degradationPrefix: "MCP:",
      degradation: degradation
    )
  }

  public func updateTunnel(state: String, degradation: String? = nil) {
    snapshot = replacing(
      mcpState: snapshot.mcpState,
      tunnelState: state,
      degradationPrefix: "Tunnel:",
      degradation: degradation
    )
  }

  private func replacing(
    mcpState: String,
    tunnelState: String,
    degradationPrefix: String,
    degradation: String?
  ) -> ServiceRuntimeStatusSnapshot {
    var degradations = snapshot.degradations.filter {
      !$0.hasPrefix(degradationPrefix)
    }
    if let degradation {
      degradations.append("\(degradationPrefix) \(degradation)")
    }
    return ServiceRuntimeStatusSnapshot(
      mcpState: mcpState,
      tunnelState: tunnelState,
      codexVersion: snapshot.codexVersion,
      loginMode: snapshot.loginMode,
      degradations: degradations
    )
  }
}
