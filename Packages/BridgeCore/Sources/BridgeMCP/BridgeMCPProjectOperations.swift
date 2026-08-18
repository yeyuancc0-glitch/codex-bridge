import Foundation

public protocol BridgeMCPProjectOperations: Sendable {
  func getProject(
    projectID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectDetail

  func searchProjectFiles(
    projectID: String,
    query: String,
    relativeDirectory: String?,
    caseSensitive: Bool,
    cursor: String?,
    limit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectFileSearchPage

  func readProjectFile(
    projectID: String,
    relativePath: String,
    startLine: Int,
    lineCount: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectFileReadPage

  func openInCodex(
    projectID: String,
    threadID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPOpenInCodexReceipt
}

public struct MCPProjectDetail: Codable, Equatable, Sendable {
  public let projectID: String
  public let name: String
  public let capabilities: MCPProjectCapabilities
  public let gitState: String?
  public let verificationCommands: [String]
  public let threadCount: Int?

  public init(
    projectID: String,
    name: String,
    capabilities: MCPProjectCapabilities,
    gitState: String? = nil,
    verificationCommands: [String] = [],
    threadCount: Int? = nil
  ) {
    self.projectID = projectID
    self.name = name
    self.capabilities = capabilities
    self.gitState = gitState
    self.verificationCommands = verificationCommands
    self.threadCount = threadCount
  }

  private enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    case name
    case capabilities
    case gitState = "git_state"
    case verificationCommands = "verification_commands"
    case threadCount = "thread_count"
  }
}

public struct MCPProjectFileSearchMatch: Codable, Equatable, Sendable {
  public let relativePath: String
  public let lineNumber: Int
  public let preview: String
  public let redacted: Bool

  public init(relativePath: String, lineNumber: Int, preview: String, redacted: Bool) {
    self.relativePath = relativePath
    self.lineNumber = lineNumber
    self.preview = preview
    self.redacted = redacted
  }

  private enum CodingKeys: String, CodingKey {
    case relativePath = "relative_path"
    case lineNumber = "line_number"
    case preview
    case redacted
  }
}

public struct MCPProjectFileSearchPage: Codable, Equatable, Sendable {
  public let matches: [MCPProjectFileSearchMatch]
  public let nextCursor: String?
  public let skippedFileCount: Int

  public init(
    matches: [MCPProjectFileSearchMatch],
    nextCursor: String? = nil,
    skippedFileCount: Int = 0
  ) {
    self.matches = matches
    self.nextCursor = nextCursor
    self.skippedFileCount = skippedFileCount
  }

  private enum CodingKeys: String, CodingKey {
    case matches
    case nextCursor = "next_cursor"
    case skippedFileCount = "skipped_file_count"
  }
}

public struct MCPProjectFileReadPage: Codable, Equatable, Sendable {
  public let relativePath: String
  public let startLine: Int
  public let endLine: Int?
  public let content: String
  public let redactedLineCount: Int
  public let truncated: Bool
  public let nextStartLine: Int?
  public let sha256: String
  public let byteCount: Int
  public let fileRevision: String

  public init(
    relativePath: String,
    startLine: Int,
    endLine: Int?,
    content: String,
    redactedLineCount: Int,
    truncated: Bool,
    nextStartLine: Int?,
    sha256: String = "",
    byteCount: Int = 0
  ) {
    self.relativePath = relativePath
    self.startLine = startLine
    self.endLine = endLine
    self.content = content
    self.redactedLineCount = redactedLineCount
    self.truncated = truncated
    self.nextStartLine = nextStartLine
    self.sha256 = sha256
    self.byteCount = byteCount
    self.fileRevision = "sha256:\(sha256)"
  }

  private enum CodingKeys: String, CodingKey {
    case relativePath = "relative_path"
    case startLine = "start_line"
    case endLine = "end_line"
    case content
    case redactedLineCount = "redacted_line_count"
    case truncated
    case nextStartLine = "next_start_line"
    case sha256
    case byteCount = "byte_count"
    case fileRevision = "file_revision"
  }
}

public struct MCPOpenInCodexReceipt: Codable, Equatable, Sendable {
  public let projectID: String
  public let threadID: String
  public let opened: Bool

  public init(projectID: String, threadID: String, opened: Bool) {
    self.projectID = projectID
    self.threadID = threadID
    self.opened = opened
  }

  private enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    case threadID = "thread_id"
    case opened
  }
}
