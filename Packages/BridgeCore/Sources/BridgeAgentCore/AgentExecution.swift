import BridgeDomain
import Foundation

public enum AgentRuntimeError: Error, Equatable, Sendable {
  case invalidRequest(String)
  case providerUnavailable(AgentProviderID)
  case installationUnavailable(AgentInstallationID)
  case unsupportedProtocol(String)
  case capabilityUnavailable(AgentCapability)
  case modelUnavailable(String)
  case sessionMismatch
  case runMismatch
  case malformedEvent(String)
  case oversizedFrame
  case approvalUnavailable(String)
  case processUnavailable
  case processExited(Int32?)
  case timedOut
}

public struct AgentBinding: Codable, Equatable, Hashable, Sendable {
  public let providerID: AgentProviderID
  public let installationID: AgentInstallationID
  public let providerSessionID: String?
  public let providerRunID: String?

  public init(
    providerID: AgentProviderID,
    installationID: AgentInstallationID,
    providerSessionID: String? = nil,
    providerRunID: String? = nil
  ) throws {
    try AgentValidation.identifier(
      providerID.rawValue, field: "binding.providerID", maximumBytes: 128)
    try AgentValidation.identifier(
      installationID.rawValue,
      field: "binding.installationID",
      maximumBytes: 256
    )
    try AgentValidation.optionalIdentifier(
      providerSessionID,
      field: "binding.providerSessionID",
      maximumBytes: 1_024
    )
    try AgentValidation.optionalIdentifier(
      providerRunID,
      field: "binding.providerRunID",
      maximumBytes: 1_024
    )
    self.providerID = providerID
    self.installationID = installationID
    self.providerSessionID = providerSessionID
    self.providerRunID = providerRunID
  }
}

public struct AgentExecutionRequest: Equatable, Sendable {
  public let taskID: TaskID
  public let projectID: ProjectID
  public let projectRoot: String
  public let prompt: String
  public let requestedSessionID: String?
  public let model: String?
  public let effort: String?
  public let profileID: AgentProfileID?
  public let mutationIntent: AgentMutationIntent
  public let workspaceStrategy: AgentWorkspaceStrategy
  public let networkAccessRequested: Bool
  public let toolApprovalPolicy: AgentToolApprovalPolicy
  public let requiredCapabilities: Set<AgentCapability>

  public init(
    taskID: TaskID,
    projectID: ProjectID,
    projectRoot: String,
    prompt: String,
    requestedSessionID: String? = nil,
    model: String? = nil,
    effort: String? = nil,
    profileID: AgentProfileID? = nil,
    mutationIntent: AgentMutationIntent,
    workspaceStrategy: AgentWorkspaceStrategy,
    networkAccessRequested: Bool,
    toolApprovalPolicy: AgentToolApprovalPolicy = .providerManaged,
    requiredCapabilities: Set<AgentCapability> = []
  ) throws {
    try AgentValidation.identifier(taskID.rawValue, field: "request.taskID", maximumBytes: 128)
    try AgentValidation.identifier(
      projectID.rawValue, field: "request.projectID", maximumBytes: 128)
    try AgentValidation.absolutePath(projectRoot, field: "request.projectRoot")
    try AgentValidation.text(prompt, field: "request.prompt", maximumBytes: 32 * 1_024)
    try AgentValidation.optionalIdentifier(
      requestedSessionID,
      field: "request.requestedSessionID",
      maximumBytes: 1_024
    )
    try AgentValidation.optionalIdentifier(model, field: "request.model", maximumBytes: 256)
    try AgentValidation.optionalIdentifier(effort, field: "request.effort", maximumBytes: 64)
    if let profileID {
      try AgentValidation.identifier(
        profileID.rawValue,
        field: "request.profileID",
        maximumBytes: 256
      )
    }
    guard toolApprovalPolicy != .autoApprove || networkAccessRequested else {
      throw AgentRuntimeError.invalidRequest("request.toolApprovalPolicy")
    }
    self.taskID = taskID
    self.projectID = projectID
    self.projectRoot = projectRoot
    self.prompt = prompt
    self.requestedSessionID = requestedSessionID
    self.model = model
    self.effort = effort
    self.profileID = profileID
    self.mutationIntent = mutationIntent
    self.workspaceStrategy = workspaceStrategy
    self.networkAccessRequested = networkAccessRequested
    self.toolApprovalPolicy = toolApprovalPolicy
    self.requiredCapabilities = requiredCapabilities
  }
}

public enum AgentContentRole: String, Codable, Sendable {
  case user
  case assistant
}

public enum AgentContentKind: String, Codable, Sendable {
  case message
  case reasoning
}

public enum AgentContentMode: String, Codable, Sendable {
  case delta
  case full
}

public struct AgentContentUpdate: Codable, Equatable, Sendable {
  public let key: String
  public let role: AgentContentRole
  public let kind: AgentContentKind
  public let mode: AgentContentMode
  public let content: String
  public let baseContentLength: Int?
  public let isFinal: Bool
  public let authoritative: Bool

  public init(
    key: String,
    role: AgentContentRole,
    kind: AgentContentKind,
    mode: AgentContentMode,
    content: String,
    baseContentLength: Int? = nil,
    isFinal: Bool = false,
    authoritative: Bool = false
  ) throws {
    try AgentValidation.identifier(key, field: "content.key", maximumBytes: 256)
    try AgentValidation.streamText(content, field: "content.content", maximumBytes: 256 * 1_024)
    if let baseContentLength, baseContentLength < 0 {
      throw AgentRuntimeError.invalidRequest("content.baseContentLength")
    }
    self.key = key
    self.role = role
    self.kind = kind
    self.mode = mode
    self.content = content
    self.baseContentLength = baseContentLength
    self.isFinal = isFinal
    self.authoritative = authoritative
  }
}

public enum AgentToolStatus: String, Codable, Sendable {
  case pending
  case inProgress = "in_progress"
  case completed
  case failed
  case cancelled
  case declined
}

public struct AgentToolUpdate: Codable, Equatable, Sendable {
  public let key: String
  public let name: String
  public let title: String?
  public let kind: String?
  public let status: AgentToolStatus
  public let arguments: String?
  public let output: String?
  public let locations: [String]

  public init(
    key: String,
    name: String,
    title: String? = nil,
    kind: String? = nil,
    status: AgentToolStatus,
    arguments: String? = nil,
    output: String? = nil,
    locations: [String] = []
  ) throws {
    try AgentValidation.identifier(key, field: "tool.key", maximumBytes: 256)
    try AgentValidation.text(name, field: "tool.name", maximumBytes: 256)
    try AgentValidation.optionalText(title, field: "tool.title", maximumBytes: 1_024)
    try AgentValidation.optionalIdentifier(kind, field: "tool.kind", maximumBytes: 128)
    try AgentValidation.optionalText(arguments, field: "tool.arguments", maximumBytes: 64 * 1_024)
    try AgentValidation.optionalText(output, field: "tool.output", maximumBytes: 256 * 1_024)
    guard locations.count <= 128 else {
      throw AgentRuntimeError.invalidRequest("tool.locations")
    }
    for location in locations {
      try AgentValidation.absolutePath(location, field: "tool.locations")
    }
    self.key = key
    self.name = name
    self.title = title
    self.kind = kind
    self.status = status
    self.arguments = arguments
    self.output = output
    self.locations = locations
  }
}

public struct AgentPlanEntry: Codable, Equatable, Sendable {
  public let content: String
  public let priority: String?
  public let status: String?

  public init(content: String, priority: String? = nil, status: String? = nil) throws {
    try AgentValidation.text(content, field: "plan.content", maximumBytes: 4 * 1_024)
    try AgentValidation.optionalIdentifier(priority, field: "plan.priority", maximumBytes: 64)
    try AgentValidation.optionalIdentifier(status, field: "plan.status", maximumBytes: 64)
    self.content = content
    self.priority = priority
    self.status = status
  }
}

public struct AgentUsageUpdate: Codable, Equatable, Sendable {
  public let usedTokens: Int
  public let contextSize: Int
  public let costAmount: Double?
  public let currency: String?

  public init(usedTokens: Int, contextSize: Int, costAmount: Double?, currency: String?) throws {
    guard usedTokens >= 0, contextSize >= 0, usedTokens <= contextSize else {
      throw AgentRuntimeError.invalidRequest("usage.tokens")
    }
    guard (costAmount == nil) == (currency == nil) else {
      throw AgentRuntimeError.invalidRequest("usage.cost")
    }
    if let costAmount, !costAmount.isFinite || costAmount < 0 {
      throw AgentRuntimeError.invalidRequest("usage.costAmount")
    }
    try AgentValidation.optionalIdentifier(currency, field: "usage.currency", maximumBytes: 8)
    self.usedTokens = usedTokens
    self.contextSize = contextSize
    self.costAmount = costAmount
    self.currency = currency
  }
}

public enum AgentApprovalKind: String, Codable, Sendable {
  case command
  case fileChange = "file_change"
  case network
  case tool
  case unknown
}

public struct AgentApprovalOption: Codable, Equatable, Sendable {
  public let id: String
  public let name: String
  public let kind: String

  public init(id: String, name: String, kind: String) throws {
    try AgentValidation.identifier(id, field: "approvalOption.id", maximumBytes: 256)
    try AgentValidation.text(name, field: "approvalOption.name", maximumBytes: 512)
    try AgentValidation.identifier(kind, field: "approvalOption.kind", maximumBytes: 128)
    self.id = id
    self.name = name
    self.kind = kind
  }
}

public struct AgentApprovalRequest: Codable, Equatable, Sendable {
  public let approvalID: String
  public let taskID: TaskID
  public let binding: AgentBinding
  public let providerItemID: String
  public let kind: AgentApprovalKind
  public let title: String
  public let normalizedPayloadDigest: String?
  public let relativePaths: [String]
  public let normalizedCommand: String?
  public let networkTarget: String?
  public let options: [AgentApprovalOption]

  public init(
    approvalID: String,
    taskID: TaskID,
    binding: AgentBinding,
    providerItemID: String,
    kind: AgentApprovalKind,
    title: String,
    normalizedPayloadDigest: String? = nil,
    relativePaths: [String] = [],
    normalizedCommand: String? = nil,
    networkTarget: String? = nil,
    options: [AgentApprovalOption]
  ) throws {
    try AgentValidation.identifier(approvalID, field: "approval.id", maximumBytes: 256)
    try AgentValidation.identifier(providerItemID, field: "approval.itemID", maximumBytes: 256)
    try AgentValidation.text(title, field: "approval.title", maximumBytes: 1_024)
    try AgentValidation.optionalIdentifier(
      normalizedPayloadDigest,
      field: "approval.payloadDigest",
      maximumBytes: 128
    )
    try AgentValidation.optionalText(
      normalizedCommand,
      field: "approval.command",
      maximumBytes: 8 * 1_024
    )
    try AgentValidation.optionalText(
      networkTarget,
      field: "approval.networkTarget",
      maximumBytes: 4 * 1_024
    )
    guard !options.isEmpty, options.count <= 16 else {
      throw AgentRuntimeError.invalidRequest("approval.options")
    }
    guard Set(options.map(\.id)).count == options.count else {
      throw AgentRuntimeError.invalidRequest("approval.options")
    }
    try AgentValidation.uniqueRelativePaths(relativePaths, field: "approval.relativePaths")
    self.approvalID = approvalID
    self.taskID = taskID
    self.binding = binding
    self.providerItemID = providerItemID
    self.kind = kind
    self.title = title
    self.normalizedPayloadDigest = normalizedPayloadDigest
    self.relativePaths = relativePaths
    self.normalizedCommand = normalizedCommand
    self.networkTarget = networkTarget
    self.options = options
  }
}

public enum AgentEvent: Equatable, Sendable {
  case content(AgentContentUpdate)
  case tool(AgentToolUpdate)
  case plan([AgentPlanEntry])
  case usage(AgentUsageUpdate)
  case approvalRequested(AgentApprovalRequest)
  case approvalAutomaticallyDenied(String)
  case completed(summary: String, stopReason: String?)
  case interrupted
  case failed(code: String, summary: String)
}

public struct AgentEventEnvelope: Equatable, Sendable {
  public let taskID: TaskID
  public let providerID: AgentProviderID
  public let providerSessionID: String?
  public let providerRunID: String?
  public let providerSequence: Int64
  public let event: AgentEvent

  public init(
    taskID: TaskID,
    providerID: AgentProviderID,
    providerSessionID: String?,
    providerRunID: String?,
    providerSequence: Int64,
    event: AgentEvent
  ) throws {
    guard providerSequence >= 0 else {
      throw AgentRuntimeError.invalidRequest("event.providerSequence")
    }
    self.taskID = taskID
    self.providerID = providerID
    self.providerSessionID = providerSessionID
    self.providerRunID = providerRunID
    self.providerSequence = providerSequence
    self.event = event
  }
}

public struct AgentExecutionControl: Sendable {
  public let interrupt: @Sendable () async throws -> Void
  public let shutdown: (@Sendable () async -> Void)?
  public let steer: (@Sendable (String) async throws -> Void)?
  public let interruptAndSteer: (@Sendable (String) async throws -> Void)?
  public let resolveApproval: (@Sendable (String, String) async throws -> Void)?

  public init(
    interrupt: @escaping @Sendable () async throws -> Void,
    shutdown: (@Sendable () async -> Void)? = nil,
    steer: (@Sendable (String) async throws -> Void)? = nil,
    interruptAndSteer: (@Sendable (String) async throws -> Void)? = nil,
    resolveApproval: (@Sendable (String, String) async throws -> Void)? = nil
  ) {
    self.interrupt = interrupt
    self.shutdown = shutdown
    self.steer = steer
    self.interruptAndSteer = interruptAndSteer
    self.resolveApproval = resolveApproval
  }
}

public struct AgentExecutionHandle: Sendable {
  public let taskID: TaskID
  public let binding: AgentBinding
  public let capabilities: AgentCapabilitySnapshot
  public let events: AsyncThrowingStream<AgentEventEnvelope, any Error>
  public let control: AgentExecutionControl

  public init(
    taskID: TaskID,
    binding: AgentBinding,
    capabilities: AgentCapabilitySnapshot,
    events: AsyncThrowingStream<AgentEventEnvelope, any Error>,
    control: AgentExecutionControl
  ) {
    self.taskID = taskID
    self.binding = binding
    self.capabilities = capabilities
    self.events = events
    self.control = control
  }
}

enum AgentValidation {
  static func identifier(_ value: String, field: String, maximumBytes: Int) throws {
    guard !value.isEmpty, value.utf8.count <= maximumBytes, !value.contains("\0") else {
      throw AgentRuntimeError.invalidRequest(field)
    }
  }

  static func optionalIdentifier(_ value: String?, field: String, maximumBytes: Int) throws {
    guard let value else { return }
    try identifier(value, field: field, maximumBytes: maximumBytes)
  }

  static func text(_ value: String, field: String, maximumBytes: Int) throws {
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      value.utf8.count <= maximumBytes,
      !value.contains("\0")
    else {
      throw AgentRuntimeError.invalidRequest(field)
    }
  }

  static func streamText(_ value: String, field: String, maximumBytes: Int) throws {
    guard value.utf8.count <= maximumBytes, !value.contains("\0") else {
      throw AgentRuntimeError.invalidRequest(field)
    }
  }

  static func optionalText(_ value: String?, field: String, maximumBytes: Int) throws {
    guard let value else { return }
    try streamText(value, field: field, maximumBytes: maximumBytes)
  }

  static func absolutePath(_ value: String, field: String) throws {
    guard value.hasPrefix("/"), value.utf8.count <= 16 * 1_024, !value.contains("\0") else {
      throw AgentRuntimeError.invalidRequest(field)
    }
  }

  static func uniqueRelativePaths(_ values: [String], field: String) throws {
    guard values.count <= 128, Set(values).count == values.count else {
      throw AgentRuntimeError.invalidRequest(field)
    }
    for value in values {
      guard !value.isEmpty, !value.hasPrefix("/"), value.utf8.count <= 1_024,
        !value.contains("\0")
      else {
        throw AgentRuntimeError.invalidRequest(field)
      }
      let components = value.split(separator: "/", omittingEmptySubsequences: false)
      guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
        throw AgentRuntimeError.invalidRequest(field)
      }
    }
  }
}
