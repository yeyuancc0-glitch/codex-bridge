import BridgeCodexRPC
import BridgeSecurity
import Foundation

public struct CodexSupervisorRuntimeConfiguration: Sendable {
  public let appServer: AppServerConfiguration
  public let clientInfo: CodexClientInfo
  public let requestTimeoutNanoseconds: UInt64
  public let reviewTimeoutNanoseconds: UInt64
  public let eventBufferLimit: Int
  public let maximumConcurrentTasks: Int
  /// A private HOME/CODEX_HOME prepared by the desktop host for evidence-only
  /// Supervisor sessions. The project root is denied per session.
  public let evidenceOnlyHomeURL: URL?
  public let authenticationProvisioner: CodexSupervisorAuthenticationProvisioner?
  package let permitsUnconfinedProjectReadForProtocolTesting: Bool

  public init(
    appServer: AppServerConfiguration = .codex(),
    clientInfo: CodexClientInfo,
    requestTimeoutNanoseconds: UInt64 = 180_000_000_000,
    reviewTimeoutNanoseconds: UInt64 = 180_000_000_000,
    eventBufferLimit: Int = 128,
    maximumConcurrentTasks: Int = 2,
    evidenceOnlyHomeURL: URL? = nil,
    authenticationProvisioner: CodexSupervisorAuthenticationProvisioner? = nil
  ) {
    self.appServer = appServer
    self.clientInfo = clientInfo
    self.requestTimeoutNanoseconds = max(1, requestTimeoutNanoseconds)
    self.reviewTimeoutNanoseconds = max(1, reviewTimeoutNanoseconds)
    self.eventBufferLimit = max(1, eventBufferLimit)
    self.maximumConcurrentTasks = max(1, maximumConcurrentTasks)
    self.evidenceOnlyHomeURL = evidenceOnlyHomeURL
    self.authenticationProvisioner = authenticationProvisioner
    permitsUnconfinedProjectReadForProtocolTesting = false
  }

  package static func unconfinedProtocolTest(
    appServer: AppServerConfiguration,
    clientInfo: CodexClientInfo,
    requestTimeoutNanoseconds: UInt64 = 180_000_000_000,
    reviewTimeoutNanoseconds: UInt64 = 180_000_000_000,
    eventBufferLimit: Int = 128,
    maximumConcurrentTasks: Int = 2,
    evidenceOnlyHomeURL: URL? = nil
  ) -> Self {
    Self(
      appServer: appServer,
      clientInfo: clientInfo,
      requestTimeoutNanoseconds: requestTimeoutNanoseconds,
      reviewTimeoutNanoseconds: reviewTimeoutNanoseconds,
      eventBufferLimit: eventBufferLimit,
      maximumConcurrentTasks: maximumConcurrentTasks,
      evidenceOnlyHomeURL: evidenceOnlyHomeURL,
      authenticationProvisioner: nil,
      permitsUnconfinedProjectReadForProtocolTesting: true
    )
  }

  private init(
    appServer: AppServerConfiguration,
    clientInfo: CodexClientInfo,
    requestTimeoutNanoseconds: UInt64,
    reviewTimeoutNanoseconds: UInt64,
    eventBufferLimit: Int,
    maximumConcurrentTasks: Int,
    evidenceOnlyHomeURL: URL?,
    authenticationProvisioner: CodexSupervisorAuthenticationProvisioner?,
    permitsUnconfinedProjectReadForProtocolTesting: Bool
  ) {
    self.appServer = appServer
    self.clientInfo = clientInfo
    self.requestTimeoutNanoseconds = max(1, requestTimeoutNanoseconds)
    self.reviewTimeoutNanoseconds = max(1, reviewTimeoutNanoseconds)
    self.eventBufferLimit = max(1, eventBufferLimit)
    self.maximumConcurrentTasks = max(1, maximumConcurrentTasks)
    self.evidenceOnlyHomeURL = evidenceOnlyHomeURL
    self.authenticationProvisioner = authenticationProvisioner
    self.permitsUnconfinedProjectReadForProtocolTesting =
      permitsUnconfinedProjectReadForProtocolTesting
  }

  func withEvidenceOnlyProcessBoundary(
    home: URL,
    deniedRoot: RegisteredRoot
  ) throws -> Self {
    let wrappedAppServer = try EvidenceOnlyProcessBoundary.configuration(
      wrapping: appServer,
      isolatedHomeURL: home,
      deniedReadRoots: [URL(fileURLWithPath: deniedRoot.canonicalPath, isDirectory: true)]
    )
    return Self(
      appServer: wrappedAppServer,
      clientInfo: clientInfo,
      requestTimeoutNanoseconds: requestTimeoutNanoseconds,
      reviewTimeoutNanoseconds: reviewTimeoutNanoseconds,
      eventBufferLimit: eventBufferLimit,
      maximumConcurrentTasks: maximumConcurrentTasks,
      evidenceOnlyHomeURL: evidenceOnlyHomeURL,
      authenticationProvisioner: authenticationProvisioner,
      permitsUnconfinedProjectReadForProtocolTesting: permitsUnconfinedProjectReadForProtocolTesting
    )
  }
}

public enum CodexSupervisorRuntimeError: Error, Equatable, Sendable {
  case invalidTaskIdentifier
  case invalidModel
  case invalidEffort
  case rootChanged
  case taskLimitReached
  case reviewAlreadyActive
  case modelUnavailable
  case effortUnavailable
  case threadMismatch
  case turnMismatch
  case approvalRequested
  case responseMissing
  case responseTooLarge
  case reviewTimedOut
  case unsafeCheckpoint
  case evidenceIsolationUnavailable
  case authenticationRequired
  case processFailed
}

public actor CodexSupervisorRuntime {
  let configuration: CodexSupervisorRuntimeConfiguration
  var sessions: [String: CodexSupervisorSession] = [:]
  var creating: Set<String> = []

  public init(configuration: CodexSupervisorRuntimeConfiguration) {
    self.configuration = configuration
  }

  /// Reviews with the exact model and effort selected from the current catalog.
  /// This low-level runtime never chooses a product default.
  public func review(
    _ checkpoint: SupervisorCheckpoint,
    root: RegisteredRoot,
    model: String,
    effort: String
  ) async throws -> SupervisorDecision {
    guard
      configuration.permitsUnconfinedProjectReadForProtocolTesting
        || configuration.evidenceOnlyHomeURL != nil
    else {
      throw CodexSupervisorRuntimeError.evidenceIsolationUnavailable
    }
    try Self.validate(checkpoint: checkpoint, root: root, model: model, effort: effort)
    let liveRoot: RegisteredRoot
    do {
      liveRoot = try RegisteredRoot(
        capturing: URL(fileURLWithPath: root.canonicalPath, isDirectory: true)
      )
    } catch {
      throw CodexSupervisorRuntimeError.rootChanged
    }
    guard liveRoot == root else { throw CodexSupervisorRuntimeError.rootChanged }

    let session = try await session(
      taskID: checkpoint.taskID,
      root: root,
      model: model,
      effort: effort
    )
    do {
      return try await session.review(
        checkpoint,
        timeoutNanoseconds: configuration.reviewTimeoutNanoseconds
      )
    } catch let error as SupervisorDecisionValidationError {
      throw error
    } catch let error as CodexSupervisorRuntimeError {
      if Self.requiresSessionTermination(error) {
        await removeAndStop(taskID: checkpoint.taskID, session: session)
      }
      throw error
    } catch is CancellationError {
      await removeAndStop(taskID: checkpoint.taskID, session: session)
      throw CancellationError()
    } catch {
      await removeAndStop(taskID: checkpoint.taskID, session: session)
      throw CodexSupervisorRuntimeError.processFailed
    }
  }

  /// Preserves source compatibility for callers compiled against the original
  /// convenience signature while refusing to invent a model outside the live catalog.
  @available(*, deprecated, message: "Pass the current Codex catalog model and effort explicitly.")
  public func review(
    _ checkpoint: SupervisorCheckpoint,
    root: RegisteredRoot
  ) async throws -> SupervisorDecision {
    _ = checkpoint
    _ = root
    throw CodexSupervisorRuntimeError.modelUnavailable
  }

  public func shutdown(taskID: String) async {
    guard let session = sessions.removeValue(forKey: taskID) else { return }
    await session.shutdown()
  }

  public func shutdown() async {
    let active = Array(sessions.values)
    sessions.removeAll(keepingCapacity: false)
    creating.removeAll(keepingCapacity: false)
    for session in active {
      await session.shutdown()
    }
  }

}
