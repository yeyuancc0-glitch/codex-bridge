import Foundation

public struct CodexProjectRoot: Codable, Equatable, Sendable {
  public let path: String

  public init(path: String) {
    self.path = path
  }
}

public struct CodexProject: Codable, Equatable, Sendable {
  public let id: String
  public let name: String
  public let roots: [CodexProjectRoot]
  public let metadata: [String: String]
  public let position: Int64
  public let createdAt: Int64
  public let updatedAt: Int64
}

public struct ProjectListParams: Codable, Equatable, Sendable {
  public let cursor: String?
  public let limit: UInt32?

  public init(cursor: String? = nil, limit: UInt32? = nil) {
    self.cursor = cursor
    self.limit = limit
  }
}

public struct ProjectListResponse: Codable, Equatable, Sendable {
  public let data: [CodexProject]
  public let nextCursor: String?
}

public struct ProjectCreateParams: Codable, Equatable, Sendable {
  public let idempotencyKey: String
  public let name: String
  public let roots: [CodexProjectRoot]
  public let metadata: [String: String]?

  public init(
    idempotencyKey: String,
    name: String,
    roots: [CodexProjectRoot],
    metadata: [String: String]? = nil
  ) {
    self.idempotencyKey = idempotencyKey
    self.name = name
    self.roots = roots
    self.metadata = metadata
  }
}

public struct ProjectCreateResponse: Codable, Equatable, Sendable {
  public let project: CodexProject
}

public struct ThreadMetadataUpdateParams: Codable, Equatable, Sendable {
  public let threadId: String
  public let projectId: String

  public init(threadId: String, projectId: String) {
    self.threadId = threadId
    self.projectId = projectId
  }
}

public struct ThreadMetadataUpdateResponse: Codable, Equatable, Sendable {
  public let thread: CodexThread
}
