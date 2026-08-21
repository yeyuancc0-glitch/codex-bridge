import Foundation

public struct MCPWorkspaceOwner: Codable, Equatable, Sendable {
  public let owner: String
  public let taskID: String?
  public let operationID: String?
  public let sessionID: String?

  public init(
    owner: String,
    taskID: String? = nil,
    operationID: String? = nil,
    sessionID: String? = nil
  ) {
    self.owner = owner
    self.taskID = taskID
    self.operationID = operationID
    self.sessionID = sessionID
  }

  public init(detail: WorkspaceBusyDetail) {
    self.init(
      owner: detail.owner,
      taskID: detail.taskID,
      operationID: detail.operationID,
      sessionID: detail.sessionID
    )
  }

  private enum CodingKeys: String, CodingKey {
    case owner
    case taskID = "task_id"
    case operationID = "operation_id"
    case sessionID = "session_id"
  }
}
public struct MCPBoundedDiff: Codable, Equatable, Sendable {
  public let removedLines: [String]
  public let addedLines: [String]
  public let truncated: Bool
  public let byteCount: Int

  public init(removedLines: [String], addedLines: [String], truncated: Bool, byteCount: Int) {
    self.removedLines = removedLines
    self.addedLines = addedLines
    self.truncated = truncated
    self.byteCount = byteCount
  }

  public static let empty = MCPBoundedDiff(
    removedLines: [], addedLines: [], truncated: false, byteCount: 0)

  private enum CodingKeys: String, CodingKey {
    case removedLines = "removed_lines"
    case addedLines = "added_lines"
    case truncated
    case byteCount = "byte_count"
  }
}

public struct MCPDirectWriteRequest: Codable, Equatable, Sendable {
  public let projectID: String
  public let relativePath: String
  public let mode: String
  public let content: String
  public let expectedSHA256: String?
  public let createParents: Bool
  public let clientRequestID: String?

  public init(
    projectID: String,
    relativePath: String,
    mode: String,
    content: String,
    expectedSHA256: String? = nil,
    createParents: Bool = false,
    clientRequestID: String? = nil
  ) {
    self.projectID = projectID
    self.relativePath = relativePath
    self.mode = mode
    self.content = content
    self.expectedSHA256 = expectedSHA256
    self.createParents = createParents
    self.clientRequestID = clientRequestID
  }

  private enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    case relativePath = "relative_path"
    case mode
    case content
    case expectedSHA256 = "expected_sha256"
    case createParents = "create_parents"
    case clientRequestID = "client_request_id"
  }
}

public struct MCPDirectWriteReceipt: Codable, Equatable, Sendable {
  public let relativePath: String
  public let operation: String
  public let oldSHA256: String?
  public let newSHA256: String?
  public let byteCount: Int
  public let boundedDiff: MCPBoundedDiff

  public init(
    relativePath: String,
    operation: String,
    oldSHA256: String?,
    newSHA256: String?,
    byteCount: Int,
    boundedDiff: MCPBoundedDiff = .empty
  ) {
    self.relativePath = relativePath
    self.operation = operation
    self.oldSHA256 = oldSHA256
    self.newSHA256 = newSHA256
    self.byteCount = byteCount
    self.boundedDiff = boundedDiff
  }

  public init(result: MCPDirectWriteReceipt, boundedDiff: MCPBoundedDiff) {
    self.init(
      relativePath: result.relativePath,
      operation: result.operation,
      oldSHA256: result.oldSHA256,
      newSHA256: result.newSHA256,
      byteCount: result.byteCount,
      boundedDiff: boundedDiff
    )
  }

  private enum CodingKeys: String, CodingKey {
    case relativePath = "relative_path"
    case operation
    case oldSHA256 = "old_sha256"
    case newSHA256 = "new_sha256"
    case byteCount = "byte_count"
    case boundedDiff = "bounded_diff"
  }
}

extension MCPDirectWriteReceipt {
  func compactedForTransport() -> Self {
    Self(
      relativePath: relativePath,
      operation: operation,
      oldSHA256: oldSHA256,
      newSHA256: newSHA256,
      byteCount: byteCount,
      boundedDiff: MCPBoundedDiff(
        removedLines: [],
        addedLines: [],
        truncated: true,
        byteCount: 0
      )
    )
  }
}

public struct MCPDirectEditRequest: Codable, Equatable, Sendable {
  public let projectID: String
  public let relativePath: String
  public let expectedSHA256: String
  public let oldText: String
  public let newText: String
  public let expectedReplacements: Int
  public let clientRequestID: String?

  public init(
    projectID: String,
    relativePath: String,
    expectedSHA256: String,
    oldText: String,
    newText: String,
    expectedReplacements: Int = 1,
    clientRequestID: String? = nil
  ) {
    self.projectID = projectID
    self.relativePath = relativePath
    self.expectedSHA256 = expectedSHA256
    self.oldText = oldText
    self.newText = newText
    self.expectedReplacements = expectedReplacements
    self.clientRequestID = clientRequestID
  }

  private enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    case relativePath = "relative_path"
    case expectedSHA256 = "expected_sha256"
    case oldText = "old_text"
    case newText = "new_text"
    case expectedReplacements = "expected_replacements"
    case clientRequestID = "client_request_id"
  }
}

public typealias MCPDirectEditReceipt = MCPDirectWriteReceipt

public struct MCPPatchHunk: Codable, Equatable, Sendable {
  public let context: String
  public let removals: [String]
  public let additions: [String]

  public init(context: String, removals: [String], additions: [String]) {
    self.context = context
    self.removals = removals
    self.additions = additions
  }

  private enum CodingKeys: String, CodingKey {
    case context
    case removals
    case additions
  }
}

public struct MCPPatchFileOperation: Codable, Equatable, Sendable {
  public let action: String
  public let relativePath: String
  public let expectedSHA256: String?
  public let hunks: [MCPPatchHunk]

  public init(
    action: String,
    relativePath: String,
    expectedSHA256: String? = nil,
    hunks: [MCPPatchHunk]
  ) {
    self.action = action
    self.relativePath = relativePath
    self.expectedSHA256 = expectedSHA256
    self.hunks = hunks
  }

  private enum CodingKeys: String, CodingKey {
    case action
    case relativePath = "relative_path"
    case expectedSHA256 = "expected_sha256"
    case hunks
  }
}

public struct MCPDirectPatchRequest: Codable, Equatable, Sendable {
  public let projectID: String
  public let patch: String
  public let clientRequestID: String?

  public init(
    projectID: String,
    patch: String,
    clientRequestID: String? = nil
  ) {
    self.projectID = projectID
    self.patch = patch
    self.clientRequestID = clientRequestID
  }

  private enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    case patch
    case clientRequestID = "client_request_id"
  }
}

public struct MCPPartialCommit: Codable, Equatable, Sendable {
  public let changedFiles: [String]
  public let rollbackStatus: String

  public init(changedFiles: [String], rollbackStatus: String) {
    self.changedFiles = changedFiles
    self.rollbackStatus = rollbackStatus
  }

  private enum CodingKeys: String, CodingKey {
    case changedFiles = "changed_files"
    case rollbackStatus = "rollback_status"
  }
}

public struct MCPDirectPatchReceipt: Codable, Equatable, Sendable {
  public let operations: [MCPDirectWriteReceipt]
  public let partialCommit: MCPPartialCommit?

  public init(operations: [MCPDirectWriteReceipt], partialCommit: MCPPartialCommit? = nil) {
    self.operations = operations
    self.partialCommit = partialCommit
  }

  private enum CodingKeys: String, CodingKey {
    case operations
    case partialCommit = "partial_commit"
  }
}

extension MCPDirectPatchReceipt {
  func compactedForTransport() -> Self {
    Self(
      operations: operations.map { $0.compactedForTransport() },
      partialCommit: partialCommit
    )
  }
}

public struct MCPDirectManagePathRequest: Codable, Equatable, Sendable {
  public let projectID: String
  public let action: String
  public let relativePath: String
  public let expectedSHA256: String?
  public let destinationRelativePath: String?
  public let sourceExpectedSHA256: String?
  public let destinationExpectedAbsent: Bool
  public let clientRequestID: String?

  public init(
    projectID: String,
    action: String,
    relativePath: String,
    expectedSHA256: String? = nil,
    destinationRelativePath: String? = nil,
    sourceExpectedSHA256: String? = nil,
    destinationExpectedAbsent: Bool = true,
    clientRequestID: String? = nil
  ) {
    self.projectID = projectID
    self.action = action
    self.relativePath = relativePath
    self.expectedSHA256 = expectedSHA256
    self.destinationRelativePath = destinationRelativePath
    self.sourceExpectedSHA256 = sourceExpectedSHA256
    self.destinationExpectedAbsent = destinationExpectedAbsent
    self.clientRequestID = clientRequestID
  }

  private enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    case action
    case relativePath = "relative_path"
    case expectedSHA256 = "expected_sha256"
    case destinationRelativePath = "destination_relative_path"
    case sourceExpectedSHA256 = "source_expected_sha256"
    case destinationExpectedAbsent = "destination_expected_absent"
    case clientRequestID = "client_request_id"
  }
}

public struct MCPDirectManagePathReceipt: Codable, Equatable, Sendable {
  public let relativePath: String
  public let sourceRelativePath: String
  public let destinationRelativePath: String?
  public let operation: String
  public let sha256: String?
  public let oldSHA256: String?
  public let newSHA256: String?
  public let byteCount: Int

  public init(
    relativePath: String,
    sourceRelativePath: String? = nil,
    destinationRelativePath: String? = nil,
    operation: String,
    sha256: String? = nil,
    oldSHA256: String? = nil,
    newSHA256: String? = nil,
    byteCount: Int = 0
  ) {
    self.relativePath = relativePath
    self.sourceRelativePath = sourceRelativePath ?? relativePath
    self.destinationRelativePath = destinationRelativePath
    self.operation = operation
    self.sha256 = sha256
    self.oldSHA256 = oldSHA256
    self.newSHA256 = newSHA256
    self.byteCount = byteCount
  }

  private enum CodingKeys: String, CodingKey {
    case relativePath = "relative_path"
    case sourceRelativePath = "source_relative_path"
    case destinationRelativePath = "destination_relative_path"
    case operation
    case sha256
    case oldSHA256 = "old_sha256"
    case newSHA256 = "new_sha256"
    case byteCount = "byte_count"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    relativePath = try container.decode(String.self, forKey: .relativePath)
    sourceRelativePath =
      try container.decodeIfPresent(String.self, forKey: .sourceRelativePath) ?? relativePath
    destinationRelativePath = try container.decodeIfPresent(
      String.self, forKey: .destinationRelativePath)
    operation = try container.decode(String.self, forKey: .operation)
    sha256 = try container.decodeIfPresent(String.self, forKey: .sha256)
    oldSHA256 = try container.decodeIfPresent(String.self, forKey: .oldSHA256)
    newSHA256 = try container.decodeIfPresent(String.self, forKey: .newSHA256)
    byteCount = try container.decode(Int.self, forKey: .byteCount)
  }
}
