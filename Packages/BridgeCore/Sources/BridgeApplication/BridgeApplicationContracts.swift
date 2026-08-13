import BridgeMCP
import Foundation

public struct CatalogThreadEntry: Equatable, Sendable {
  public let turnID: String
  public let role: String
  public let text: String
  public let status: String?

  public init(turnID: String, role: String, text: String, status: String? = nil) {
    self.turnID = turnID
    self.role = role
    self.text = text
    self.status = status
  }
}

public struct CatalogThread: Equatable, Sendable {
  public let threadID: String
  public let cwd: String
  public let title: String?
  public let status: String
  public let updatedAt: Date?
  public let preview: String?
  public let entries: [CatalogThreadEntry]

  public init(
    threadID: String,
    cwd: String,
    title: String? = nil,
    status: String,
    updatedAt: Date? = nil,
    preview: String? = nil,
    entries: [CatalogThreadEntry] = []
  ) {
    self.threadID = threadID
    self.cwd = cwd
    self.title = title
    self.status = status
    self.updatedAt = updatedAt
    self.preview = preview
    self.entries = entries
  }
}

public struct CatalogThreadPage: Equatable, Sendable {
  public let threads: [CatalogThread]
  public let nextCursor: String?

  public init(threads: [CatalogThread], nextCursor: String? = nil) {
    self.threads = threads
    self.nextCursor = nextCursor
  }
}

public struct CatalogModel: Equatable, Sendable {
  public let id: String
  public let displayName: String
  public let isDefault: Bool
  public let reasoningEfforts: [String]

  public init(
    id: String,
    displayName: String,
    isDefault: Bool,
    reasoningEfforts: [String]
  ) {
    self.id = id
    self.displayName = displayName
    self.isDefault = isDefault
    self.reasoningEfforts = reasoningEfforts
  }
}

public protocol CodexCatalogQuerying: Sendable {
  func listThreads(
    canonicalWorkingDirectories: [String],
    cursor: String?,
    limit: Int,
    search: String?,
    deadline: ContinuousClock.Instant
  ) async throws -> CatalogThreadPage

  func readThread(
    threadID: String,
    includeTurns: Bool,
    deadline: ContinuousClock.Instant
  ) async throws -> CatalogThread

  func listModels(deadline: ContinuousClock.Instant) async throws -> [CatalogModel]
}

public protocol BridgeStatusProviding: Sendable {
  func snapshot(deadline: ContinuousClock.Instant) async throws -> BridgeStatusSnapshot
}

public actor BridgeStatusStore: BridgeStatusProviding {
  private var current: BridgeStatusSnapshot

  public init(initial: BridgeStatusSnapshot) {
    current = initial
  }

  public func update(_ snapshot: BridgeStatusSnapshot) {
    current = snapshot
  }

  public func snapshot(deadline: ContinuousClock.Instant) throws -> BridgeStatusSnapshot {
    guard ContinuousClock.now < deadline else { throw BridgeMCPQueryError.timeout }
    return current
  }
}

public struct TaskArtifactSummary: Equatable, Sendable {
  public let changedFileCount: Int
  public let verificationSummary: String?

  public init(changedFileCount: Int = 0, verificationSummary: String? = nil) {
    self.changedFileCount = changedFileCount
    self.verificationSummary = verificationSummary
  }
}

public protocol TaskArtifactQuerying: Sendable {
  func summary(
    taskID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> TaskArtifactSummary

  func diff(
    taskID: String,
    cursor: String?,
    limit: Int,
    includePatch: Bool,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPTaskDiffPage
}

public struct UnavailableTaskArtifacts: TaskArtifactQuerying {
  public init() {}

  public func summary(
    taskID _: String,
    deadline: ContinuousClock.Instant
  ) throws -> TaskArtifactSummary {
    guard ContinuousClock.now < deadline else { throw BridgeMCPQueryError.timeout }
    return TaskArtifactSummary()
  }

  public func diff(
    taskID _: String,
    cursor _: String?,
    limit _: Int,
    includePatch _: Bool,
    deadline _: ContinuousClock.Instant
  ) throws -> MCPTaskDiffPage {
    throw BridgeMCPQueryError.unavailable
  }
}
