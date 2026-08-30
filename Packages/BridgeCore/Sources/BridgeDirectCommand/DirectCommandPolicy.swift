import BridgeDomain
import BridgeProjects
import BridgeSecurity
import BridgeServiceCore
import Foundation

public enum DirectCommandDenialReason: Equatable, Sendable {
  case commandModeDenied
  case commandNotRegistered
  case invalidArguments
  case unknownCommand
  case networkNotAllowed
  case writeNotAllowed
  case blacklisted
}

public struct DirectCommandRequest: Equatable, Sendable {
  public let projectID: ProjectID
  public let commandID: String?
  public let argv: [String]
  /// The executable resolved by the service before policy evaluation.
  ///
  /// `argv` remains the caller's representation so registered-command matching
  /// stays source-compatible, while the policy evaluates the executable that
  /// will actually be launched.
  public let resolvedExecutable: String?
  public let workingDirectory: String?
  public let requiresNetwork: Bool
  public let isValidatedSkillScript: Bool

  public init(
    projectID: ProjectID,
    commandID: String?,
    argv: [String],
    resolvedExecutable: String? = nil,
    workingDirectory: String? = nil,
    requiresNetwork: Bool = false,
    isValidatedSkillScript: Bool = false
  ) {
    self.projectID = projectID
    self.commandID = commandID
    self.argv = argv
    self.resolvedExecutable = resolvedExecutable
    self.workingDirectory = workingDirectory
    self.requiresNetwork = requiresNetwork
    self.isValidatedSkillScript = isValidatedSkillScript
  }
}

public struct DirectCommandResolution: Equatable, Sendable {
  public let allowed: Bool
  public let requiresApproval: Bool
  public let argv: [String]
  public let workingDirectory: String?
  public let requiresNetwork: Bool
  public let reason: DirectCommandDenialReason?

  public init(
    allowed: Bool,
    requiresApproval: Bool,
    argv: [String],
    workingDirectory: String? = nil,
    requiresNetwork: Bool,
    reason: DirectCommandDenialReason?
  ) {
    self.allowed = allowed
    self.requiresApproval = requiresApproval
    self.argv = argv
    self.workingDirectory = workingDirectory
    self.requiresNetwork = requiresNetwork
    self.reason = reason
  }

  public static func denied(_ reason: DirectCommandDenialReason) -> DirectCommandResolution {
    DirectCommandResolution(
      allowed: false,
      requiresApproval: false,
      argv: [],
      workingDirectory: nil,
      requiresNetwork: false,
      reason: reason
    )
  }
}

struct SafeRule: Equatable {
  let executable: String
  let argumentsPrefix: [String]
  let requiresNetwork: Bool
}

public struct DirectCommandPolicy: Sendable {
  let builtInSafeRules: [SafeRule]
  let builtInResolver: DirectBuiltInCommandResolver
  public let safeCommandRules: [DirectSafeCommandRule]

  public init(builtInSafeRules: [DirectSafeCommandRule] = DirectCommandPolicy.defaultSafeRules) {
    safeCommandRules = builtInSafeRules
    builtInResolver = DirectBuiltInCommandResolver(rules: builtInSafeRules)
    self.builtInSafeRules = builtInSafeRules.map {
      SafeRule(
        executable: $0.executable,
        argumentsPrefix: $0.argumentsPrefix,
        requiresNetwork: $0.requiresNetwork
      )
    }
  }

  /// codexpro-style safe prefixes: a program plus an optional exact argument prefix.
  /// `git status` allows `git status --short` but never `git push`.
  public struct DirectSafeCommandRule: Sendable, Equatable {
    public let executable: String
    public let argumentsPrefix: [String]
    public let requiresNetwork: Bool

    public init(
      executable: String,
      argumentsPrefix: [String] = [],
      requiresNetwork: Bool = false
    ) {
      self.executable = executable
      self.argumentsPrefix = argumentsPrefix
      self.requiresNetwork = requiresNetwork
    }
  }

  public var effectiveSafeCommandRules: [DirectSafeCommandRule] {
    builtInResolver.effectiveRules
  }

  public static let defaultSafeRules: [DirectSafeCommandRule] = [
    DirectSafeCommandRule(executable: "pwd"),
    DirectSafeCommandRule(executable: "/bin/pwd"),
    DirectSafeCommandRule(executable: "ls"),
    DirectSafeCommandRule(executable: "/bin/ls"),
    DirectSafeCommandRule(executable: "/usr/bin/ls"),
    DirectSafeCommandRule(executable: "find", argumentsPrefix: []),
    DirectSafeCommandRule(executable: "/usr/bin/find", argumentsPrefix: []),
    DirectSafeCommandRule(executable: "git", argumentsPrefix: ["status"]),
    DirectSafeCommandRule(executable: "/usr/bin/git", argumentsPrefix: ["status"]),
    DirectSafeCommandRule(executable: "git", argumentsPrefix: ["diff"]),
    DirectSafeCommandRule(executable: "/usr/bin/git", argumentsPrefix: ["diff"]),
    DirectSafeCommandRule(executable: "git", argumentsPrefix: ["log"]),
    DirectSafeCommandRule(executable: "/usr/bin/git", argumentsPrefix: ["log"]),
    DirectSafeCommandRule(executable: "git", argumentsPrefix: ["show"]),
    DirectSafeCommandRule(executable: "/usr/bin/git", argumentsPrefix: ["show"]),
    DirectSafeCommandRule(executable: "git", argumentsPrefix: ["branch"]),
    DirectSafeCommandRule(executable: "/usr/bin/git", argumentsPrefix: ["branch"]),
    DirectSafeCommandRule(executable: "git", argumentsPrefix: ["rev-parse"]),
    DirectSafeCommandRule(executable: "/usr/bin/git", argumentsPrefix: ["rev-parse"]),
    DirectSafeCommandRule(executable: "git", argumentsPrefix: ["ls-files"]),
    DirectSafeCommandRule(executable: "/usr/bin/git", argumentsPrefix: ["ls-files"]),
    DirectSafeCommandRule(executable: "git", argumentsPrefix: ["--version"]),
    DirectSafeCommandRule(executable: "/usr/bin/git", argumentsPrefix: ["--version"]),
    DirectSafeCommandRule(executable: "node", argumentsPrefix: ["--version"]),
    DirectSafeCommandRule(executable: "npm", argumentsPrefix: ["--version"]),
    DirectSafeCommandRule(executable: "npm", argumentsPrefix: ["test"]),
    DirectSafeCommandRule(executable: "npm", argumentsPrefix: ["run", "build"]),
    DirectSafeCommandRule(executable: "npm", argumentsPrefix: ["run", "lint"]),
    DirectSafeCommandRule(executable: "npm", argumentsPrefix: ["run", "typecheck"]),
    DirectSafeCommandRule(executable: "npm", argumentsPrefix: ["run", "test"]),
    DirectSafeCommandRule(executable: "grep"),
    DirectSafeCommandRule(executable: "/usr/bin/grep"),
    DirectSafeCommandRule(executable: "rg"),
    DirectSafeCommandRule(executable: "swift", argumentsPrefix: ["test"]),
    DirectSafeCommandRule(executable: "/usr/bin/swift", argumentsPrefix: ["test"]),
    DirectSafeCommandRule(executable: "swift", argumentsPrefix: ["build"]),
    DirectSafeCommandRule(executable: "/usr/bin/swift", argumentsPrefix: ["build"]),
    DirectSafeCommandRule(executable: "xcodebuild", argumentsPrefix: ["-project"]),
    DirectSafeCommandRule(executable: "/usr/bin/xcodebuild", argumentsPrefix: ["-project"]),
    DirectSafeCommandRule(executable: "xcodebuild", argumentsPrefix: ["-workspace"]),
    DirectSafeCommandRule(executable: "/usr/bin/xcodebuild", argumentsPrefix: ["-workspace"]),
    DirectSafeCommandRule(executable: "echo"),
    DirectSafeCommandRule(executable: "/bin/echo"),
    DirectSafeCommandRule(executable: "/usr/bin/echo"),
  ]

  static let swiftPathOptions: Set<String> = [
    "--package-path", "--cache-path", "--config-path", "--security-path", "--scratch-path",
    "--swift-sdks-path", "--toolset", "--pkg-config-path", "--netrc-file", "--attachments-path",
    "--xunit-output", "--experimental-codesize-profile-output-dir", "--build-path",
    "--index-store-path", "--plugin-path", "--sbom-output-dir", "--sdk", "--toolchain",
    "--swift-sdk",
  ]

  static let xcodebuildPathOptions: Set<String> = [
    "-project", "-workspace", "-xcconfig", "-sdk", "-resultBundlePath", "-resultStreamPath",
    "-clonedSourcePackagesDirPath", "-derivedDataPath", "-archivePath", "-exportOptionsPlist",
    "-codesizeProfileOutputDir", "-exportPath", "-importPath", "-localizationPath", "-xctestrun",
    "-testProductsPath", "-test-enumeration-output-path", "-packageCachePath",
    "-authenticationKeyPath", "-importPlatform",
  ]

  static let xcodebuildResponseFileOptions: Set<String> = [
    "-only-testing", "-skip-testing",
  ]

  static let xcodebuildResponseFilePrefixes: [String] = [
    "-only-testing:", "-skip-testing:", "-only-testing=", "-skip-testing=",
  ]

  static let swiftDeniedOptions: Set<String> = [
    "--disable-sandbox"
  ]

  static let xcodebuildDeniedOptions: Set<String> = [
    "-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration",
  ]
}
