import BridgeDirectCommand
import BridgeMCP
import BridgeProjects
import Foundation

extension BridgeServiceApplication {
  public func serviceProjects(
    cursor: String?,
    limit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectPage {
    try Self.checkDeadline(deadline)
    guard (1...100).contains(limit) else { throw BridgeMCPQueryError.contractRejected }
    let all = try await projects.projects()
    let visible = Self.sortedProjects(all.filter { $0.accessPolicy.read == .allowed })
    let offset = try Self.decodeOffset(cursor, maximum: visible.count)
    let end = min(offset + limit, visible.count)
    let page = visible[offset..<end].map(Self.projectSummary)
    return MCPProjectPage(
      projects: Array(page),
      nextCursor: end < visible.count ? "v1.\(end)" : nil
    )
  }

  public func serviceManagedProjects(
    deadline: ContinuousClock.Instant
  ) async throws -> [MCPProjectSummary] {
    try Self.checkDeadline(deadline)
    return Self.sortedProjects(try await projects.projects()).map(Self.projectSummary)
  }

  public func serviceProject(
    projectID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectDetail {
    try Self.checkDeadline(deadline)
    let project = try await readableProject(projectID)
    return Self.projectDetail(project)
  }

  public func serviceManagedProject(
    projectID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectDetail {
    try Self.checkDeadline(deadline)
    return Self.projectDetail(try await managedProject(projectID))
  }

  public func serviceProjectCommands(
    projectID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectCommands {
    try Self.checkDeadline(deadline)
    let project = try await readableProject(projectID)
    let commands = project.workspaceCommands.map(Self.projectCommand)
    var recommendedUsage: [String: MCPRecommendedCommandUsage] = [:]
    for rule in commandPolicy.effectiveSafeCommandRules {
      guard let key = Self.builtInRecommendationKey(rule) else { continue }
      let argv = [rule.executable] + rule.argumentsPrefix
      let resolution = commandPolicy.resolve(
        project: project,
        request: DirectCommandRequest(
          projectID: project.id,
          commandID: nil,
          argv: argv,
          requiresNetwork: rule.requiresNetwork
        )
      )
      guard resolution.allowed else { continue }
      recommendedUsage[key] = MCPRecommendedCommandUsage(argv: argv)
    }
    for command in commands {
      let resolution = commandPolicy.resolve(
        project: project,
        request: DirectCommandRequest(
          projectID: project.id,
          commandID: command.commandID,
          argv: [command.executable] + command.arguments,
          workingDirectory: command.workingDirectory,
          requiresNetwork: command.requiresNetwork
        )
      )
      guard resolution.allowed else { continue }
      recommendedUsage[command.commandID] = MCPRecommendedCommandUsage(
        commandID: command.commandID,
        argv: [command.executable] + command.arguments,
        workingDirectory: command.workingDirectory
      )
    }
    return MCPProjectCommands(
      commandMode: project.directCommandMode.rawValue,
      builtInCommands: builtInCommands(),
      commands: commands,
      recommendedUsage: recommendedUsage
    )
  }

  private func builtInCommands() -> [MCPBuiltInCommand] {
    commandPolicy.effectiveSafeCommandRules.map { rule in
      return MCPBuiltInCommand(
        executable: rule.executable,
        argumentsPrefix: rule.argumentsPrefix,
        requiresNetwork: rule.requiresNetwork
      )
    }
  }

  private static func builtInRecommendationKey(
    _ rule: DirectCommandPolicy.DirectSafeCommandRule
  ) -> String? {
    let executable = URL(fileURLWithPath: rule.executable).lastPathComponent
    if rule.argumentsPrefix.isEmpty, !["pwd", "ls"].contains(executable) { return nil }
    if ["-project", "-workspace"].contains(rule.argumentsPrefix.last) { return nil }
    let components: [String] = ([executable] + rule.argumentsPrefix).map { component in
      String(
        component.lowercased().map { character in
          character.isLetter || character.isNumber ? character : "_"
        })
    }
    let key = components.joined(separator: "_")
    return key.replacingOccurrences(of: "__", with: "_")
      .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
  }

  public func serviceProjectChanges(
    projectID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectChanges {
    try Self.checkDeadline(deadline)
    let project = try await readableProject(projectID)
    let changes = try await mutations.changes(projectID: project.id)
    return MCPProjectChanges(
      changedFiles: changes.changedFiles,
      diff: Self.safe(changes.diff, maximum: 200 * 1_024),
      additions: changes.additions,
      deletions: changes.deletions,
      truncated: changes.truncated,
      notGitRepository: changes.notGitRepository
    )
  }
}
