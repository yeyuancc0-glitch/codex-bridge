import BridgePolicy
import BridgeProjects
import BridgeSecurity
import Foundation

public struct VerificationRunnerConfiguration: Sendable {
  package let timeout: Duration
  package let terminationGracePeriod: Duration
  package let maximumStandardOutputBytes: Int
  package let maximumStandardErrorBytes: Int

  public init(
    timeout: Duration = .seconds(120),
    terminationGracePeriod: Duration = .seconds(1),
    maximumStandardOutputBytes: Int = 256 * 1_024,
    maximumStandardErrorBytes: Int = 256 * 1_024
  ) {
    self.timeout = min(max(timeout, .milliseconds(1)), .seconds(300))
    self.terminationGracePeriod = min(max(terminationGracePeriod, .zero), .seconds(2))
    self.maximumStandardOutputBytes = min(max(maximumStandardOutputBytes, 1), 1_048_576)
    self.maximumStandardErrorBytes = min(max(maximumStandardErrorBytes, 1), 1_048_576)
  }
}

public struct VerificationRunner: Sendable {
  private static let environment = [
    "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
    "LANG=C",
    "LC_ALL=C",
    "NO_COLOR=1",
    "TERM=dumb",
    "TMPDIR=/tmp",
  ]

  private let configuration: VerificationRunnerConfiguration
  private let processRunner = BoundedVerificationProcessRunner()

  public init(configuration: VerificationRunnerConfiguration = .init()) {
    self.configuration = configuration
  }

  public func run(
    project: RegisteredProject,
    workingDirectory: RegisteredRoot,
    command selection: VerificationCommandSelection,
    required: Bool,
    authorization: VerificationExecutionAuthorization = .notApproved
  ) async throws -> VerificationRunResult {
    let resolved = try VerificationCommandResolver().resolve(
      selection,
      commands: project.verificationCommands
    )
    try validateMembership(workingDirectory, project: project)
    let start = ContinuousClock().now

    guard commandIsAbsolute(resolved.command) else {
      return result(
        for: resolved,
        required: required,
        status: .policyDenied,
        startedAt: start
      )
    }
    let decision = evaluatePolicy(resolved.command, project: project)
    guard decision.disposition != .deny, Self.isVerificationDecision(decision) else {
      return result(for: resolved, required: required, status: .policyDenied, startedAt: start)
    }
    guard authorization == .localUserApproved else {
      return result(
        for: resolved,
        required: required,
        status: .localApprovalRequired,
        startedAt: start
      )
    }

    let directory: OpenedVerificationDirectory
    do {
      try project.validateCurrentRoots()
      directory = try OpenedVerificationDirectory(root: workingDirectory)
      try directory.validatePathIdentity()
    } catch {
      return result(for: resolved, required: required, status: .rootUnavailable, startedAt: start)
    }

    do {
      let outcome = try await processRunner.run(
        BoundedVerificationProcessConfiguration(
          executableURL: URL(fileURLWithPath: resolved.command.executable),
          arguments: resolved.command.arguments,
          workingDirectory: directory,
          environment: Self.environment,
          timeout: configuration.timeout,
          terminationGracePeriod: configuration.terminationGracePeriod,
          maximumStandardOutputBytes: configuration.maximumStandardOutputBytes,
          maximumStandardErrorBytes: configuration.maximumStandardErrorBytes
        )
      )
      return result(for: resolved, required: required, outcome: outcome, startedAt: start)
    } catch {
      return result(for: resolved, required: required, status: .launchFailed, startedAt: start)
    }
  }

  public func run(
    taskID: String,
    generation: Int64,
    project: RegisteredProject,
    workingDirectory: RegisteredRoot,
    command selection: VerificationCommandSelection,
    required: Bool,
    authorization handle: VerificationAuthorizationHandle,
    authorizationStore: VerificationAuthorizationStore
  ) async throws -> VerificationRunResult {
    let resolved = try VerificationCommandResolver().resolve(
      selection,
      commands: project.verificationCommands
    )
    try validateMembership(workingDirectory, project: project)
    let start = ContinuousClock().now

    guard commandIsAbsolute(resolved.command) else {
      return result(for: resolved, required: required, status: .policyDenied, startedAt: start)
    }
    let decision = evaluatePolicy(resolved.command, project: project)
    guard decision.disposition != .deny, Self.isVerificationDecision(decision) else {
      return result(for: resolved, required: required, status: .policyDenied, startedAt: start)
    }

    let directory: OpenedVerificationDirectory
    do {
      try project.validateCurrentRoots()
      directory = try OpenedVerificationDirectory(root: workingDirectory)
      try directory.validatePathIdentity()
    } catch {
      return result(for: resolved, required: required, status: .rootUnavailable, startedAt: start)
    }

    try await authorizationStore.consume(
      handle,
      taskID: taskID,
      project: project,
      workingDirectory: workingDirectory,
      command: resolved,
      generation: generation
    )
    return await execute(
      resolved,
      required: required,
      workingDirectory: directory,
      startedAt: start
    )
  }

  private func execute(
    _ resolved: ResolvedVerificationCommand,
    required: Bool,
    workingDirectory: OpenedVerificationDirectory,
    startedAt start: ContinuousClock.Instant
  ) async -> VerificationRunResult {
    do {
      let outcome = try await processRunner.run(
        BoundedVerificationProcessConfiguration(
          executableURL: URL(fileURLWithPath: resolved.command.executable),
          arguments: resolved.command.arguments,
          workingDirectory: workingDirectory,
          environment: Self.environment,
          timeout: configuration.timeout,
          terminationGracePeriod: configuration.terminationGracePeriod,
          maximumStandardOutputBytes: configuration.maximumStandardOutputBytes,
          maximumStandardErrorBytes: configuration.maximumStandardErrorBytes
        )
      )
      return result(for: resolved, required: required, outcome: outcome, startedAt: start)
    } catch {
      return result(for: resolved, required: required, status: .launchFailed, startedAt: start)
    }
  }

  private func validateMembership(
    _ workingDirectory: RegisteredRoot,
    project: RegisteredProject
  ) throws {
    let roots = [project.primaryRoot] + project.worktreeRoots
    guard roots.contains(workingDirectory) else {
      throw VerificationRunnerError.workingDirectoryNotRegistered
    }
  }

  private func commandIsAbsolute(_ command: VerificationCommand) -> Bool {
    command.executable.hasPrefix("/")
      && URL(fileURLWithPath: command.executable).standardizedFileURL.path == command.executable
  }

  private func evaluatePolicy(
    _ command: VerificationCommand,
    project: RegisteredProject
  ) -> PolicyDecision {
    CommandPolicy().evaluate(
      argv: [command.executable] + command.arguments,
      networkRequested: false,
      context: CommandPolicyContext(
        accessPolicy: project.accessPolicy,
        verificationCommands: project.verificationCommands
      )
    )
  }

  private static func isVerificationDecision(_ decision: PolicyDecision) -> Bool {
    decision.reason == .configuredVerification
  }

  private func result(
    for command: ResolvedVerificationCommand,
    required: Bool,
    outcome: BoundedVerificationProcessOutcome,
    startedAt: ContinuousClock.Instant
  ) -> VerificationRunResult {
    let status: VerificationRunStatus
    let exitCode: Int32?
    switch outcome.termination {
    case .exited(let code):
      status = code == 0 ? .passed : .failed
      exitCode = code
    case .timedOut:
      status = .timedOut
      exitCode = nil
    case .cancelled:
      status = .cancelled
      exitCode = nil
    case .outputLimit:
      status = .outputLimitExceeded
      exitCode = nil
    }
    return result(
      for: command,
      required: required,
      status: status,
      exitCode: exitCode,
      standardOutput: .init(
        data: outcome.standardOutput,
        truncated: outcome.standardOutputTruncated
      ),
      standardError: .init(
        data: outcome.standardError,
        truncated: outcome.standardErrorTruncated
      ),
      startedAt: startedAt
    )
  }

  private func result(
    for command: ResolvedVerificationCommand,
    required: Bool,
    status: VerificationRunStatus,
    startedAt: ContinuousClock.Instant
  ) -> VerificationRunResult {
    result(
      for: command,
      required: required,
      status: status,
      exitCode: nil,
      standardOutput: .init(data: Data(), truncated: false),
      standardError: .init(data: Data(), truncated: false),
      startedAt: startedAt
    )
  }

  private func result(
    for command: ResolvedVerificationCommand,
    required: Bool,
    status: VerificationRunStatus,
    exitCode: Int32?,
    standardOutput: VerificationOutputSummary,
    standardError: VerificationOutputSummary,
    startedAt: ContinuousClock.Instant
  ) -> VerificationRunResult {
    VerificationRunResult(
      commandID: command.identifier,
      commandIndex: command.index,
      executableName: URL(fileURLWithPath: command.command.executable).lastPathComponent,
      required: required,
      status: status,
      exitCode: exitCode,
      durationMilliseconds: Self.milliseconds(since: startedAt),
      standardOutput: standardOutput,
      standardError: standardError
    )
  }

  private static func milliseconds(since start: ContinuousClock.Instant) -> UInt64 {
    let components = start.duration(to: ContinuousClock().now).components
    let seconds = max(components.seconds, 0)
    let attoseconds = max(components.attoseconds, 0)
    let secondsMilliseconds = UInt64(seconds) * 1_000
    return secondsMilliseconds + UInt64(attoseconds / 1_000_000_000_000_000)
  }
}
