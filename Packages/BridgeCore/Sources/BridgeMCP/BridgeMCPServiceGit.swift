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

  public init(
    commitHash: String? = nil,
    changedFiles: [String] = [],
    summary: String,
    exitCode: Int
  ) {
    self.commitHash = commitHash
    self.changedFiles = changedFiles
    self.summary = summary
    self.exitCode = exitCode
  }

  private enum CodingKeys: String, CodingKey {
    case commitHash = "commit_hash"
    case changedFiles = "changed_files"
    case summary
    case exitCode = "exit_code"
  }
}
