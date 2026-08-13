import BridgeTunnel
import Foundation

actor LocalOnlyTransport: ChatGPTBridgeTransport {
  private let mcp: any DesktopMCPServing
  private let authentication: DesktopMCPAuthentication
  private var localMCPURL: URL?

  init(mcp: any DesktopMCPServing, authentication: DesktopMCPAuthentication) {
    self.mcp = mcp
    self.authentication = authentication
  }

  func start() async throws {
    localMCPURL = try await mcp.start(authentication: authentication)
  }

  func stop() async {
    localMCPURL = nil
    await mcp.stop()
  }

  func testConnection() async throws {
    guard localMCPURL != nil else { throw DesktopTransportError.notStarted }
    try await mcp.testConnection()
  }

  func health() -> DesktopTransportHealth {
    DesktopTransportHealth(
      lifecycle: localMCPURL == nil ? .stopped : .ready,
      acceptsRemoteSubmissions: false,
      endpointDescription: "仅本机开发",
      localMCPURL: localMCPURL,
      actionRequired: false
    )
  }
}
