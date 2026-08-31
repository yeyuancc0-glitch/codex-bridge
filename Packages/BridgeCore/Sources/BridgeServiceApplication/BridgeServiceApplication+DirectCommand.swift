import BridgeAgentCore
import BridgeDirectCommand
import BridgeMCP
import BridgeSecurity
import BridgeServiceCore
import Foundation

private struct DirectCommandApprovalPayload: Encodable {
  let request: MCPDirectExecRequest
  let resolvedArgv: [String]
  let executableIdentity: DirectExecutableIdentity?
}

private struct DirectExecutableIdentity: Codable, Equatable, Sendable {
  let device: UInt64
  let inode: UInt64

  static func read(atPath path: String) -> DirectExecutableIdentity? {
    guard
      let attributes = try? FileManager.default.attributesOfItem(atPath: path),
      let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
      let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
    else { return nil }
    return DirectExecutableIdentity(device: device, inode: inode)
  }
}

extension BridgeServiceApplication {
  package func shutdownDirectOperations() async {
    await directCommands.cancelAll()
    await approvals.cancelAll()
  }

  public func serviceDirectExecCommand(
    _ request: MCPDirectExecRequest,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectCommandReceipt {
    try await serviceDirectExecCommand(
      request, deadline: deadline, isValidatedSkillScript: false, requiresNetwork: false,
      denyNetwork: false
    )
  }

  func serviceDirectExecCommand(
    _ request: MCPDirectExecRequest,
    deadline: ContinuousClock.Instant,
    isValidatedSkillScript: Bool,
    requiresNetwork: Bool,
    denyNetwork: Bool
  ) async throws -> MCPDirectCommandReceipt {
    try Self.checkDeadline(deadline)
    guard request.timeoutMS > 0, request.timeoutMS <= 3_600_000,
      request.yieldTimeMS >= 0, request.yieldTimeMS <= 60_000
    else {
      throw BridgeMCPQueryError.contractRejected
    }
    let project = try await writableProject(request.projectID)
    let unresolvedPolicyRequest = DirectCommandRequest(
      projectID: project.id,
      commandID: request.commandID,
      argv: request.argv,
      workingDirectory: request.workingDirectory,
      requiresNetwork: requiresNetwork,
      isValidatedSkillScript: isValidatedSkillScript
    )
    let resolvedExecutable: String?
    if let builtInExecutable = commandPolicy.preferredSystemBuiltInExecutable(
      project: project,
      request: unresolvedPolicyRequest
    ) {
      resolvedExecutable = builtInExecutable
    } else {
      resolvedExecutable = try Self.resolvedExecutableForPolicy(
        request: request,
        project: project
      )
    }
    let resolution = commandPolicy.resolve(
      project: project,
      request: DirectCommandRequest(
        projectID: project.id,
        commandID: request.commandID,
        argv: request.argv,
        resolvedExecutable: resolvedExecutable,
        workingDirectory: request.workingDirectory,
        requiresNetwork: requiresNetwork,
        isValidatedSkillScript: isValidatedSkillScript
      )
    )
    guard resolution.allowed else {
      throw BridgeMCPQueryError.commandDenied(
        Self.commandDenialReason(resolution.reason).rawValue
      )
    }
    let workingDirectory = try Self.resolvedWorkingDirectory(
      project: project,
      relative: resolution.workingDirectory
    )
    let launchArgv = try Self.resolvedLaunchArgv(resolution.argv, project: project)
    let approvalPayload = DirectCommandApprovalPayload(
      request: request,
      resolvedArgv: launchArgv,
      executableIdentity: launchArgv.first.flatMap(DirectExecutableIdentity.read(atPath:))
    )
    try await requireDirectApproval(
      project: project,
      kind: resolution.requiresNetwork ? .network : .command,
      summary: "Run \(launchArgv.joined(separator: " "))",
      payload: approvalPayload,
      clientRequestID: request.clientRequestID
    )
    guard
      approvalPayload.resolvedArgv == launchArgv,
      approvalPayload.executableIdentity
        == launchArgv.first.flatMap(DirectExecutableIdentity.read(atPath:))
    else {
      throw BridgeMCPQueryError.pathChanged
    }
    let sessionID = "dcmd-\(UUID().uuidString)"
    let lease = try await acquireDirectLease(
      project: project,
      owner: .directCommand(sessionID: sessionID)
    )
    var launched = false
    do {
      _ = try await directCommands.launch(
        sessionID: sessionID,
        projectID: project.id,
        argv: launchArgv,
        workingDirectory: workingDirectory,
        requiresNetwork: resolution.requiresNetwork,
        usePTY: request.tty,
        timeout: .milliseconds(request.timeoutMS),
        denyNetwork: denyNetwork || !resolution.requiresNetwork
          || project.accessPolicy.network == .denied,
        onExit: { await lease.release() }
      )
      launched = true
      let requestedYieldDeadline = ContinuousClock.now.advanced(
        by: .milliseconds(request.yieldTimeMS)
      )
      let yieldDeadline = requestedYieldDeadline < deadline ? requestedYieldDeadline : deadline
      while ContinuousClock.now < yieldDeadline {
        try Task.checkCancellation()
        if let session = await directCommands.snapshot(sessionID: sessionID),
          session.status != "running"
        {
          break
        }
        try await Task.sleep(for: .milliseconds(20))
      }
      try Self.checkDeadline(deadline)
      return try await receipt(for: sessionID)
    } catch is CancellationError {
      if launched { await stopDirectSession(sessionID) }
      await lease.release()
      throw CancellationError()
    } catch let error as BridgeMCPQueryError {
      if launched { await stopDirectSession(sessionID) }
      await lease.release()
      throw error
    } catch {
      if launched { await stopDirectSession(sessionID) }
      await lease.release()
      throw Self.publicCommandError(error)
    }
  }

  private func stopDirectSession(_ sessionID: String) async {
    try? await directCommands.interrupt(sessionID: sessionID)
  }

  private static func resolvedExecutableForPolicy(
    request: MCPDirectExecRequest,
    project: ServiceProjectRecord
  ) throws -> String? {
    let requestedExecutable =
      request.argv.first
      ?? request.commandID.flatMap { commandID in
        project.workspaceCommands.first(where: { $0.id == commandID })?.executable
      }
    guard let requestedExecutable, !requestedExecutable.isEmpty else { return nil }
    guard
      let resolved = try resolvedLaunchArgv(
        [requestedExecutable],
        project: project,
        allowUnresolvedBareExecutable: true
      ).first,
      AgentPathSemantics.isAbsolute(resolved, style: .current)
    else { return nil }
    return resolved
  }

  private func receipt(for sessionID: String) async throws -> MCPDirectCommandReceipt {
    guard let session = await directCommands.snapshot(sessionID: sessionID) else {
      throw BridgeMCPQueryError.commandSessionNotFound
    }
    return MCPDirectCommandReceipt(
      sessionID: session.sessionID,
      status: session.status,
      exitCode: session.exitCode.map(Int.init),
      startedAt: iso8601.string(from: session.startedAt),
      output: Self.output(session)
    )
  }

  static func mcpEnvironment(
    _ environment: DirectExecutionEnvironmentCapabilities
  ) -> MCPExecutionEnvironment {
    let directDefault = environment.commandEnvironment(denyNetwork: true)
    #if os(Windows)
      let childNetworkPolicy = directDefault.childNetworkPolicy
    #else
      let childNetworkPolicy = "denied_by_default"
    #endif
    return MCPExecutionEnvironment(
      bridgeSandbox: directDefault.bridgeSandbox,
      scope: "direct_default",
      sandboxExec: directDefault.sandboxExec,
      nestedSandbox: directDefault.nestedSandbox,
      loopback: directDefault.loopback,
      childNetworkPolicy: childNetworkPolicy,
      xcodebuildNestedSandbox: directDefault.xcodebuildNestedSandbox,
      loopbackBind: directDefault.loopbackBind,
      limitations: directDefault.limitations
    )
  }

  static func commandDenialReason(_ reason: DirectCommandDenialReason?) -> MCPCommandDenialReason {
    switch reason {
    case .commandModeDenied: .commandModeDenied
    case .commandNotRegistered, .unknownCommand: .commandNotRegistered
    case .invalidArguments, nil: .invalidArguments
    case .networkNotAllowed: .networkDenied
    case .writeNotAllowed: .writeDenied
    case .blacklisted: .blacklisted
    }
  }

  static func publicCommandError(_ error: Error) -> BridgeMCPQueryError {
    switch error {
    case let error as DirectCommandSessionError:
      switch error {
      case .sessionNotFound:
        return .commandSessionNotFound
      case .notRunning:
        return .commandSessionNotRunning
      case .projectBusy:
        return .busy
      case .invalidStdin:
        return .contractRejected
      }
    case let error as DirectProcessError:
      switch error {
      case .invalidArgument:
        return .contractRejected
      case .processLaunchFailed:
        return .processLaunchFailed
      case .stdinUnavailable:
        return .commandSessionNotFound
      case .sandboxUnavailable:
        return .networkIsolationUnavailable
      }
    default:
      return .unavailable
    }
  }
}
