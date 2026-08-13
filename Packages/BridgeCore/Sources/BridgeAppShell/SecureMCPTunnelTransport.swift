import BridgeSecurity
import BridgeTunnel
import Foundation

actor SecureMCPTunnelTransport: ChatGPTBridgeTransport {
  private let mcp: any DesktopMCPServing
  private let tunnelFactory: any DesktopTunnelManagerBuilding
  private let tunnelID: TunnelID
  private let runtimeKeyReference: SecretReference
  private let localMCPHeaderSecret: String
  private var localMCPURL: URL?
  private var tunnel: (any DesktopTunnelManaging)?
  private var failed = false

  init(
    mcp: any DesktopMCPServing,
    tunnelFactory: any DesktopTunnelManagerBuilding,
    tunnelID: TunnelID,
    runtimeKeyReference: SecretReference,
    localMCPHeaderSecret: String
  ) {
    self.mcp = mcp
    self.tunnelFactory = tunnelFactory
    self.tunnelID = tunnelID
    self.runtimeKeyReference = runtimeKeyReference
    self.localMCPHeaderSecret = localMCPHeaderSecret
  }

  func start() async throws {
    failed = false
    do {
      let url = try await mcp.start(authentication: .header(secret: localMCPHeaderSecret))
      try await mcp.testConnection()
      let tunnel = try await tunnelFactory.make(
        tunnelID: tunnelID,
        runtimeKeyReference: runtimeKeyReference,
        localMCPURL: url,
        localMCPHeaderSecret: localMCPHeaderSecret
      )
      self.tunnel = tunnel
      localMCPURL = url
      try await tunnel.start()
    } catch {
      failed = true
      await tunnel?.stop()
      tunnel = nil
      localMCPURL = nil
      await mcp.stop()
      throw error
    }
  }

  func stop() async {
    let tunnel = tunnel
    self.tunnel = nil
    localMCPURL = nil
    failed = false
    await tunnel?.stop()
    await mcp.stop()
  }

  func testConnection() async throws {
    guard let tunnel, localMCPURL != nil else { throw DesktopTransportError.notStarted }
    try await mcp.testConnection()
    guard await tunnel.acceptsRemoteSubmissions() else {
      throw DesktopTransportError.connectionFailed
    }
  }

  func health() async -> DesktopTransportHealth {
    guard let tunnel else {
      return DesktopTransportHealth(
        lifecycle: failed ? .failed : .stopped,
        acceptsRemoteSubmissions: false,
        endpointDescription: "OpenAI Secure MCP Tunnel",
        localMCPURL: localMCPURL,
        actionRequired: failed
      )
    }
    let lifecycle = await tunnel.state()
    let diagnostics = await tunnel.diagnostics()
    return DesktopTransportHealth(
      lifecycle: lifecycle,
      acceptsRemoteSubmissions: await tunnel.acceptsRemoteSubmissions(),
      endpointDescription: "OpenAI Secure MCP Tunnel",
      localMCPURL: localMCPURL,
      actionRequired: diagnostics.actionRequired
    )
  }
}
