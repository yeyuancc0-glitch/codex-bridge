import BridgeDomain
import BridgeProjects
import BridgeServiceCore
import Foundation

public enum DirectCommandDenialReason: Equatable, Sendable {
  case commandModeDenied
  case commandNotRegistered
  case invalidArguments
  case unknownCommand
  case networkNotAllowed
  case writeNotAllowed
}

public struct DirectCommandRequest: Equatable, Sendable {
  public let projectID: ProjectID
  public let commandID: String?
  public let argv: [String]
  public let workingDirectory: String?
  public let requiresNetwork: Bool

  public init(
    projectID: ProjectID,
    commandID: String?,
    argv: [String],
    workingDirectory: String? = nil,
    requiresNetwork: Bool = false
  ) {
    self.projectID = projectID
    self.commandID = commandID
    self.argv = argv
    self.workingDirectory = workingDirectory
    self.requiresNetwork = requiresNetwork
  }
}

public struct DirectCommandResolution: Equatable, Sendable {
  public let allowed: Bool
  public let requiresApproval: Bool
  public let argv: [String]
  public let requiresNetwork: Bool
  public let reason: DirectCommandDenialReason?

  public init(
    allowed: Bool,
    requiresApproval: Bool,
    argv: [String],
    requiresNetwork: Bool,
    reason: DirectCommandDenialReason?
  ) {
    self.allowed = allowed
    self.requiresApproval = requiresApproval
    self.argv = argv
    self.requiresNetwork = requiresNetwork
    self.reason = reason
  }

  public static func denied(_ reason: DirectCommandDenialReason) -> DirectCommandResolution {
    DirectCommandResolution(
      allowed: false,
      requiresApproval: false,
      argv: [],
      requiresNetwork: false,
      reason: reason
    )
  }
}

public struct DirectCommandPolicy: Sendable {
  private let safePrograms: Set<String>

  public init(safePrograms: Set<String> = DirectCommandPolicy.defaultSafePrograms) {
    self.safePrograms = safePrograms
  }

  public static let defaultSafePrograms: Set<String> = [
    "/usr/bin/git", "git",
    "/bin/ls", "/usr/bin/ls", "ls",
    "/bin/pwd", "/usr/bin/pwd", "pwd",
    "/usr/bin/swift", "swift",
    "/usr/bin/xcodebuild", "xcodebuild",
    "/bin/echo", "/usr/bin/echo", "echo",
  ]

  public func resolve(
    project: ServiceProjectRecord,
    request: DirectCommandRequest
  ) -> DirectCommandResolution {
    guard project.directCommandMode != .denied else {
      return .denied(.commandModeDenied)
    }
    let executable = request.argv.first ?? ""
    if request.commandID == nil {
      guard !executable.isEmpty else { return .denied(.invalidArguments) }
    }
    guard request.argv.count <= 128, request.workingDirectory?.utf8.count ?? 0 <= 1_024 else {
      return .denied(.invalidArguments)
    }

    let matched: ServiceWorkspaceCommand?
    if let commandID = request.commandID {
      guard let command = project.workspaceCommands.first(where: { $0.id == commandID }) else {
        return .denied(.unknownCommand)
      }
      guard request.argv.isEmpty || request.argv == [command.executable] + command.arguments else {
        return .denied(.invalidArguments)
      }
      matched = command
    } else {
      matched = project.workspaceCommands.first {
        $0.executable == executable && $0.arguments == Array(request.argv.dropFirst())
      }
    }

    let effectiveArgv: [String]
    let isSafeProgram: Bool
    if let matched {
      effectiveArgv = [matched.executable] + matched.arguments
      isSafeProgram = safePrograms.contains(matched.executable)
    } else {
      effectiveArgv = request.argv
      isSafeProgram = safePrograms.contains(executable)
    }

    switch project.directCommandMode {
    case .denied:
      return .denied(.commandModeDenied)
    case .registered:
      guard matched != nil else { return .denied(.commandNotRegistered) }
    case .safe:
      guard matched != nil || isSafeProgram else { return .denied(.commandNotRegistered) }
    }

    let needsNetwork = matched?.requiresNetwork == true || request.requiresNetwork
    if needsNetwork {
      guard project.accessPolicy.network != .denied else { return .denied(.networkNotAllowed) }
    }
    guard project.accessPolicy.write != .denied else { return .denied(.writeNotAllowed) }

    let risk = matched?.risk ?? .normal
    let requiresApproval =
      risk == .elevated
      || project.accessPolicy.write == .requiresLocalApproval
      || (needsNetwork && project.accessPolicy.network == .requiresLocalApproval)
    return DirectCommandResolution(
      allowed: true,
      requiresApproval: requiresApproval,
      argv: effectiveArgv,
      requiresNetwork: needsNetwork,
      reason: nil
    )
  }
}
