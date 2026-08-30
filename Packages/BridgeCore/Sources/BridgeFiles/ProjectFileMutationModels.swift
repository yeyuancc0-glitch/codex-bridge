import BridgeDomain
import Foundation

public enum ProjectWriteMode: String, Codable, Equatable, Sendable {
  case create
  case replace
}

public struct ProjectWriteRequest: Equatable, Sendable {
  public let projectID: ProjectID
  public let relativePath: String
  public let mode: ProjectWriteMode
  public let content: String
  public let expectedSHA256: String?
  public let createParents: Bool

  public init(
    projectID: ProjectID,
    relativePath: String,
    mode: ProjectWriteMode,
    content: String,
    expectedSHA256: String? = nil,
    createParents: Bool = false
  ) {
    self.projectID = projectID
    self.relativePath = relativePath
    self.mode = mode
    self.content = content
    self.expectedSHA256 = expectedSHA256
    self.createParents = createParents
  }
}

public struct ProjectEditRequest: Equatable, Sendable {
  public let projectID: ProjectID
  public let relativePath: String
  public let expectedSHA256: String
  public let oldText: String
  public let newText: String
  public let expectedReplacements: Int

  public init(
    projectID: ProjectID,
    relativePath: String,
    expectedSHA256: String,
    oldText: String,
    newText: String,
    expectedReplacements: Int = 1
  ) {
    self.projectID = projectID
    self.relativePath = relativePath
    self.expectedSHA256 = expectedSHA256
    self.oldText = oldText
    self.newText = newText
    self.expectedReplacements = expectedReplacements
  }
}

public enum ProjectPathAction: String, Codable, Equatable, Sendable {
  case deleteFile = "delete_file"
  case moveFile = "move_file"
  case createDirectory = "create_directory"
  case deleteEmptyDirectory = "delete_empty_directory"
}

public struct ProjectManagePathRequest: Equatable, Sendable {
  public let projectID: ProjectID
  public let action: ProjectPathAction
  public let relativePath: String
  public let expectedSHA256: String?
  public let destinationRelativePath: String?
  public let sourceExpectedSHA256: String?
  public let destinationExpectedAbsent: Bool

  public init(
    projectID: ProjectID,
    action: ProjectPathAction,
    relativePath: String,
    expectedSHA256: String? = nil,
    destinationRelativePath: String? = nil,
    sourceExpectedSHA256: String? = nil,
    destinationExpectedAbsent: Bool = true
  ) {
    self.projectID = projectID
    self.action = action
    self.relativePath = relativePath
    self.expectedSHA256 = expectedSHA256
    self.destinationRelativePath = destinationRelativePath
    self.sourceExpectedSHA256 = sourceExpectedSHA256
    self.destinationExpectedAbsent = destinationExpectedAbsent
  }
}

public struct ProjectPatchFileOperation: Equatable, Sendable {
  public let action: String
  public let relativePath: String
  public let expectedSHA256: String?
  public let hunks: [ProjectPatchHunk]

  public init(
    action: String,
    relativePath: String,
    expectedSHA256: String? = nil,
    hunks: [ProjectPatchHunk]
  ) {
    self.action = action
    self.relativePath = relativePath
    self.expectedSHA256 = expectedSHA256
    self.hunks = hunks
  }
}

public struct ProjectPatchHunk: Equatable, Sendable {
  public let context: String
  public let removals: [String]
  public let additions: [String]

  public init(context: String, removals: [String], additions: [String]) {
    self.context = context
    self.removals = removals
    self.additions = additions
  }
}

public struct ProjectApplyPatchRequest: Equatable, Sendable {
  public let projectID: ProjectID
  public let operations: [ProjectPatchFileOperation]

  public init(projectID: ProjectID, operations: [ProjectPatchFileOperation]) {
    self.projectID = projectID
    self.operations = operations
  }
}

public struct BoundedDiff: Codable, Equatable, Sendable {
  public let removedLines: [String]
  public let addedLines: [String]
  public let truncated: Bool
  public let byteCount: Int

  public init(
    removedLines: [String],
    addedLines: [String],
    truncated: Bool,
    byteCount: Int
  ) {
    self.removedLines = removedLines
    self.addedLines = addedLines
    self.truncated = truncated
    self.byteCount = byteCount
  }

  public static let empty = BoundedDiff(
    removedLines: [], addedLines: [], truncated: false, byteCount: 0)
}

public struct ProjectMutationResult: Codable, Equatable, Sendable {
  public let relativePath: String
  public let destinationRelativePath: String?
  public let operation: String
  public let oldSHA256: String?
  public let newSHA256: String?
  public let byteCount: Int
  public let boundedDiff: BoundedDiff

  public init(
    relativePath: String,
    destinationRelativePath: String? = nil,
    operation: String,
    oldSHA256: String? = nil,
    newSHA256: String? = nil,
    byteCount: Int,
    boundedDiff: BoundedDiff = .empty
  ) {
    self.relativePath = relativePath
    self.destinationRelativePath = destinationRelativePath
    self.operation = operation
    self.oldSHA256 = oldSHA256
    self.newSHA256 = newSHA256
    self.byteCount = byteCount
    self.boundedDiff = boundedDiff
  }
}

public struct ProjectChangesResult: Codable, Equatable, Sendable {
  public let changedFiles: [String]
  public let diff: String
  public let additions: Int
  public let deletions: Int
  public let truncated: Bool
  public let notGitRepository: Bool

  public init(
    changedFiles: [String],
    diff: String,
    additions: Int,
    deletions: Int,
    truncated: Bool,
    notGitRepository: Bool = false
  ) {
    self.changedFiles = changedFiles
    self.diff = diff
    self.additions = additions
    self.deletions = deletions
    self.truncated = truncated
    self.notGitRepository = notGitRepository
  }
}

public enum ProjectMutationError: Error, LocalizedError, Equatable, Sendable {
  case unknownProject
  case writeNotAllowed
  case readNotAllowed
  case forbiddenPath
  case invalidRequest
  case pathExists
  case pathMissing
  case revisionConflict
  case revisionConflictWithContext(
    relativePath: String, currentSHA256: String, boundedDiff: BoundedDiff)
  case pathChanged
  case unsupportedHardLink
  case binaryContent
  case contentTooLarge
  case invalidPatch
  case invalidPatchSyntax
  case patchContextNotFound
  case patchContextNonUnique
  case partialCommit(changedFiles: [String], rollbackStatus: String)
  case durabilityUncertain
  case unsafeFilesystemState
  case notGitRepository

  public var errorDescription: String? {
    switch self {
    case .unknownProject:
      "The project identifier is not registered."
    case .writeNotAllowed:
      "The project does not allow remote writes."
    case .readNotAllowed:
      "The project does not allow remote file reads."
    case .forbiddenPath:
      "The path is blocked by the project policy."
    case .invalidRequest:
      "The mutation request is invalid."
    case .pathExists:
      "The target already exists and cannot be created."
    case .pathMissing:
      "The target does not exist."
    case .revisionConflict:
      "The file content does not match the expected revision."
    case .revisionConflictWithContext:
      "The file content does not match the expected revision."
    case .pathChanged:
      "The target changed after it was validated."
    case .unsupportedHardLink:
      "The target has multiple hard links and cannot be mutated safely."
    case .binaryContent:
      "Only UTF-8 text content is supported."
    case .contentTooLarge:
      "The content exceeds the allowed size."
    case .invalidPatch, .invalidPatchSyntax:
      "The patch syntax is invalid."
    case .patchContextNotFound:
      "The patch context was not found in the current file."
    case .patchContextNonUnique:
      "The patch context matched more than one location."
    case .partialCommit:
      "Some files changed before a write failed; the service attempted a rollback."
    case .durabilityUncertain:
      "The mutation was applied, but its crash durability could not be confirmed. Read the path before retrying."
    case .unsafeFilesystemState:
      "The project changed during the mutation."
    case .notGitRepository:
      "The project is not a Git repository."
    }
  }
}
