import BridgeACP
import BridgeAgentCore
import Foundation

public struct DeepSeekHarnessACPProviderConfiguration: Sendable {
  public let clientInfo: DeepSeekHarnessACPClientInfo
  public let launchBuilder: DeepSeekHarnessACPLaunchBuilder
  public let requestTimeout: Duration
  public let inactivityTimeout: Duration
  public let eventBufferLimit: Int
  public let runtimeBaseDirectory: String
  public let sourceEnvironment: [String: String]
  public let transportFactory: DeepSeekHarnessACPTransportFactory

  public init(
    clientInfo: DeepSeekHarnessACPClientInfo = .init(
      name: "codex-bridge",
      title: "Codex Bridge",
      version: "1"
    ),
    launchBuilder: DeepSeekHarnessACPLaunchBuilder? = nil,
    requestTimeout: Duration = DeepSeekHarnessACPConstants.requestTimeout,
    inactivityTimeout: Duration = DeepSeekHarnessACPConstants.inactivityTimeout,
    eventBufferLimit: Int = DeepSeekHarnessACPConstants.maximumEventBuffer,
    runtimeBaseDirectory: String = FileManager.default.temporaryDirectory
      .appendingPathComponent("CodexBridge/DeepSeekHarnessACP", isDirectory: true).path,
    sourceEnvironment: [String: String] = ProcessInfo.processInfo.environment,
    transportFactory: @escaping DeepSeekHarnessACPTransportFactory = { launch in
      try ACPProcessTransport.launch(configuration: launch.process)
    }
  ) throws {
    self.clientInfo = clientInfo
    self.launchBuilder = try launchBuilder ?? DeepSeekHarnessACPLaunchBuilder()
    self.requestTimeout = requestTimeout
    self.inactivityTimeout = inactivityTimeout
    self.eventBufferLimit = max(1, eventBufferLimit)
    self.runtimeBaseDirectory = runtimeBaseDirectory
    self.sourceEnvironment = sourceEnvironment
    self.transportFactory = transportFactory
  }
}

public struct DeepSeekHarnessACPProvider: AgentProvider, Sendable {
  public let descriptor: AgentProviderDescriptor

  let configuration: DeepSeekHarnessACPProviderConfiguration

  public init(configuration: DeepSeekHarnessACPProviderConfiguration? = nil) throws {
    self.configuration = try configuration ?? DeepSeekHarnessACPProviderConfiguration()
    descriptor = try AgentProviderDescriptor(
      providerID: .deepSeekHarness,
      displayName: "DeepSeek Harness",
      adapterRevision: 5
    )
  }

  func makeClient(transport: any ACPTransport) -> DeepSeekHarnessACPClient {
    DeepSeekHarnessACPClient(
      transport: transport,
      clientInfo: configuration.clientInfo,
      requestTimeout: configuration.requestTimeout,
      eventBufferLimit: configuration.eventBufferLimit
    )
  }

  func validate(_ initialization: DeepSeekHarnessACPInitialization) throws {
    guard initialization.protocolVersion == DeepSeekHarnessACPConstants.acpProtocolVersion else {
      throw AgentRuntimeError.unsupportedProtocol(String(initialization.protocolVersion))
    }
    guard initialization.agentName != nil || initialization.agentVersion != nil else { return }
    guard initialization.agentName == DeepSeekHarnessACPConstants.agentName,
      initialization.agentVersion == DeepSeekHarnessACPConstants.agentVersion
    else {
      throw AgentRuntimeError.unsupportedProtocol("unexpected_deepseek_harness_identity")
    }
  }
}
