import BridgeSecurity
import Foundation
import MCP

public struct MCPProjectToolDeadlines: Sendable {
  public static let production = MCPProjectToolDeadlines(
    project: .seconds(5),
    search: .seconds(15),
    read: .seconds(10),
    navigation: .seconds(5)
  )

  public let project: ContinuousClock.Duration
  public let search: ContinuousClock.Duration
  public let read: ContinuousClock.Duration
  public let navigation: ContinuousClock.Duration

  public init(
    project: ContinuousClock.Duration,
    search: ContinuousClock.Duration,
    read: ContinuousClock.Duration,
    navigation: ContinuousClock.Duration
  ) {
    precondition([project, search, read, navigation].allSatisfy { $0 > .zero })
    self.project = project
    self.search = search
    self.read = read
    self.navigation = navigation
  }
}

struct ProjectTools: Sendable {
  private let operations: (any BridgeMCPProjectOperations)?
  private let deadlines: MCPProjectToolDeadlines
  private let clock = ContinuousClock()

  init(
    operations: (any BridgeMCPProjectOperations)?,
    deadlines: MCPProjectToolDeadlines = .production
  ) {
    self.operations = operations
    self.deadlines = deadlines
  }

  func getProject(arguments: [String: Value]?) async throws -> GetProjectOutput {
    let values = try StrictToolArguments(
      arguments,
      allowed: ["project_id"],
      required: ["project_id"]
    )
    let projectID = try values.requiredIdentifier("project_id", maximumUTF8Bytes: 128)
    let operations = try availableOperations()
    let deadline = clock.now.advanced(by: deadlines.project)
    let project = try await withToolDeadline(until: deadline) {
      try await operations.getProject(projectID: projectID, deadline: deadline)
    }
    try validate(project, expectedID: projectID)
    return GetProjectOutput(project: project)
  }

  func searchProjectFiles(arguments: [String: Value]?) async throws
    -> SearchProjectFilesOutput
  {
    let values = try StrictToolArguments(
      arguments,
      allowed: [
        "project_id", "query", "relative_directory", "case_sensitive", "cursor", "limit",
      ],
      required: ["project_id", "query"]
    )
    let projectID = try values.requiredIdentifier("project_id", maximumUTF8Bytes: 128)
    let query = try values.requiredText("query", maximumUTF8Bytes: 512)
    let directory = try values.optionalString("relative_directory", maximumUTF8Bytes: 1_024)
    if let directory { try validateRelativePath(directory) }
    let cursor = try values.optionalString("cursor", maximumUTF8Bytes: 128)
    let limit = try values.limit(maximum: 50)
    let caseSensitive = try values.optionalBoolean("case_sensitive") ?? false
    let operations = try availableOperations()
    let deadline = clock.now.advanced(by: deadlines.search)
    let page = try await withToolDeadline(until: deadline) {
      try await operations.searchProjectFiles(
        projectID: projectID,
        query: query,
        relativeDirectory: directory,
        caseSensitive: caseSensitive,
        cursor: cursor,
        limit: limit,
        deadline: deadline
      )
    }
    try validate(page, limit: limit)
    return SearchProjectFilesOutput(page: page)
  }

  func readProjectFile(arguments: [String: Value]?) async throws -> ReadProjectFileOutput {
    let values = try StrictToolArguments(
      arguments,
      allowed: ["project_id", "relative_path", "start_line", "line_count"],
      required: ["project_id", "relative_path"]
    )
    let projectID = try values.requiredIdentifier("project_id", maximumUTF8Bytes: 128)
    let path = try values.requiredIdentifier("relative_path", maximumUTF8Bytes: 1_024)
    try validateRelativePath(path)
    let startLine = try values.optionalPositiveInteger("start_line", maximum: Int.max) ?? 1
    let lineCount = try values.optionalPositiveInteger("line_count", maximum: 300) ?? 300
    let operations = try availableOperations()
    let deadline = clock.now.advanced(by: deadlines.read)
    let page = try await withToolDeadline(until: deadline) {
      try await operations.readProjectFile(
        projectID: projectID,
        relativePath: path,
        startLine: startLine,
        lineCount: lineCount,
        deadline: deadline
      )
    }
    try validate(
      page,
      path: path,
      requestedStartLine: startLine,
      requestedLines: lineCount
    )
    return ReadProjectFileOutput(page: page)
  }

  func openInCodex(arguments: [String: Value]?) async throws -> OpenInCodexOutput {
    let values = try StrictToolArguments(
      arguments,
      allowed: ["project_id", "thread_id"],
      required: ["project_id", "thread_id"]
    )
    let projectID = try values.requiredIdentifier("project_id", maximumUTF8Bytes: 128)
    let threadID = try values.requiredIdentifier("thread_id", maximumUTF8Bytes: 256)
    let operations = try availableOperations()
    let deadline = clock.now.advanced(by: deadlines.navigation)
    let receipt = try await withToolDeadline(until: deadline) {
      try await operations.openInCodex(
        projectID: projectID,
        threadID: threadID,
        deadline: deadline
      )
    }
    guard receipt.projectID == projectID, receipt.threadID == threadID, receipt.opened else {
      throw MCPToolAdapterError.invalidQueryOutput
    }
    return OpenInCodexOutput(receipt: receipt)
  }

  private func availableOperations() throws -> any BridgeMCPProjectOperations {
    guard let operations else { throw BridgeMCPQueryError.unavailable }
    return operations
  }

  private func validate(_ project: MCPProjectDetail, expectedID: String) throws {
    let capabilities = [
      project.capabilities.read,
      project.capabilities.write,
      project.capabilities.network,
    ]
    let permissionValues = Set(["allowed", "requiresLocalApproval", "denied"])
    guard project.projectID == expectedID, !project.name.isEmpty,
      project.name.utf8.count <= 1_024,
      project.verificationCommands.count <= 128,
      project.threadCount.map({ $0 >= 0 }) ?? true,
      capabilities.allSatisfy(permissionValues.contains),
      project.gitState.map({ $0.utf8.count <= 128 && isSafeProjectText($0) }) ?? true,
      project.verificationCommands.allSatisfy({ $0.utf8.count <= 4_096 }),
      ([project.name] + project.verificationCommands).allSatisfy(isSafeProjectText)
    else {
      throw MCPToolAdapterError.invalidQueryOutput
    }
  }

  private func validate(_ page: MCPProjectFileSearchPage, limit: Int) throws {
    guard page.matches.count <= limit, page.skippedFileCount >= 0,
      page.nextCursor.map(isSafeCursor) ?? true
    else {
      throw MCPToolAdapterError.invalidQueryOutput
    }
    for match in page.matches {
      guard isSafeRelativePath(match.relativePath), match.lineNumber > 0,
        isSafeProjectText(match.preview), match.preview.utf8.count <= 1_024
      else {
        throw MCPToolAdapterError.invalidQueryOutput
      }
    }
  }

  private func validate(
    _ page: MCPProjectFileReadPage,
    path: String,
    requestedStartLine: Int,
    requestedLines: Int
  ) throws {
    let returnedLines: Int
    if let endLine = page.endLine {
      let distance = endLine.subtractingReportingOverflow(page.startLine)
      let count = distance.partialValue.addingReportingOverflow(1)
      guard !distance.overflow, !count.overflow else {
        throw MCPToolAdapterError.invalidQueryOutput
      }
      returnedLines = count.partialValue
    } else {
      returnedLines = 0
    }
    let contentLineCount = logicalLineCount(page.content)
    let expectedNextLine = page.endLine?.addingReportingOverflow(1)
    guard page.relativePath == path, page.startLine == requestedStartLine,
      page.endLine.map({ $0 >= page.startLine }) ?? page.content.isEmpty,
      returnedLines <= requestedLines,
      returnedLines == contentLineCount,
      page.redactedLineCount >= 0, page.redactedLineCount <= returnedLines,
      page.truncated == (page.nextStartLine != nil),
      expectedNextLine?.overflow != true,
      page.nextStartLine == (page.truncated ? expectedNextLine?.partialValue : nil),
      page.content.utf8.count <= 200 * 1_024,
      isSafeProjectText(page.content)
    else {
      throw MCPToolAdapterError.invalidQueryOutput
    }
  }

  private func validateRelativePath(_ path: String) throws {
    guard isSafeRelativePath(path) else {
      throw MCPError.invalidParams("Project paths must be safe relative paths.")
    }
  }
}

private func isSafeRelativePath(_ path: String) -> Bool {
  guard !path.isEmpty, path.utf8.count <= 1_024, !path.hasPrefix("/"), !path.hasPrefix("~"),
    !path.contains("\\"),
    path.rangeOfCharacter(from: .controlCharacters) == nil
  else { return false }
  return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
    !$0.isEmpty && $0 != "." && $0 != ".."
  }
}

private func logicalLineCount(_ value: String) -> Int {
  guard !value.isEmpty else { return 0 }
  return value.split(separator: "\n", omittingEmptySubsequences: false).count
}

private func isSafeProjectText(_ value: String) -> Bool {
  OutboundContentSecurity.isSafe(value)
}

private func isSafeCursor(_ value: String) -> Bool {
  !value.isEmpty && value.utf8.count <= 128
    && value.rangeOfCharacter(from: .controlCharacters) == nil
    && OutboundContentSecurity.isSafe(value)
}

struct GetProjectOutput: Codable, Sendable {
  let schemaVersion = 1
  let project: MCPProjectDetail

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case project
  }
}

struct SearchProjectFilesOutput: Codable, Sendable {
  let schemaVersion = 1
  let matches: [MCPProjectFileSearchMatch]
  let nextCursor: String?
  let skippedFileCount: Int

  init(page: MCPProjectFileSearchPage) {
    matches = page.matches
    nextCursor = page.nextCursor
    skippedFileCount = page.skippedFileCount
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case matches
    case nextCursor = "next_cursor"
    case skippedFileCount = "skipped_file_count"
  }
}

struct ReadProjectFileOutput: Codable, Sendable {
  let schemaVersion = 1
  let relativePath: String
  let startLine: Int
  let endLine: Int?
  let content: String
  let redactedLineCount: Int
  let truncated: Bool
  let nextStartLine: Int?

  init(page: MCPProjectFileReadPage) {
    relativePath = page.relativePath
    startLine = page.startLine
    endLine = page.endLine
    content = page.content
    redactedLineCount = page.redactedLineCount
    truncated = page.truncated
    nextStartLine = page.nextStartLine
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case relativePath = "relative_path"
    case startLine = "start_line"
    case endLine = "end_line"
    case content
    case redactedLineCount = "redacted_line_count"
    case truncated
    case nextStartLine = "next_start_line"
  }
}

struct OpenInCodexOutput: Codable, Sendable {
  let schemaVersion = 1
  let projectID: String
  let threadID: String
  let opened: Bool

  init(receipt: MCPOpenInCodexReceipt) {
    projectID = receipt.projectID
    threadID = receipt.threadID
    opened = receipt.opened
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case projectID = "project_id"
    case threadID = "thread_id"
    case opened
  }
}
