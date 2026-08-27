import BridgeACP
import BridgeAgentCore
import Foundation

public enum DeepSeekHarnessACPConstants {
  public static let providerID = AgentProviderID.deepSeekHarness
  public static let releaseVersion = "0.1.1-rc.2"
  public static let rootManifestVersion = "0.1.1-rc.2"
  public static let agentName = "deepseek-harness-acp"
  public static let agentVersion = "0.0.1"
  public static let acpProtocolVersion = 1
  public static let agentProtocolVersion = "0.0.1"
  public static let nodeRequirement = "^22.19.0 || >=24.0.0"
  public static let pnpmVersion = "11.7.0"
  public static let acpSDKVersion = "0.25.1"

  public static let maximumFrameBytes = 1_048_576
  public static let maximumStandardErrorBytes = 256 * 1_024
  public static let maximumFinalTextBytes = 256 * 1_024
  public static let maximumEventBuffer = 256
  public static let requestTimeout: Duration = .seconds(30)
  public static let inactivityTimeout: Duration = .seconds(10 * 60)
  public static let maximumProcessLifetime: Duration = .seconds(24 * 60 * 60)
}

public enum DeepSeekHarnessACPProfiles {
  public static let controlledReadOnly = AgentProfileID(rawValue: "controlled-readonly")
}

public enum DeepSeekHarnessACPError: Error, Equatable, Sendable {
  case notInitialized
  case operationInProgress
  case invalidMessage
  case malformedResponse
  case remote(code: Int, message: String)
  case requestTimedOut
  case transportClosed
  case processExited(Int32?)
  case oversizedFrame
  case sessionMismatch
  case unsupportedProtocol(Int)
  case unexpectedAgent
  case unsupportedStopReason(String)
  case missingRejectOnce
  case malformedPermission
  case artifactInvalid(String)
  case templateMismatch
  case nodeVersionIncompatible(String)
  case processUnavailable
  case inactivityTimeout
}

public struct DeepSeekHarnessACPClientInfo: Equatable, Sendable {
  public let name: String
  public let title: String
  public let version: String

  public init(name: String, title: String, version: String) {
    self.name = name
    self.title = title
    self.version = version
  }
}

public struct DeepSeekHarnessACPInitialization: Equatable, Sendable {
  public let protocolVersion: Int
  public let agentName: String?
  public let agentTitle: String?
  public let agentVersion: String?

  public init(
    protocolVersion: Int,
    agentName: String?,
    agentTitle: String?,
    agentVersion: String?
  ) {
    self.protocolVersion = protocolVersion
    self.agentName = agentName
    self.agentTitle = agentTitle
    self.agentVersion = agentVersion
  }
}

public struct DeepSeekHarnessACPSession: Equatable, Sendable {
  public let id: String

  public init(id: String) {
    self.id = id
  }
}

public struct DeepSeekHarnessACPPromptResult: Equatable, Sendable {
  public let stopReason: String
  public let eventSequenceBarrier: Int64

  public init(stopReason: String, eventSequenceBarrier: Int64) {
    self.stopReason = stopReason
    self.eventSequenceBarrier = eventSequenceBarrier
  }
}

public enum DeepSeekHarnessACPClientEvent: Equatable, Sendable {
  case textDelta(sessionID: String, text: String)
  case approvalAutomaticallyDenied(sessionID: String, toolCallID: String)
}

public struct DeepSeekHarnessACPClientEventEnvelope: Equatable, Sendable {
  public let sequence: Int64
  public let event: DeepSeekHarnessACPClientEvent

  public init(sequence: Int64, event: DeepSeekHarnessACPClientEvent) {
    self.sequence = sequence
    self.event = event
  }
}

public struct DeepSeekHarnessACPValidatedInstallation: Equatable, Sendable {
  public let installation: AgentInstallation
  public let nodeInterpreterPath: String
  public let executablePath: String
  public let configurationPath: String
  public let configurationData: Data
  public let sourceRoot: String
  public let nodeVersion: String

  public init(
    installation: AgentInstallation,
    nodeInterpreterPath: String,
    executablePath: String,
    configurationPath: String,
    configurationData: Data,
    sourceRoot: String,
    nodeVersion: String
  ) {
    self.installation = installation
    self.nodeInterpreterPath = nodeInterpreterPath
    self.executablePath = executablePath
    self.configurationPath = configurationPath
    self.configurationData = configurationData
    self.sourceRoot = sourceRoot
    self.nodeVersion = nodeVersion
  }
}

public struct DeepSeekHarnessACPLaunchConfiguration: Sendable {
  public let process: ACPProcessTransportConfiguration
  public let runDirectory: String
  public let resolvedNodeInterpreterPath: String
  public let resolvedExecutablePath: String
  public let resolvedConfigurationPath: String

  public init(
    process: ACPProcessTransportConfiguration,
    runDirectory: String,
    resolvedNodeInterpreterPath: String,
    resolvedExecutablePath: String,
    resolvedConfigurationPath: String
  ) {
    self.process = process
    self.runDirectory = runDirectory
    self.resolvedNodeInterpreterPath = resolvedNodeInterpreterPath
    self.resolvedExecutablePath = resolvedExecutablePath
    self.resolvedConfigurationPath = resolvedConfigurationPath
  }
}

public typealias DeepSeekHarnessACPTransportFactory =
  @Sendable (
    DeepSeekHarnessACPLaunchConfiguration
  ) throws -> any ACPTransport
