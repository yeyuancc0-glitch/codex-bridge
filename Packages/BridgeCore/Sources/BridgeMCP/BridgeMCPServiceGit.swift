import Foundation

public struct MCPDirectGitCommitRequest: Codable, Equatable, Sendable {
  public let projectID: String
  public let message: String
  public let files: [String]
  public let clientRequestID: String?

  public init(
    projectID: String,
    message: String,
    files: [String] = [],
    clientRequestID: String? = nil
  ) {
    self.projectID = projectID
    self.message = message
    self.files = files
    self.clientRequestID = clientRequestID
  }

  private enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    case message
    case files
    case clientRequestID = "client_request_id"
  }
}
public struct MCPDirectGitCommitReceipt: Codable, Equatable, Sendable {
  public let commitHash: String?
  public let changedFiles: [String]
  public let summary: String
  public let exitCode: Int
  public let indexSynchronized: Bool
  public let indexSynchronizationError: String?

  public init(
    commitHash: String? = nil,
    changedFiles: [String] = [],
    summary: String,
    exitCode: Int,
    indexSynchronized: Bool = true,
    indexSynchronizationError: String? = nil
  ) {
    self.commitHash = commitHash
    self.changedFiles = changedFiles
    self.summary = summary
    self.exitCode = exitCode
    self.indexSynchronized = indexSynchronized
    self.indexSynchronizationError = indexSynchronizationError
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    commitHash = try container.decodeIfPresent(String.self, forKey: .commitHash)
    changedFiles = try container.decode([String].self, forKey: .changedFiles)
    summary = try container.decode(String.self, forKey: .summary)
    exitCode = try container.decode(Int.self, forKey: .exitCode)
    indexSynchronized = try container.decodeIfPresent(Bool.self, forKey: .indexSynchronized) ?? true
    indexSynchronizationError = try container.decodeIfPresent(
      String.self,
      forKey: .indexSynchronizationError
    )
  }

  private enum CodingKeys: String, CodingKey {
    case commitHash = "commit_hash"
    case changedFiles = "changed_files"
    case summary
    case exitCode = "exit_code"
    case indexSynchronized = "index_synchronized"
    case indexSynchronizationError = "index_synchronization_error"
  }
}
