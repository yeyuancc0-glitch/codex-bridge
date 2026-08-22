import BridgeDomain
import BridgeSecurity
import Foundation

public enum ServiceStoreError: Error, Equatable, LocalizedError, Sendable {
  case invalidArgument(String)
  case corruptSchema
  case corruptRecord
  case unsupportedSchemaVersion(Int64)
  case duplicateProject(ProjectID)
  case duplicateProjectRoot(String)
  case unknownProject(ProjectID)
  case duplicateTask(TaskID)
  case unknownTask(TaskID)
  case activeWriteTaskExists(ProjectID)
  case idempotencyConflict(source: ServiceTaskSource, clientRequestID: String)
  case immutableTaskChanged(TaskID)
  case invalidTaskTransition(from: ServiceTaskStatus, to: ServiceTaskStatus)
  case storageFailure

  public var errorDescription: String? {
    switch self {
    case .invalidArgument(let field):
      "The service value is invalid: \(field)."
    case .corruptSchema:
      "The service database schema is corrupt."
    case .corruptRecord:
      "The service database contains an invalid record."
    case .unsupportedSchemaVersion(let version):
      "The service database schema version is unsupported: \(version)."
    case .duplicateProject:
      "The project identifier is already registered."
    case .duplicateProjectRoot:
      "The project root is already registered."
    case .unknownProject:
      "The project is not registered."
    case .duplicateTask:
      "The task identifier is already in use."
    case .unknownTask:
      "The task does not exist."
    case .activeWriteTaskExists:
      "The project already has an active write task."
    case .idempotencyConflict:
      "The client request identifier was reused with a different task."
    case .immutableTaskChanged:
      "Immutable task fields cannot be changed."
    case .invalidTaskTransition(let source, let destination):
      "The task cannot transition from \(source.rawValue) to \(destination.rawValue)."
    case .storageFailure:
      "The service database operation failed."
    }
  }
}

public struct ServiceRootIdentity: Codable, Equatable, Hashable, Sendable {
  public let canonicalPath: String
  public let identity: FileSystemIdentity

  public init(canonicalPath: String, identity: FileSystemIdentity) throws {
    guard !canonicalPath.isEmpty,
      canonicalPath.utf8.count <= 16_384,
      !canonicalPath.contains("\0"),
      canonicalPath.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw ServiceStoreError.invalidArgument("project.root")
    }
    self.canonicalPath = canonicalPath
    self.identity = identity
  }

  public init(capturing url: URL) throws {
    let root = try RegisteredRoot(capturing: url)
    try self.init(canonicalPath: root.canonicalPath, identity: root.identity)
  }

  public func validateCurrentIdentity() throws {
    let current = try ServiceRootIdentity(
      capturing: URL(fileURLWithPath: canonicalPath, isDirectory: true)
    )
    guard current == self else {
      throw ServiceStoreError.invalidArgument("project.rootIdentity")
    }
  }
}
