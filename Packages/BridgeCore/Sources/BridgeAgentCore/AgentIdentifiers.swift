import Foundation

public protocol AgentStringIdentifier: RawRepresentable, Codable, Hashable, Sendable
where RawValue == String {}

public struct AgentProviderID: AgentStringIdentifier {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public static let codex = AgentProviderID(rawValue: "codex")
  public static let openCode = AgentProviderID(rawValue: "opencode")
  public static let deepSeekHarness = AgentProviderID(rawValue: "deepseek-harness")
}

public struct AgentInstallationID: AgentStringIdentifier {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

public enum AgentInstallationArtifactRole: String, Codable, CaseIterable, Hashable, Sendable {
  case launchConfiguration = "launch_configuration"
  case runtimeManifest = "runtime_manifest"
  case dependencyLock = "dependency_lock"
  case nodeInterpreter = "node_interpreter"

  public var requiresExecutable: Bool {
    self == .nodeInterpreter
  }
}

public struct AgentInstallationArtifact: Codable, Equatable, Sendable {
  public let role: AgentInstallationArtifactRole
  public let canonicalPath: String
  public let device: UInt64
  public let inode: UInt64
  public let fileSize: UInt64
  public let modificationTimeNanoseconds: Int64
  public let sha256: String

  public init(
    role: AgentInstallationArtifactRole,
    canonicalPath: String,
    device: UInt64,
    inode: UInt64,
    fileSize: UInt64,
    modificationTimeNanoseconds: Int64,
    sha256: String
  ) {
    self.role = role
    self.canonicalPath = canonicalPath
    self.device = device
    self.inode = inode
    self.fileSize = fileSize
    self.modificationTimeNanoseconds = modificationTimeNanoseconds
    self.sha256 = sha256
  }

  public var path: String { canonicalPath }
}

public struct AgentProfileID: AgentStringIdentifier {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}
