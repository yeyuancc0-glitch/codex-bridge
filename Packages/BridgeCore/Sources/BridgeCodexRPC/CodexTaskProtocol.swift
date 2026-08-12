import Foundation

public struct ThreadSandboxMode: Codable, Equatable, Hashable, RawRepresentable, Sendable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    rawValue = try container.decode(String.self)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  public static let readOnly = ThreadSandboxMode(rawValue: "read-only")
  public static let workspaceWrite = ThreadSandboxMode(rawValue: "workspace-write")
  public static let dangerFullAccess = ThreadSandboxMode(rawValue: "danger-full-access")
}

public struct GranularApprovalPolicy: Codable, Equatable, Sendable {
  public let mcpElicitations: Bool
  public let rules: Bool
  public let sandboxApproval: Bool
  public let requestPermissions: Bool?
  public let skillApproval: Bool?

  public init(
    mcpElicitations: Bool,
    rules: Bool,
    sandboxApproval: Bool,
    requestPermissions: Bool? = nil,
    skillApproval: Bool? = nil
  ) {
    self.mcpElicitations = mcpElicitations
    self.rules = rules
    self.sandboxApproval = sandboxApproval
    self.requestPermissions = requestPermissions
    self.skillApproval = skillApproval
  }

  private enum CodingKeys: String, CodingKey {
    case mcpElicitations = "mcp_elicitations"
    case rules
    case sandboxApproval = "sandbox_approval"
    case requestPermissions = "request_permissions"
    case skillApproval = "skill_approval"
  }
}

public enum CodexApprovalPolicy: Codable, Equatable, Sendable {
  case named(String)
  case granular(GranularApprovalPolicy)

  public static let untrusted = CodexApprovalPolicy.named("untrusted")
  public static let onRequest = CodexApprovalPolicy.named("on-request")
  public static let never = CodexApprovalPolicy.named("never")

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let value = try? container.decode(String.self) {
      self = .named(value)
      return
    }
    let value = try container.decode(GranularEnvelope.self)
    self = .granular(value.granular)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .named(let value):
      try container.encode(value)
    case .granular(let value):
      try container.encode(GranularEnvelope(granular: value))
    }
  }

  private struct GranularEnvelope: Codable {
    let granular: GranularApprovalPolicy
  }
}

public struct CodexSandboxPolicy: Codable, Equatable, Sendable {
  public let type: String
  public let networkAccess: JSONValue?
  public let writableRoots: [String]?
  public let excludeSlashTmp: Bool?
  public let excludeTmpdirEnvVar: Bool?

  public init(
    type: String,
    networkAccess: JSONValue? = nil,
    writableRoots: [String]? = nil,
    excludeSlashTmp: Bool? = nil,
    excludeTmpdirEnvVar: Bool? = nil
  ) {
    self.type = type
    self.networkAccess = networkAccess
    self.writableRoots = writableRoots
    self.excludeSlashTmp = excludeSlashTmp
    self.excludeTmpdirEnvVar = excludeTmpdirEnvVar
  }

  public static func readOnly(networkAccess: Bool = false) -> CodexSandboxPolicy {
    CodexSandboxPolicy(
      type: "readOnly",
      networkAccess: .bool(networkAccess)
    )
  }

  public static func workspaceWrite(
    writableRoots: [String],
    networkAccess: Bool = false,
    excludeSlashTmp: Bool = false,
    excludeTmpdirEnvVar: Bool = false
  ) -> CodexSandboxPolicy {
    CodexSandboxPolicy(
      type: "workspaceWrite",
      networkAccess: .bool(networkAccess),
      writableRoots: writableRoots,
      excludeSlashTmp: excludeSlashTmp,
      excludeTmpdirEnvVar: excludeTmpdirEnvVar
    )
  }

  public static let dangerFullAccess = CodexSandboxPolicy(type: "dangerFullAccess")
}

public struct CodexTextInput: Codable, Equatable, Sendable {
  public let type: String
  public let text: String
  public let textElements: [JSONValue]

  public init(text: String) {
    type = "text"
    self.text = text
    textElements = []
  }

  private enum CodingKeys: String, CodingKey {
    case type
    case text
    case textElements = "text_elements"
  }
}

public struct ThreadStartParams: Codable, Equatable, Sendable {
  public let cwd: String
  public let sandbox: ThreadSandboxMode
  public let approvalPolicy: CodexApprovalPolicy
  public let ephemeral: Bool
  public let model: String?
  public let baseInstructions: String?
  public let developerInstructions: String?

  public init(
    cwd: String,
    sandbox: ThreadSandboxMode,
    approvalPolicy: CodexApprovalPolicy,
    ephemeral: Bool = true,
    model: String? = nil,
    baseInstructions: String? = nil,
    developerInstructions: String? = nil
  ) {
    self.cwd = cwd
    self.sandbox = sandbox
    self.approvalPolicy = approvalPolicy
    self.ephemeral = ephemeral
    self.model = model
    self.baseInstructions = baseInstructions
    self.developerInstructions = developerInstructions
  }
}

public struct ThreadReadParams: Codable, Equatable, Sendable {
  public let threadId: String
  public let includeTurns: Bool

  public init(threadId: String, includeTurns: Bool = false) {
    self.threadId = threadId
    self.includeTurns = includeTurns
  }
}

public enum ThreadListCwdFilter: Codable, Equatable, Sendable {
  case one(String)
  case anyOf([String])

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let value = try? container.decode(String.self) {
      self = .one(value)
      return
    }
    self = .anyOf(try container.decode([String].self))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .one(let value):
      try container.encode(value)
    case .anyOf(let values):
      try container.encode(values)
    }
  }
}

public struct ThreadListParams: Codable, Equatable, Sendable {
  public let cursor: String?
  public let limit: UInt32?
  public let sortKey: String?
  public let sortDirection: String?
  public let sourceKinds: [String]?
  public let modelProviders: [String]?
  public let archived: Bool?
  public let cwd: ThreadListCwdFilter?
  public let searchTerm: String?
  public let useStateDbOnly: Bool

  public init(
    cursor: String? = nil,
    limit: UInt32? = nil,
    sortKey: String? = nil,
    sortDirection: String? = nil,
    sourceKinds: [String]? = nil,
    modelProviders: [String]? = nil,
    archived: Bool? = nil,
    cwd: ThreadListCwdFilter? = nil,
    searchTerm: String? = nil,
    useStateDbOnly: Bool = true
  ) {
    self.cursor = cursor
    self.limit = limit
    self.sortKey = sortKey
    self.sortDirection = sortDirection
    self.sourceKinds = sourceKinds
    self.modelProviders = modelProviders
    self.archived = archived
    self.cwd = cwd
    self.searchTerm = searchTerm
    self.useStateDbOnly = useStateDbOnly
  }
}

public struct ThreadResumeParams: Codable, Equatable, Sendable {
  public let threadId: String
  public let cwd: String?
  public let sandbox: ThreadSandboxMode?
  public let approvalPolicy: CodexApprovalPolicy?
  public let approvalsReviewer: String?
  public let model: String?
  public let baseInstructions: String?
  public let developerInstructions: String?

  public init(
    threadId: String,
    cwd: String? = nil,
    sandbox: ThreadSandboxMode? = nil,
    approvalPolicy: CodexApprovalPolicy? = nil,
    approvalsReviewer: String? = nil,
    model: String? = nil,
    baseInstructions: String? = nil,
    developerInstructions: String? = nil
  ) {
    self.threadId = threadId
    self.cwd = cwd
    self.sandbox = sandbox
    self.approvalPolicy = approvalPolicy
    self.approvalsReviewer = approvalsReviewer
    self.model = model
    self.baseInstructions = baseInstructions
    self.developerInstructions = developerInstructions
  }
}

public struct TurnStartParams: Codable, Equatable, Sendable {
  public let threadId: String
  public let input: [CodexTextInput]
  public let sandboxPolicy: CodexSandboxPolicy
  public let approvalPolicy: CodexApprovalPolicy
  public let model: String?
  public let effort: String?
  public let outputSchema: JSONValue?

  public init(
    threadId: String,
    text: String,
    sandboxPolicy: CodexSandboxPolicy,
    approvalPolicy: CodexApprovalPolicy,
    model: String? = nil,
    effort: String? = nil,
    outputSchema: JSONValue? = nil
  ) {
    self.threadId = threadId
    input = [CodexTextInput(text: text)]
    self.sandboxPolicy = sandboxPolicy
    self.approvalPolicy = approvalPolicy
    self.model = model
    self.effort = effort
    self.outputSchema = outputSchema
  }
}

public struct TurnSteerParams: Codable, Equatable, Sendable {
  public let threadId: String
  public let expectedTurnId: String
  public let input: [CodexTextInput]

  public init(threadId: String, expectedTurnId: String, text: String) {
    self.threadId = threadId
    self.expectedTurnId = expectedTurnId
    input = [CodexTextInput(text: text)]
  }
}

public struct TurnInterruptParams: Codable, Equatable, Sendable {
  public let threadId: String
  public let turnId: String

  public init(threadId: String, turnId: String) {
    self.threadId = threadId
    self.turnId = turnId
  }
}

public struct CodexTurn: Codable, Equatable, Sendable {
  public let id: String
  public let status: String
  public let error: JSONValue?
  public let items: [JSONValue]
  public let itemsView: String?
  public let startedAt: Int64?
  public let completedAt: Int64?
  public let durationMs: Int64?
}

public struct CodexThread: Codable, Equatable, Sendable {
  public let id: String
  public let cwd: String
  public let ephemeral: Bool
  public let modelProvider: String
  public let preview: String
  public let turns: [CodexTurn]
  public let name: String?
  public let cliVersion: String
  public let createdAt: Int64
  public let updatedAt: Int64
  public let sessionId: String
  public let status: JSONValue
  public let source: JSONValue
}

public struct ThreadStartResponse: Codable, Equatable, Sendable {
  public let thread: CodexThread
  public let model: String
  public let modelProvider: String
  public let reasoningEffort: String?
  public let cwd: String
  public let sandbox: CodexSandboxPolicy
  public let approvalPolicy: CodexApprovalPolicy
  public let approvalsReviewer: String
  public let serviceTier: String?
}

public struct ThreadReadResponse: Codable, Equatable, Sendable {
  public let thread: CodexThread
}

public struct ThreadListResponse: Codable, Equatable, Sendable {
  public let data: [CodexThread]
  public let nextCursor: String?
  public let backwardsCursor: String?
}

public typealias ThreadResumeResponse = ThreadStartResponse

public struct TurnStartResponse: Codable, Equatable, Sendable {
  public let turn: CodexTurn
}

public struct TurnSteerResponse: Codable, Equatable, Sendable {
  public let turnId: String
}

public struct TurnInterruptResponse: Codable, Equatable, Sendable {
  public init() {}
}

public struct ThreadStartedNotification: Codable, Equatable, Sendable {
  public let thread: CodexThread
}

public struct TurnNotification: Codable, Equatable, Sendable {
  public let threadId: String
  public let turn: CodexTurn
}

public struct AgentMessageDeltaNotification: Codable, Equatable, Sendable {
  public let threadId: String
  public let turnId: String
  public let itemId: String
  public let delta: String
}

public enum CodexNotification: Equatable, Sendable {
  case threadStarted(ThreadStartedNotification)
  case turnStarted(TurnNotification)
  case turnCompleted(TurnNotification)
  case agentMessageDelta(AgentMessageDeltaNotification)
  case unknown(RPCNotification)
}

extension RPCNotification {
  public func decodedCodexNotification() throws -> CodexNotification {
    switch method {
    case "thread/started":
      return .threadStarted(try decodeParams(ThreadStartedNotification.self))
    case "turn/started":
      return .turnStarted(try decodeParams(TurnNotification.self))
    case "turn/completed":
      return .turnCompleted(try decodeParams(TurnNotification.self))
    case "item/agentMessage/delta":
      return .agentMessageDelta(try decodeParams(AgentMessageDeltaNotification.self))
    default:
      return .unknown(self)
    }
  }

  private func decodeParams<Value: Decodable>(_ type: Value.Type) throws -> Value {
    guard let params else {
      throw CodexRPCError.malformedMessage("notification \(method) has no params")
    }
    do {
      return try params.decode(type)
    } catch {
      throw CodexRPCError.malformedMessage(
        "notification \(method) has invalid params: \(error.localizedDescription)"
      )
    }
  }
}
