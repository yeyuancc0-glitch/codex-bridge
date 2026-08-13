import Foundation

public protocol GitProjectRootAuthorizing: Sendable {
  func authorizedCanonicalGitRoot(for projectIdentifier: String) async throws -> URL
}

public struct GitEvidenceLimits: Equatable, Sendable {
  public let commandTimeout: Duration
  public let terminationGracePeriod: Duration
  public let maximumStatusBytes: Int
  public let maximumStandardErrorBytes: Int
  public let maximumDiffStatBytes: Int
  public let maximumPatchBytes: Int
  public let maximumPatchPageBytes: Int
  public let maximumFileCount: Int
  public let maximumPathBytes: Int
  public let maximumAggregatePathBytes: Int

  public init(
    commandTimeout: Duration = .seconds(10),
    terminationGracePeriod: Duration = .milliseconds(500),
    maximumStatusBytes: Int = 2 * 1_024 * 1_024,
    maximumStandardErrorBytes: Int = 128 * 1_024,
    maximumDiffStatBytes: Int = 512 * 1_024,
    maximumPatchBytes: Int = 8 * 1_024 * 1_024,
    maximumPatchPageBytes: Int = 200 * 1_024,
    maximumFileCount: Int = 10_000,
    maximumPathBytes: Int = 4_096,
    maximumAggregatePathBytes: Int = 2 * 1_024 * 1_024
  ) {
    self.commandTimeout = commandTimeout
    self.terminationGracePeriod = terminationGracePeriod
    self.maximumStatusBytes = max(1, maximumStatusBytes)
    self.maximumStandardErrorBytes = max(1, maximumStandardErrorBytes)
    self.maximumDiffStatBytes = max(1, maximumDiffStatBytes)
    self.maximumPatchBytes = max(1, maximumPatchBytes)
    self.maximumPatchPageBytes = max(1, maximumPatchPageBytes)
    self.maximumFileCount = max(1, maximumFileCount)
    self.maximumPathBytes = max(1, maximumPathBytes)
    self.maximumAggregatePathBytes = max(1, maximumAggregatePathBytes)
  }
}

public enum GitRepositoryClassification: String, Codable, Equatable, Sendable {
  case gitWorkingTree
  case notGitRepository
}

public enum GitFileChangeKind: String, Codable, Equatable, Sendable {
  case ordinary
  case renamedOrCopied
  case unmerged
  case untracked
}

public struct GitFileChange: Codable, Equatable, Sendable {
  public let kind: GitFileChangeKind
  public let path: String
  public let originalPath: String?
  public let indexStatus: String?
  public let workTreeStatus: String?

  public init(
    kind: GitFileChangeKind,
    path: String,
    originalPath: String? = nil,
    indexStatus: String? = nil,
    workTreeStatus: String? = nil
  ) {
    self.kind = kind
    self.path = path
    self.originalPath = originalPath
    self.indexStatus = indexStatus
    self.workTreeStatus = workTreeStatus
  }
}

public struct GitStatusEvidence: Codable, Equatable, Sendable {
  public let repositoryClassification: GitRepositoryClassification
  public let branch: String?
  public let headCommit: String?
  public let detachedHead: Bool
  public let entries: [GitFileChange]
  public let porcelainV2: Data

  public var isDirty: Bool { !entries.isEmpty }

  public init(
    repositoryClassification: GitRepositoryClassification,
    branch: String?,
    headCommit: String?,
    detachedHead: Bool,
    entries: [GitFileChange],
    porcelainV2: Data
  ) {
    self.repositoryClassification = repositoryClassification
    self.branch = branch
    self.headCommit = headCommit
    self.detachedHead = detachedHead
    self.entries = entries
    self.porcelainV2 = porcelainV2
  }

  public static let notGitRepository = GitStatusEvidence(
    repositoryClassification: .notGitRepository,
    branch: nil,
    headCommit: nil,
    detachedHead: false,
    entries: [],
    porcelainV2: Data()
  )
}

public enum GitChangeAttribution: String, Codable, Equatable, Sendable {
  case attributableFromCleanBaseline
  case mixedWithPreexistingChanges
  case unavailableForNonGitProject
}

public struct GitRootIdentity: Codable, Equatable, Sendable {
  public let device: UInt64
  public let inode: UInt64

  public init(device: UInt64, inode: UInt64) {
    self.device = device
    self.inode = inode
  }
}

public struct GitBaselineEvidence: Codable, Equatable, Sendable {
  public let projectIdentifier: String
  public let canonicalRootPath: String
  public let rootIdentity: GitRootIdentity?
  public let capturedAt: Date
  public let status: GitStatusEvidence
  public let changeAttribution: GitChangeAttribution

  public init(
    projectIdentifier: String,
    canonicalRootPath: String,
    rootIdentity: GitRootIdentity? = nil,
    capturedAt: Date,
    status: GitStatusEvidence,
    changeAttribution: GitChangeAttribution
  ) {
    self.projectIdentifier = projectIdentifier
    self.canonicalRootPath = canonicalRootPath
    self.rootIdentity = rootIdentity
    self.capturedAt = capturedAt
    self.status = status
    self.changeAttribution = changeAttribution
  }
}

public struct GitPatchHandle: Codable, Equatable, Hashable, Sendable {
  public let rawValue: String
  public let totalBytes: Int
  public let isTruncated: Bool

  public init(rawValue: String, totalBytes: Int, isTruncated: Bool) {
    self.rawValue = rawValue
    self.totalBytes = totalBytes
    self.isTruncated = isTruncated
  }
}

public struct GitPatchPage: Equatable, Sendable {
  public let bytes: Data
  public let nextOffset: Int?
  public let totalBytes: Int
  public let isTruncated: Bool

  public init(bytes: Data, nextOffset: Int?, totalBytes: Int, isTruncated: Bool) {
    self.bytes = bytes
    self.nextOffset = nextOffset
    self.totalBytes = totalBytes
    self.isTruncated = isTruncated
  }
}

public struct GitFinalEvidence: Codable, Equatable, Sendable {
  public let projectIdentifier: String
  public let canonicalRootPath: String
  public let capturedAt: Date
  public let status: GitStatusEvidence
  public let diffStat: String
  public let changedFiles: [String]
  public let untrackedFiles: [String]
  public let patch: GitPatchHandle?
  public let changeAttribution: GitChangeAttribution

  public init(
    projectIdentifier: String,
    canonicalRootPath: String,
    capturedAt: Date,
    status: GitStatusEvidence,
    diffStat: String,
    changedFiles: [String],
    untrackedFiles: [String],
    patch: GitPatchHandle?,
    changeAttribution: GitChangeAttribution
  ) {
    self.projectIdentifier = projectIdentifier
    self.canonicalRootPath = canonicalRootPath
    self.capturedAt = capturedAt
    self.status = status
    self.diffStat = diffStat
    self.changedFiles = changedFiles
    self.untrackedFiles = untrackedFiles
    self.patch = patch
    self.changeAttribution = changeAttribution
  }
}

public enum GitEvidenceError: Error, LocalizedError, Equatable, Sendable {
  case invalidAuthorizedRoot
  case repositoryRootMismatch
  case unsafeRepositoryConfiguration
  case unsafeGitAttributes
  case repositoryChangedDuringCapture
  case baselineProjectMismatch
  case commandLaunchFailed
  case commandTimedOut
  case commandOutputLimitExceeded
  case commandFailed(exitCode: Int32, diagnostic: String)
  case malformedGitOutput
  case fileCountLimitExceeded
  case pathByteLimitExceeded
  case aggregatePathByteLimitExceeded
  case patchNotFound
  case invalidPatchCursor
  case patchStoreCapacityExceeded

  public var errorDescription: String? {
    switch self {
    case .invalidAuthorizedRoot:
      "The project registry did not return an existing canonical directory."
    case .repositoryRootMismatch:
      "Git resolved a repository root different from the registered canonical root."
    case .unsafeRepositoryConfiguration:
      "Repository-local Git configuration may execute project-controlled programs."
    case .unsafeGitAttributes:
      "Git attributes request a content filter that is unsafe for evidence collection."
    case .repositoryChangedDuringCapture:
      "The repository changed while Git evidence was being collected."
    case .baselineProjectMismatch:
      "The Git baseline belongs to a different project or registered root."
    case .commandLaunchFailed:
      "The fixed Git process could not be launched."
    case .commandTimedOut:
      "The Git process exceeded its time limit."
    case .commandOutputLimitExceeded:
      "The Git process exceeded a bounded output limit."
    case .commandFailed(let exitCode, let diagnostic):
      "Git exited with code \(exitCode): \(diagnostic)"
    case .malformedGitOutput:
      "Git returned malformed porcelain output."
    case .fileCountLimitExceeded:
      "Git reported more changed files than the configured limit."
    case .pathByteLimitExceeded:
      "A Git path exceeded the configured byte limit."
    case .aggregatePathByteLimitExceeded:
      "Git paths exceeded the configured aggregate byte limit."
    case .patchNotFound:
      "The patch handle does not exist or has expired."
    case .invalidPatchCursor:
      "The patch cursor is outside the stored patch."
    case .patchStoreCapacityExceeded:
      "The bounded patch store has no remaining capacity."
    }
  }
}
