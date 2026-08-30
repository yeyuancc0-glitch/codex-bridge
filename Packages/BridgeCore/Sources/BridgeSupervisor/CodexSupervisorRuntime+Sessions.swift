import BridgeCodexRPC
import BridgeSecurity
import Foundation

extension CodexSupervisorRuntime {
  func session(
    taskID: String,
    root: RegisteredRoot,
    model: String,
    effort: String
  ) async throws -> CodexSupervisorSession {
    if let session = sessions[taskID] {
      guard await session.matches(root: root, model: model, effort: effort) else {
        throw CodexSupervisorRuntimeError.threadMismatch
      }
      return session
    }
    guard !creating.contains(taskID) else {
      throw CodexSupervisorRuntimeError.reviewAlreadyActive
    }
    guard sessions.count + creating.count < configuration.maximumConcurrentTasks else {
      throw CodexSupervisorRuntimeError.taskLimitReached
    }
    creating.insert(taskID)
    let sessionConfiguration: CodexSupervisorRuntimeConfiguration
    var sessionHome: URL?
    if configuration.permitsUnconfinedProjectReadForProtocolTesting {
      sessionConfiguration = configuration
      sessionHome = nil
    } else {
      guard let home = configuration.evidenceOnlyHomeURL else {
        throw CodexSupervisorRuntimeError.evidenceIsolationUnavailable
      }
      do {
        let preparedHome = try EvidenceOnlyProcessBoundary.prepareSessionHome(in: home)
        sessionHome = preparedHome
        if let authenticationProvisioner = configuration.authenticationProvisioner {
          do {
            _ = try await authenticationProvisioner.ensureAuthenticated(
              homeURL: preparedHome,
              deniedReadRoots: [URL(fileURLWithPath: root.canonicalPath, isDirectory: true)]
            )
          } catch {
            throw CodexSupervisorRuntimeError.authenticationRequired
          }
        }
        sessionConfiguration = try configuration.withEvidenceOnlyProcessBoundary(
          home: preparedHome,
          deniedRoot: root
        )
      } catch let error as CodexSupervisorRuntimeError {
        creating.remove(taskID)
        if let sessionHome {
          EvidenceOnlyProcessBoundary.removeSessionHome(sessionHome, from: home)
        }
        throw error
      } catch {
        creating.remove(taskID)
        if let sessionHome {
          EvidenceOnlyProcessBoundary.removeSessionHome(sessionHome, from: home)
        }
        throw CodexSupervisorRuntimeError.evidenceIsolationUnavailable
      }
    }
    let session = CodexSupervisorSession(
      taskID: taskID,
      root: root,
      model: model,
      effort: effort,
      configuration: sessionConfiguration,
      sessionHome: sessionHome,
      sessionHomeRoot: configuration.evidenceOnlyHomeURL
    )
    do {
      try await session.start()
      creating.remove(taskID)
      sessions[taskID] = session
      return session
    } catch {
      creating.remove(taskID)
      await session.shutdown()
      throw error
    }
  }

  func removeAndStop(taskID: String, session: CodexSupervisorSession) async {
    if sessions[taskID] === session { sessions[taskID] = nil }
    await session.shutdown()
  }

  static func validate(
    checkpoint: SupervisorCheckpoint,
    root: RegisteredRoot,
    model: String,
    effort: String
  ) throws {
    guard !checkpoint.taskID.isEmpty, checkpoint.taskID.utf8.count <= 256 else {
      throw CodexSupervisorRuntimeError.invalidTaskIdentifier
    }
    guard validIdentifier(model, maximumBytes: 256) else {
      throw CodexSupervisorRuntimeError.invalidModel
    }
    guard validIdentifier(effort, maximumBytes: 64) else {
      throw CodexSupervisorRuntimeError.invalidEffort
    }
    do {
      try SupervisorCheckpointEgressPolicy.validate(checkpoint, projectRoot: root.canonicalPath)
    } catch {
      throw CodexSupervisorRuntimeError.unsafeCheckpoint
    }
  }

  private static func validIdentifier(_ value: String, maximumBytes: Int) -> Bool {
    !value.isEmpty && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
      && value.utf8.count <= maximumBytes && !value.contains("\0")
  }

  static func requiresSessionTermination(_ error: CodexSupervisorRuntimeError) -> Bool {
    switch error {
    case .approvalRequested, .processFailed, .reviewTimedOut, .threadMismatch, .turnMismatch:
      true
    case .invalidTaskIdentifier, .invalidModel, .invalidEffort, .rootChanged, .taskLimitReached,
      .reviewAlreadyActive, .modelUnavailable, .effortUnavailable, .responseMissing,
      .responseTooLarge, .unsafeCheckpoint, .evidenceIsolationUnavailable:
      false
    case .authenticationRequired:
      false
    }
  }
}
