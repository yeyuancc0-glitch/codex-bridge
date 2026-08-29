import BridgeAgentCore
import Foundation

public struct AntigravityCLIProviderConfiguration: Sendable {
  public let compatibility: AntigravityCLICompatibility
  public let launchBuilder: AntigravityCLILaunchBuilder
  public let commandRunner: any AntigravityCLICommandRunning
  public let requestTimeout: Duration
  public let inactivityTimeout: Duration
  public let eventBufferLimit: Int
  public let runtimeBaseDirectory: String
  public let sourceEnvironment: [String: String]
  public let transportFactory: AntigravityCLITransportFactory

  public init(
    compatibility: AntigravityCLICompatibility = .init(),
    launchBuilder: AntigravityCLILaunchBuilder = .init(),
    commandRunner: any AntigravityCLICommandRunning = AntigravityCLICommandRunner(),
    requestTimeout: Duration = .seconds(30),
    inactivityTimeout: Duration = .seconds(10 * 60),
    eventBufferLimit: Int = 256,
    runtimeBaseDirectory: String = FileManager.default.temporaryDirectory
      .appendingPathComponent("CodexBridge/AntigravityCLI", isDirectory: true).path,
    sourceEnvironment: [String: String] = ProcessInfo.processInfo.environment,
    transportFactory: @escaping AntigravityCLITransportFactory = { launch in
      try AntigravityCLIProcessTransport.launch(configuration: launch.process)
    }
  ) {
    self.compatibility = compatibility
    self.launchBuilder = launchBuilder
    self.commandRunner = commandRunner
    self.requestTimeout = requestTimeout
    self.inactivityTimeout = inactivityTimeout
    self.eventBufferLimit = max(1, eventBufferLimit)
    self.runtimeBaseDirectory = runtimeBaseDirectory
    self.sourceEnvironment = sourceEnvironment
    self.transportFactory = transportFactory
  }
}

public struct AntigravityCLIProvider: AgentProvider, Sendable {
  public let descriptor: AgentProviderDescriptor

  let configuration: AntigravityCLIProviderConfiguration

  public init(configuration: AntigravityCLIProviderConfiguration = .init()) throws {
    self.configuration = configuration
    descriptor = try AgentProviderDescriptor(
      providerID: .antigravity,
      displayName: "Antigravity CLI",
      adapterRevision: 3
    )
  }
}
