import BridgeTunnel
import Foundation

actor ManualHTTPSTransport: ChatGPTBridgeTransport {
  private let mcp: any DesktopMCPServing
  private let remoteTester: any DesktopRemoteMCPTesting
  private let localAuthentication: DesktopMCPAuthentication
  private let endpoint: URL
  private let authorization: String
  private var localMCPURL: URL?
  private var lifecycle = TunnelLifecycle.stopped

  init(
    mcp: any DesktopMCPServing,
    remoteTester: any DesktopRemoteMCPTesting,
    localAuthentication: DesktopMCPAuthentication,
    endpoint: URL,
    authorization: String
  ) throws {
    guard Self.isValidEndpoint(endpoint) else {
      throw DesktopTransportError.invalidManualEndpoint
    }
    guard Self.isValidAuthorization(authorization) else {
      throw DesktopTransportError.invalidAuthorization
    }
    self.mcp = mcp
    self.remoteTester = remoteTester
    self.localAuthentication = localAuthentication
    self.endpoint = endpoint
    self.authorization = authorization
  }

  func start() async throws {
    lifecycle = .starting
    do {
      localMCPURL = try await mcp.start(authentication: localAuthentication)
      lifecycle = .connecting
    } catch {
      lifecycle = .failed
      await mcp.stop()
      throw error
    }
  }

  func stop() async {
    lifecycle = .stopped
    localMCPURL = nil
    await mcp.stop()
  }

  func testConnection() async throws {
    guard localMCPURL != nil else { throw DesktopTransportError.notStarted }
    do {
      try await mcp.testConnection()
      try await remoteTester.validate(endpoint: endpoint, authorization: authorization)
      lifecycle = .ready
    } catch {
      lifecycle = .failed
      throw error
    }
  }

  func health() -> DesktopTransportHealth {
    DesktopTransportHealth(
      lifecycle: lifecycle,
      acceptsRemoteSubmissions: lifecycle == .ready,
      endpointDescription: endpoint.absoluteString,
      localMCPURL: localMCPURL,
      actionRequired: lifecycle == .failed
    )
  }

  private static func isValidEndpoint(_ endpoint: URL) -> Bool {
    guard let components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
      return false
    }
    return components.scheme == "https"
      && components.host?.isEmpty == false
      && components.user == nil
      && components.password == nil
      && components.percentEncodedPath == "/mcp"
      && components.percentEncodedQuery == nil
      && components.fragment == nil
  }

  static func isValidAuthorization(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    return (16...4_096).contains(bytes.count)
      && value == value.trimmingCharacters(in: .whitespaces)
      && bytes.allSatisfy { (0x20...0x7e).contains($0) }
  }
}

struct DesktopRemoteMCPClient: DesktopRemoteMCPTesting {
  func validate(endpoint: URL, authorization: String) async throws {
    guard ManualHTTPSTransport.isValidAuthorization(authorization) else {
      throw DesktopTransportError.invalidAuthorization
    }
    try await DesktopMCPRuntime.validate(
      transport: DesktopBoundedHTTPTransport(
        endpoint: endpoint,
        authorization: authorization
      )
    )
  }
}
