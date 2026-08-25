import Foundation
import MCP

public enum MCPToolResultEncodingError: Error, Equatable, Sendable {
  case resultTooLarge(maximumBytes: Int)
}

public struct MCPToolResultEncoder: Sendable {
  public static let productionMaximumBytes = 200 * 1_024

  public let maximumBytes: Int

  public init(maximumBytes: Int = Self.productionMaximumBytes) {
    precondition(maximumBytes > 0)
    self.maximumBytes = maximumBytes
  }

  public func encode<Output: Encodable & Sendable>(
    _ output: Output,
    isError: Bool = false
  ) throws -> CallTool.Result {
    let encoder = Self.makeJSONEncoder()
    let data = try encoder.encode(output)
    let structured = try JSONDecoder().decode(Value.self, from: data)
    let text = String(decoding: data, as: UTF8.self)
    let result = CallTool.Result(
      content: [.text(text: text, annotations: nil, _meta: nil)],
      structuredContent: Optional.some(structured),
      isError: isError
    )
    guard try encoder.encode(result).count <= maximumBytes else {
      throw MCPToolResultEncodingError.resultTooLarge(maximumBytes: maximumBytes)
    }
    return result
  }

  public func encodeTaskDiffPage(_ page: MCPTaskDiffPage) throws -> CallTool.Result {
    try encode(GetTaskDiffOutput(page: page))
  }

  private static func makeJSONEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }
}

public struct MCPToolErrorDTO: Codable, Equatable, Sendable {
  public let code: String
  public let message: String
  public let retryable: Bool
  public let owner: String?
  public let taskID: String?
  public let operationID: String?
  public let sessionID: String?
  public let data: [String: String]?

  public init(
    code: String,
    message: String,
    retryable: Bool,
    owner: String? = nil,
    taskID: String? = nil,
    operationID: String? = nil,
    sessionID: String? = nil,
    data: [String: String]? = nil
  ) {
    self.code = code
    self.message = message
    self.retryable = retryable
    self.owner = owner
    self.taskID = taskID
    self.operationID = operationID
    self.sessionID = sessionID
    self.data = data
  }

  private enum CodingKeys: String, CodingKey {
    case code
    case message
    case retryable
    case owner
    case taskID = "task_id"
    case operationID = "operation_id"
    case sessionID = "session_id"
    case data
  }
}

public struct MCPToolErrorOutput: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let error: MCPToolErrorDTO

  public init(schemaVersion: Int = 1, error: MCPToolErrorDTO) {
    self.schemaVersion = schemaVersion
    self.error = error
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case error
  }
}

public struct BridgeStatusOutput: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let appVersion: String
  public let mcpState: String
  public let tunnelState: String
  public let codexVersion: String?
  public let loginMode: String?
  public let executionState: String
  public let supervisorState: String
  public let degradations: [String]
  public let pendingApprovalCount: Int
  public let executionEnvironment: MCPExecutionEnvironment?

  public init(snapshot: BridgeStatusSnapshot) {
    schemaVersion = 1
    appVersion = snapshot.appVersion
    mcpState = snapshot.mcpState
    tunnelState = snapshot.tunnelState
    codexVersion = snapshot.codexVersion
    loginMode = snapshot.loginMode
    executionState = snapshot.executionState
    supervisorState = snapshot.supervisorState
    degradations = snapshot.degradations
    pendingApprovalCount = snapshot.pendingApprovalCount
    executionEnvironment = snapshot.executionEnvironment
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case appVersion = "app_version"
    case mcpState = "mcp_state"
    case tunnelState = "tunnel_state"
    case codexVersion = "codex_version"
    case loginMode = "login_mode"
    case executionState = "execution_state"
    case supervisorState = "supervisor_state"
    case degradations
    case pendingApprovalCount = "pending_approval_count"
    case executionEnvironment = "execution_environment"
  }
}

public struct ListProjectsOutput: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let projects: [MCPProjectSummary]
  public let nextCursor: String?

  public init(page: MCPProjectPage) {
    schemaVersion = 1
    projects = page.projects
    nextCursor = page.nextCursor
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case projects
    case nextCursor = "next_cursor"
  }
}

public struct ListAgentsOutput: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let agents: [MCPAgentSummary]

  public init(list: MCPAgentList) {
    schemaVersion = 1
    agents = list.agents
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case agents
  }
}

public struct ListThreadsOutput: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let threads: [MCPThreadSummary]
  public let nextCursor: String?

  public init(page: MCPThreadPage) {
    schemaVersion = 1
    threads = page.threads
    nextCursor = page.nextCursor
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case threads
    case nextCursor = "next_cursor"
  }
}

public struct ReadThreadOutput: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let thread: MCPThreadSummary
  public let detail: MCPThreadDetail
  public let entries: [MCPThreadEntry]
  public let nextCursor: String?

  public init(page: MCPThreadReadPage) {
    schemaVersion = 1
    thread = page.thread
    detail = page.detail
    entries = page.entries
    nextCursor = page.nextCursor
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case thread
    case detail
    case entries
    case nextCursor = "next_cursor"
  }
}

public struct ListModelsOutput: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let models: [MCPModelSummary]

  public init(list: MCPModelList) {
    schemaVersion = 1
    models = list.models
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case models
  }
}
