import BridgeDomain
import Foundation

public struct ProjectFileLimits: Equatable, Sendable {
  public let maximumFileBytes: Int
  public let maximumResponseBytes: Int
  public let defaultSearchMatches: Int
  public let maximumSearchMatches: Int
  public let maximumCandidateFiles: Int
  public let maximumEnumeratedEntries: Int
  public let maximumDirectoryDepth: Int
  public let maximumSearchBytes: Int
  public let maximumScannedLines: Int

  public init(
    maximumFileBytes: Int = 200 * 1_024,
    maximumResponseBytes: Int = 200 * 1_024,
    defaultSearchMatches: Int = 50,
    maximumSearchMatches: Int = 200,
    maximumCandidateFiles: Int = 20_000,
    maximumEnumeratedEntries: Int = 100_000,
    maximumDirectoryDepth: Int = 64,
    maximumSearchBytes: Int = 20 * 1_024 * 1_024,
    maximumScannedLines: Int = 1_000_000
  ) throws {
    guard
      maximumFileBytes > 0,
      maximumResponseBytes > 0,
      defaultSearchMatches > 0,
      defaultSearchMatches <= maximumSearchMatches,
      maximumSearchMatches <= 1_000,
      maximumCandidateFiles > 0,
      maximumEnumeratedEntries >= maximumCandidateFiles,
      maximumDirectoryDepth > 0,
      maximumSearchBytes >= maximumFileBytes,
      maximumScannedLines > 0
    else {
      throw ProjectFileError.invalidLimits
    }
    self.init(
      uncheckedMaximumFileBytes: maximumFileBytes,
      maximumResponseBytes: maximumResponseBytes,
      defaultSearchMatches: defaultSearchMatches,
      maximumSearchMatches: maximumSearchMatches,
      maximumCandidateFiles: maximumCandidateFiles,
      maximumEnumeratedEntries: maximumEnumeratedEntries,
      maximumDirectoryDepth: maximumDirectoryDepth,
      maximumSearchBytes: maximumSearchBytes,
      maximumScannedLines: maximumScannedLines
    )
  }

  public static let `default` = ProjectFileLimits(
    uncheckedMaximumFileBytes: 200 * 1_024,
    maximumResponseBytes: 200 * 1_024,
    defaultSearchMatches: 50,
    maximumSearchMatches: 200,
    maximumCandidateFiles: 20_000,
    maximumEnumeratedEntries: 100_000,
    maximumDirectoryDepth: 64,
    maximumSearchBytes: 20 * 1_024 * 1_024,
    maximumScannedLines: 1_000_000
  )

  private init(
    uncheckedMaximumFileBytes maximumFileBytes: Int,
    maximumResponseBytes: Int,
    defaultSearchMatches: Int,
    maximumSearchMatches: Int,
    maximumCandidateFiles: Int,
    maximumEnumeratedEntries: Int,
    maximumDirectoryDepth: Int,
    maximumSearchBytes: Int,
    maximumScannedLines: Int
  ) {
    self.maximumFileBytes = maximumFileBytes
    self.maximumResponseBytes = maximumResponseBytes
    self.defaultSearchMatches = defaultSearchMatches
    self.maximumSearchMatches = maximumSearchMatches
    self.maximumCandidateFiles = maximumCandidateFiles
    self.maximumEnumeratedEntries = maximumEnumeratedEntries
    self.maximumDirectoryDepth = maximumDirectoryDepth
    self.maximumSearchBytes = maximumSearchBytes
    self.maximumScannedLines = maximumScannedLines
  }
}

public struct FileLineRange: Codable, Equatable, Sendable {
  public let startLine: Int
  public let lineCount: Int

  public init(startLine: Int = 1, lineCount: Int = 300) throws {
    guard startLine > 0, lineCount > 0, lineCount <= 300 else {
      throw ProjectFileError.invalidLineRange
    }
    self.startLine = startLine
    self.lineCount = lineCount
  }

  public static let maximum = FileLineRange(uncheckedStartLine: 1, lineCount: 300)

  private init(uncheckedStartLine startLine: Int, lineCount: Int) {
    self.startLine = startLine
    self.lineCount = lineCount
  }
}

public struct ProjectFileReadRequest: Equatable, Sendable {
  public let projectID: ProjectID
  public let relativePath: String
  public let lineRange: FileLineRange

  public init(
    projectID: ProjectID,
    relativePath: String,
    lineRange: FileLineRange = .maximum
  ) {
    self.projectID = projectID
    self.relativePath = relativePath
    self.lineRange = lineRange
  }
}

public struct FileRevision: Codable, Equatable, Sendable {
  public let sha256: String
  public let byteCount: Int

  public init(sha256: String, byteCount: Int) {
    self.sha256 = sha256
    self.byteCount = byteCount
  }

  public var value: String { "sha256:\(sha256)" }
}

public struct ProjectFileReadResult: Codable, Equatable, Sendable {
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
}

public struct ProjectFileSearchRequest: Equatable, Sendable {
  public let projectID: ProjectID
  public let query: String
  public let relativeDirectory: String?
  public let caseSensitive: Bool
  public let limit: Int?
  public let cursor: String?

  public init(
    projectID: ProjectID,
    query: String,
    relativeDirectory: String? = nil,
    caseSensitive: Bool = false,
    limit: Int? = nil,
    cursor: String? = nil
  ) throws {
    guard
      !query.isEmpty,
      query.utf8.count <= 512,
      !query.contains("\0"),
      query.rangeOfCharacter(from: .newlines) == nil,
      cursor?.utf8.count ?? 0 <= 128
    else {
      throw ProjectFileError.invalidSearchRequest
    }
    self.projectID = projectID
    self.query = query
    self.relativeDirectory = relativeDirectory
    self.caseSensitive = caseSensitive
    self.limit = limit
    self.cursor = cursor
  }
}

public struct ProjectFileSearchMatch: Codable, Equatable, Sendable {
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
}

public struct ProjectFileSearchResult: Codable, Equatable, Sendable {
  public let matches: [ProjectFileSearchMatch]
  public let nextCursor: String?
  public let skippedFileCount: Int
  public let usedTrackedPathPriority: Bool

  public init(
    matches: [ProjectFileSearchMatch],
    nextCursor: String?,
    skippedFileCount: Int,
    usedTrackedPathPriority: Bool
  ) {
    self.matches = matches
    self.nextCursor = nextCursor
    self.skippedFileCount = skippedFileCount
    self.usedTrackedPathPriority = usedTrackedPathPriority
  }
}

public enum ProjectFileError: Error, LocalizedError, Equatable, Sendable {
  case invalidLimits
  case unknownProject
  case readNotAllowed
  case invalidLineRange
  case invalidSearchRequest
  case invalidCursor
  case forbiddenPath
  case candidateLimitExceeded
  case enumerationLimitExceeded
  case directoryDepthExceeded
  case pathLengthExceeded
  case lineTooLong(maximumBytes: Int)
  case responseLimitExceeded
  case unsafeFilesystemState

  public var errorDescription: String? {
    switch self {
    case .invalidLimits:
      "File-service limits are invalid."
    case .unknownProject:
      "The project identifier is not registered."
    case .readNotAllowed:
      "The project does not allow remote file reads."
    case .invalidLineRange:
      "A file read can return at most 300 lines from a positive line number."
    case .invalidSearchRequest:
      "The search query, scope, cursor, or match limit is invalid."
    case .invalidCursor:
      "The search cursor does not belong to this query."
    case .forbiddenPath:
      "The path is blocked by the project policy."
    case .candidateLimitExceeded:
      "The project contains too many candidate files for one search."
    case .enumerationLimitExceeded:
      "The project enumeration limit was exceeded."
    case .directoryDepthExceeded:
      "The project directory depth limit was exceeded."
    case .pathLengthExceeded:
      "A project-relative path exceeded the safe length limit."
    case .lineTooLong(let maximumBytes):
      "A text line exceeds the \(maximumBytes)-byte return limit."
    case .responseLimitExceeded:
      "The bounded response cannot contain even one result."
    case .unsafeFilesystemState:
      "The project changed during secure enumeration."
    }
  }
}
