import BridgeAgentCore
import Foundation

public typealias OpenCodeACPTransportFactory =
  @Sendable (
    OpenCodeACPLaunchConfiguration
  ) throws -> any OpenCodeACPTransport

public struct OpenCodeACPProviderConfiguration: Sendable {
  public let clientInfo: OpenCodeACPClientInfo
  public let compatibility: OpenCodeACPCompatibility
  public let launchBuilder: OpenCodeACPLaunchBuilder
  public let requestTimeout: Duration
  public let inactivityTimeout: Duration
  public let eventBufferLimit: Int
  public let runtimeBaseDirectory: String
  public let persistentStateBaseDirectory: String?
  public let sourceEnvironment: [String: String]
  public let transportFactory: OpenCodeACPTransportFactory

  public init(
    clientInfo: OpenCodeACPClientInfo = .init(
      name: "codex-bridge",
      title: "Codex Bridge",
      version: "1"
    ),
    compatibility: OpenCodeACPCompatibility = .init(),
    launchBuilder: OpenCodeACPLaunchBuilder = .init(),
    requestTimeout: Duration = .seconds(30),
    inactivityTimeout: Duration = .seconds(10 * 60),
    eventBufferLimit: Int = 256,
    runtimeBaseDirectory: String = FileManager.default.temporaryDirectory
      .appendingPathComponent("CodexBridge/OpenCodeACP", isDirectory: true).path,
    persistentStateBaseDirectory: String? = nil,
    sourceEnvironment: [String: String] = ProcessInfo.processInfo.environment,
    transportFactory: @escaping OpenCodeACPTransportFactory = { launch in
      try OpenCodeACPProcessTransport.launch(configuration: launch.process)
    }
  ) {
    self.clientInfo = clientInfo
    self.compatibility = compatibility
    self.launchBuilder = launchBuilder
    self.requestTimeout = requestTimeout
    self.inactivityTimeout = inactivityTimeout
    self.eventBufferLimit = max(1, eventBufferLimit)
    self.runtimeBaseDirectory = runtimeBaseDirectory
    self.persistentStateBaseDirectory = persistentStateBaseDirectory
    self.sourceEnvironment = sourceEnvironment
    self.transportFactory = transportFactory
  }
}

public struct OpenCodeACPProvider: AgentProvider, Sendable {
  public let descriptor: AgentProviderDescriptor

  let configuration: OpenCodeACPProviderConfiguration

  public init(configuration: OpenCodeACPProviderConfiguration = .init()) throws {
    self.configuration = configuration
    descriptor = try AgentProviderDescriptor(
      providerID: .openCode,
      displayName: "OpenCode",
      adapterRevision: 1
    )
  }
}
