import Foundation

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
  public let head: String
  public let tail: String
  public let byteCount: Int
  public let truncated: Bool

  public init(
    sessionID: String,
    status: String,
    exitCode: Int? = nil,
    timedOut: Bool = false,
    head: String,
    tail: String,
    byteCount: Int,
    truncated: Bool
  ) {
    self.sessionID = sessionID
    self.status = status
    self.exitCode = exitCode
    self.timedOut = timedOut
    self.head = head
    self.tail = tail
    self.byteCount = byteCount
    self.truncated = truncated
  }

  private enum CodingKeys: String, CodingKey {
    case sessionID = "session_id"
    case status
    case exitCode = "exit_code"
    case timedOut = "timed_out"
    case head
    case tail
    case byteCount = "byte_count"
    case truncated
  }
}
