import Foundation

public struct MCPExecutionEnvironment: Codable, Equatable, Sendable {
  public let bridgeSandbox: String
  public let scope: String?
  public let sandboxExec: String
  public let nestedSandbox: String
  public let loopback: String
  public let childNetworkPolicy: String?
  public let xcodebuildNestedSandbox: String?
  public let loopbackBind: String?
  public let limitations: [String]

  public init(
    bridgeSandbox: String,
    scope: String? = nil,
    sandboxExec: String,
    nestedSandbox: String,
    loopback: String,
    childNetworkPolicy: String? = nil,
    xcodebuildNestedSandbox: String? = nil,
    loopbackBind: String? = nil,
    limitations: [String] = []
  ) {
    self.bridgeSandbox = bridgeSandbox
    self.scope = scope
    self.sandboxExec = sandboxExec
    self.nestedSandbox = nestedSandbox
    self.loopback = loopback
    self.childNetworkPolicy = childNetworkPolicy
    self.xcodebuildNestedSandbox = xcodebuildNestedSandbox
    self.loopbackBind = loopbackBind
    self.limitations = limitations
  }

  private enum CodingKeys: String, CodingKey {
    case bridgeSandbox = "bridge_sandbox"
    case scope
    case sandboxExec = "sandbox_exec"
    case nestedSandbox = "nested_sandbox"
    case loopback
    case childNetworkPolicy = "child_network_policy"
    case xcodebuildNestedSandbox = "xcodebuild_nested_sandbox"
    case loopbackBind = "loopback_bind"
    case limitations
  }
}

public struct MCPDirectExecRequest: Codable, Equatable, Sendable {
  public let projectID: String
  public let commandID: String?
  public let argv: [String]
  public let workingDirectory: String?
  public let tty: Bool
  public let yieldTimeMS: Int
  public let timeoutMS: Int
  public let clientRequestID: String?

  public init(
    projectID: String,
    commandID: String? = nil,
    argv: [String],
    workingDirectory: String? = nil,
    tty: Bool = false,
    yieldTimeMS: Int = 1_000,
    timeoutMS: Int = 300_000,
    clientRequestID: String? = nil
  ) {
    self.projectID = projectID
    self.commandID = commandID
    self.argv = argv
    self.workingDirectory = workingDirectory
    self.tty = tty
    self.yieldTimeMS = yieldTimeMS
    self.timeoutMS = timeoutMS
    self.clientRequestID = clientRequestID
  }

  private enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    case commandID = "command_id"
    case argv
    case workingDirectory = "working_directory"
    case tty
    case yieldTimeMS = "yield_time_ms"
    case timeoutMS = "timeout_ms"
    case clientRequestID = "client_request_id"
  }
}
public struct MCPDirectCommandReceipt: Codable, Equatable, Sendable {
  public let sessionID: String
  public let status: String
  public let exitCode: Int?
  public let startedAt: String?
  public let completedAt: String?
  public let output: MCPDirectCommandOutput?
  public let error: String?

  public init(
    sessionID: String,
    status: String,
    exitCode: Int? = nil,
    startedAt: String? = nil,
    completedAt: String? = nil,
    output: MCPDirectCommandOutput? = nil,
    error: String? = nil
  ) {
    self.sessionID = sessionID
    self.status = status
    self.exitCode = exitCode
    self.startedAt = startedAt
    self.completedAt = completedAt
    self.output = output
    self.error = error
  }

  private enum CodingKeys: String, CodingKey {
    case sessionID = "session_id"
    case status
    case exitCode = "exit_code"
    case startedAt = "started_at"
    case completedAt = "completed_at"
    case output
    case error
  }
}

public struct MCPDirectCommandOutput: Codable, Equatable, Sendable {
  public let sessionID: String
  public let status: String
  public let exitCode: Int?
  public let timedOut: Bool
  public let commandStatus: String?
  public let commandTimedOut: Bool?
  public let readTimeout: Bool?
  public let head: String
  public let tail: String
  public let byteCount: Int
  public let truncated: Bool
  public let executionEnvironment: MCPExecutionEnvironment?

  public init(
    sessionID: String,
    status: String,
    exitCode: Int? = nil,
    timedOut: Bool = false,
    commandStatus: String? = nil,
    commandTimedOut: Bool? = nil,
    readTimeout: Bool? = nil,
    head: String,
    tail: String,
    byteCount: Int,
    truncated: Bool,
    executionEnvironment: MCPExecutionEnvironment? = nil
  ) {
    self.sessionID = sessionID
    self.status = status
    self.exitCode = exitCode
    self.timedOut = timedOut
    self.commandStatus = commandStatus
    self.commandTimedOut = commandTimedOut
    self.readTimeout = readTimeout
    self.head = head
    self.tail = tail
    self.byteCount = byteCount
    self.truncated = truncated
    self.executionEnvironment = executionEnvironment
  }

  public func markingReadTimeout() -> MCPDirectCommandOutput {
    MCPDirectCommandOutput(
      sessionID: sessionID,
      status: status,
      exitCode: exitCode,
      timedOut: timedOut,
      commandStatus: commandStatus ?? status,
      commandTimedOut: commandTimedOut ?? timedOut,
      readTimeout: true,
      head: head,
      tail: tail,
      byteCount: byteCount,
      truncated: truncated,
      executionEnvironment: executionEnvironment
    )
  }

  private enum CodingKeys: String, CodingKey {
    case sessionID = "session_id"
    case status
    case exitCode = "exit_code"
    case timedOut = "timed_out"
    case commandStatus = "command_status"
    case commandTimedOut = "command_timed_out"
    case readTimeout = "read_timeout"
    case head
    case tail
    case byteCount = "byte_count"
    case truncated
    case executionEnvironment = "execution_environment"
  }
}
