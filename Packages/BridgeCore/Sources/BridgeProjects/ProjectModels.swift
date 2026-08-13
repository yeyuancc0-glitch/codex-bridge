import BridgeDomain
import BridgeSecurity
import Foundation

public struct ProjectPermission: RawRepresentable, Codable, Equatable, Hashable, Sendable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public static let denied = ProjectPermission(rawValue: "denied")
  public static let requiresLocalApproval = ProjectPermission(
    rawValue: "requiresLocalApproval")
  public static let allowed = ProjectPermission(rawValue: "allowed")
}

public struct ProjectAccessPolicy: Codable, Equatable, Sendable {
  public let read: ProjectPermission
  public let write: ProjectPermission
  public let network: ProjectPermission

  public init(
    read: ProjectPermission = .allowed,
    write: ProjectPermission = .requiresLocalApproval,
    network: ProjectPermission = .denied
  ) {
    self.read = read
    self.write = write
    self.network = network
  }
}

public struct VerificationCommand: Codable, Equatable, Sendable {
  public let executable: String
  public let arguments: [String]

  public init(executable: String, arguments: [String] = []) throws {
    guard Self.isValidExecutable(executable) else {
      throw ProjectRegistryError.invalidVerificationCommand
    }
    guard arguments.count <= 128, arguments.allSatisfy(Self.isValidArgument) else {
      throw ProjectRegistryError.invalidVerificationCommand
    }
    self.executable = executable
    self.arguments = arguments
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      executable: container.decode(String.self, forKey: .executable),
      arguments: container.decode([String].self, forKey: .arguments)
    )
  }

  private enum CodingKeys: String, CodingKey {
    case executable
    case arguments
  }

  private static func isValidExecutable(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed == value && !value.isEmpty && value.utf8.count <= 1_024
      && !value.contains("\0") && value.rangeOfCharacter(from: .newlines) == nil
  }

  private static func isValidArgument(_ value: String) -> Bool {
    value.utf8.count <= 4_096 && !value.contains("\0")
      && value.rangeOfCharacter(from: .newlines) == nil
  }
}

public struct ForbiddenPathPattern: Codable, Equatable, Hashable, Sendable {
  public let value: String

  public init(_ value: String) throws {
    let components = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard
      !value.isEmpty,
      value.utf8.count <= 512,
      value == value.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.hasPrefix("/"),
      !value.hasPrefix("~"),
      !value.contains("\0"),
      !value.contains("\\"),
      value.rangeOfCharacter(from: .controlCharacters) == nil,
      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
      components.allSatisfy({ $0 == "**" || !$0.contains("**") })
    else {
      throw ProjectRegistryError.invalidForbiddenPattern
    }
    self.value = value
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    try self.init(container.decode(String.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(value)
  }
}

public struct LocalProjectRegistration: Sendable {
  public let name: String
  public let rootURL: URL
  public let repositoryRootURL: URL?
  public let accessPolicy: ProjectAccessPolicy
  public let verificationCommands: [VerificationCommand]
  public let forbiddenPatterns: [ForbiddenPathPattern]

  public init(
    name: String,
    rootURL: URL,
    repositoryRootURL: URL? = nil,
    accessPolicy: ProjectAccessPolicy = .init(),
    verificationCommands: [VerificationCommand] = [],
    forbiddenPatterns: [ForbiddenPathPattern] = []
  ) throws {
    let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedName.isEmpty, normalizedName.count <= 100,
      normalizedName.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw ProjectRegistryError.invalidName
    }
    self.name = normalizedName
    self.rootURL = rootURL
    self.repositoryRootURL = repositoryRootURL
    self.accessPolicy = accessPolicy
    self.verificationCommands = verificationCommands
    self.forbiddenPatterns = forbiddenPatterns
  }
}

public struct RegisteredProject: Codable, Equatable, Sendable {
  public let id: ProjectID
  public let name: String
  public let primaryRoot: RegisteredRoot
  public let repositoryRoot: RegisteredRoot
  public let worktreeRoots: [RegisteredRoot]
  public let accessPolicy: ProjectAccessPolicy
  public let verificationCommands: [VerificationCommand]
  public let forbiddenPatterns: [ForbiddenPathPattern]
  public let createdAt: Date

  public init(
    id: ProjectID,
    name: String,
    primaryRoot: RegisteredRoot,
    repositoryRoot: RegisteredRoot,
    worktreeRoots: [RegisteredRoot] = [],
    accessPolicy: ProjectAccessPolicy,
    verificationCommands: [VerificationCommand],
    forbiddenPatterns: [ForbiddenPathPattern],
    createdAt: Date
  ) {
    self.id = id
    self.name = name
    self.primaryRoot = primaryRoot
    self.repositoryRoot = repositoryRoot
    self.worktreeRoots = worktreeRoots
    self.accessPolicy = accessPolicy
    self.verificationCommands = verificationCommands
    self.forbiddenPatterns = forbiddenPatterns
    self.createdAt = createdAt
  }

  public func addingWorktree(_ root: RegisteredRoot) -> RegisteredProject {
    RegisteredProject(
      id: id,
      name: name,
      primaryRoot: primaryRoot,
      repositoryRoot: repositoryRoot,
      worktreeRoots: worktreeRoots + [root],
      accessPolicy: accessPolicy,
      verificationCommands: verificationCommands,
      forbiddenPatterns: forbiddenPatterns,
      createdAt: createdAt
    )
  }

  public func updatingAccessPolicy(_ policy: ProjectAccessPolicy) -> RegisteredProject {
    RegisteredProject(
      id: id,
      name: name,
      primaryRoot: primaryRoot,
      repositoryRoot: repositoryRoot,
      worktreeRoots: worktreeRoots,
      accessPolicy: policy,
      verificationCommands: verificationCommands,
      forbiddenPatterns: forbiddenPatterns,
      createdAt: createdAt
    )
  }

  public func replacingSingleRoot(_ root: RegisteredRoot) -> RegisteredProject {
    RegisteredProject(
      id: id,
      name: name,
      primaryRoot: root,
      repositoryRoot: root,
      accessPolicy: accessPolicy,
      verificationCommands: verificationCommands,
      forbiddenPatterns: forbiddenPatterns,
      createdAt: createdAt
    )
  }

  public func validateCurrentRoots() throws {
    try primaryRoot.validateCurrentIdentity()
    try repositoryRoot.validateCurrentIdentity()
    for worktree in worktreeRoots {
      try worktree.validateCurrentIdentity()
    }
  }
}

public struct ProjectCapabilitiesDTO: Codable, Equatable, Sendable {
  public let read: ProjectPermission
  public let write: ProjectPermission
  public let network: ProjectPermission

  public init(policy: ProjectAccessPolicy) {
    read = policy.read
    write = policy.write
    network = policy.network
  }
}

public struct ProjectSummaryDTO: Codable, Equatable, Sendable {
  public let id: ProjectID
  public let name: String
  public let capabilities: ProjectCapabilitiesDTO

  public init(project: RegisteredProject) {
    id = project.id
    name = project.name
    capabilities = ProjectCapabilitiesDTO(policy: project.accessPolicy)
  }
}

public enum ProjectRegistryError: Error, LocalizedError, Equatable, Sendable {
  case invalidName
  case invalidVerificationCommand
  case invalidForbiddenPattern
  case duplicateRoot
  case duplicateProjectID
  case unknownProject
  case removalUnsupported
  case rootRebindingUnsupported
  case rootSelectionMismatch
  case repositoryDoesNotContainProject
  case workingDirectoryOutsideProject

  public var errorDescription: String? {
    switch self {
    case .invalidName:
      "The project name is invalid."
    case .invalidVerificationCommand:
      "The verification command must be a bounded argv array."
    case .invalidForbiddenPattern:
      "The forbidden path pattern is invalid."
    case .duplicateRoot:
      "The project root is already registered."
    case .duplicateProjectID:
      "The project identifier is already registered."
    case .unknownProject:
      "The project identifier is not registered."
    case .removalUnsupported:
      "The project repository does not support safe removal."
    case .rootRebindingUnsupported:
      "Only projects with one shared project and repository root can be safely reconnected."
    case .rootSelectionMismatch:
      "The selected directory does not match the project's registered path."
    case .repositoryDoesNotContainProject:
      "The repository root does not contain the project root."
    case .workingDirectoryOutsideProject:
      "The working directory is not an exact registered project or worktree root."
    }
  }
}
