import BridgeAgentCore
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
  case duplicateAgentInstallation(AgentInstallationID)
  case duplicateAgentExecutable(providerID: AgentProviderID, canonicalPath: String)
  case unknownAgentInstallation(AgentInstallationID)
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
    case .duplicateAgentInstallation:
      "The Agent installation identifier is already registered."
    case .duplicateAgentExecutable:
      "The Agent executable is already registered for this Provider."
    case .unknownAgentInstallation:
      "The Agent installation is not registered."
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
  public let device: UInt64
  public let inode: UInt64
  public let volumeUUID: String?

  public init(
    canonicalPath: String,
    device: UInt64,
    inode: UInt64,
    volumeUUID: String? = nil
  ) throws {
    guard canonicalPath.hasPrefix("/"),
      canonicalPath.utf8.count <= 16_384,
      !canonicalPath.contains("\0"),
      canonicalPath.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw ServiceStoreError.invalidArgument("project.root")
    }
    self.canonicalPath = canonicalPath
    self.device = device
    self.inode = inode
    if let volumeUUID {
      guard !volumeUUID.isEmpty,
        volumeUUID.utf8.count <= 256,
        !volumeUUID.contains("\0"),
        volumeUUID.rangeOfCharacter(from: .controlCharacters) == nil
      else {
        throw ServiceStoreError.invalidArgument("project.rootVolumeUUID")
      }
    }
    self.volumeUUID = volumeUUID
  }

  public init(capturing url: URL) throws {
    let root = try RegisteredRoot(capturing: url)
    try self.init(
      canonicalPath: root.canonicalPath,
      device: root.identity.device,
      inode: root.identity.inode,
      volumeUUID: try? Self.volumeUUID(atPath: root.canonicalPath)
    )
  }

  public func validateCurrentIdentity() throws {
    let current = try ServiceRootIdentity(
      capturing: URL(fileURLWithPath: canonicalPath, isDirectory: true)
    )
    let matchesStableIdentity: Bool
    if let volumeUUID {
      matchesStableIdentity =
        current.canonicalPath == canonicalPath
        && current.inode == inode
        && current.volumeUUID == volumeUUID
    } else {
      matchesStableIdentity =
        current.canonicalPath == canonicalPath
        && current.device == device
        && current.inode == inode
    }
    guard matchesStableIdentity else {
      throw ServiceStoreError.invalidArgument("project.rootIdentity")
    }
  }

  private static func volumeUUID(atPath path: String) throws -> String? {
    try URL(fileURLWithPath: path, isDirectory: true)
      .resourceValues(forKeys: [.volumeUUIDStringKey])
      .volumeUUIDString
  }
}
