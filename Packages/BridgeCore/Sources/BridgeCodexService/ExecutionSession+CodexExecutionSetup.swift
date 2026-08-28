import BridgeCodexRPC
import BridgeDomain
import BridgeProjects
import BridgeServiceCore
import Foundation

extension ExecutionSession {
  func validateProjectPolicy(_ request: ExecutionRequest) throws {
    let policy = request.project.accessPolicy
    switch request.task.permissionMode {
    case .readOnly:
      guard policy.read != .denied else {
        throw ExecutionServiceError.projectPermissionDenied(request.project.id)
      }
    case .workspaceWrite:
      guard policy.read != .denied, policy.write != .denied else {
        throw ExecutionServiceError.projectPermissionDenied(request.project.id)
      }
    }
    if request.task.networkAllowed, policy.network == .denied {
      throw ExecutionServiceError.projectPermissionDenied(request.project.id)
    }
  }

  func validateModel(
    model: String,
    effort: String,
    fastMode: Bool
  ) async throws -> String? {
    var cursor: String?
    for _ in 0..<8 {
      let page: ModelListResponse
      do {
        page = try await client.listModels(
          ModelListParams(cursor: cursor, limit: 100, includeHidden: false)
        )
      } catch {
        throw ExecutionServiceError.processUnavailable
      }
      if let available = page.data.first(where: { $0.id == model }) {
        guard
          available.supportedReasoningEfforts.contains(where: {
            $0.reasoningEffort == effort
          })
        else {
          throw ExecutionServiceError.effortUnavailable(effort)
        }
        guard !fastMode || available.supportsFastMode else {
          throw ExecutionServiceError.serviceTierUnavailable("fast")
        }
        return fastMode ? available.fastServiceTierID : nil
      }
      guard let next = page.nextCursor, !next.isEmpty, next != cursor else { break }
      cursor = next
    }
    throw ExecutionServiceError.modelUnavailable(model)
  }

  func prepareThread(
    _ request: ExecutionRequest,
    posture: ExecutionPosture
  ) async throws -> String {
    let projectID = try await codexProjectID(for: request.project)
    if let threadID = request.task.requestedThreadID {
      return try await resumeThread(
        threadID,
        request: request,
        posture: posture,
        projectID: projectID
      )
    }
    let response: ThreadStartResponse
    do {
      response = try await client.startThread(
        ThreadStartParams(
          cwd: projectRoot,
          sandbox: posture.threadSandbox,
          approvalPolicy: posture.approvalPolicy,
          approvalsReviewer: posture.approvalsReviewer,
          serviceTier: posture.serviceTier,
          ephemeral: false,
          model: request.task.executionModel,
          projectId: projectID
        )
      )
    } catch {
      throw ExecutionServiceError.processUnavailable
    }
    try validateThreadResponse(
      response,
      expectedThreadID: nil,
      expectedProjectID: projectID,
      posture: posture
    )
    return response.thread.id
  }

  func resumeThread(
    _ threadID: String,
    request: ExecutionRequest,
    posture: ExecutionPosture,
    projectID: String?
  ) async throws -> String {
    guard Self.isSafeWireIdentifier(threadID) else {
      throw ExecutionServiceError.invalidRequest("threadID")
    }
    let read: ThreadReadResponse
    do {
      read = try await client.readThread(ThreadReadParams(threadId: threadID))
    } catch {
      throw ExecutionServiceError.threadUnavailable(threadID)
    }
    guard read.thread.id == threadID, read.thread.cwd == projectRoot else {
      throw ExecutionServiceError.threadMismatch(threadID)
    }
    if let projectID, read.thread.projectId != projectID {
      do {
        let updated = try await client.updateThreadMetadata(
          ThreadMetadataUpdateParams(threadId: threadID, projectId: projectID)
        )
        guard updated.thread.id == threadID,
          updated.thread.cwd == projectRoot,
          updated.thread.projectId == projectID
        else {
          throw ExecutionServiceError.threadMismatch(threadID)
        }
      } catch let error as ExecutionServiceError {
        throw error
      } catch {
        throw ExecutionServiceError.threadUnavailable(threadID)
      }
    }
    let response: ThreadResumeResponse
    do {
      response = try await client.resumeThread(
        ThreadResumeParams(
          threadId: threadID,
          cwd: projectRoot,
          sandbox: posture.threadSandbox,
          approvalPolicy: posture.approvalPolicy,
          approvalsReviewer: posture.approvalsReviewer,
          serviceTier: posture.serviceTier,
          model: request.task.executionModel
        )
      )
    } catch {
      throw ExecutionServiceError.threadUnavailable(threadID)
    }
    try validateThreadResponse(
      response,
      expectedThreadID: threadID,
      expectedProjectID: projectID,
      posture: posture
    )
    return response.thread.id
  }

  func validateThreadResponse(
    _ response: ThreadStartResponse,
    expectedThreadID: String?,
    expectedProjectID: String?,
    posture: ExecutionPosture
  ) throws {
    guard Self.isSafeWireIdentifier(response.thread.id),
      expectedThreadID == nil || response.thread.id == expectedThreadID,
      expectedProjectID == nil || response.thread.projectId == expectedProjectID,
      response.thread.cwd == projectRoot,
      response.cwd == projectRoot,
      response.thread.ephemeral == false,
      response.model == posture.model,
      response.approvalPolicy == posture.approvalPolicy,
      response.approvalsReviewer == posture.approvalsReviewer,
      response.sandbox.type == posture.sandboxPolicy.type
    else {
      throw ExecutionServiceError.threadMismatch(response.thread.id)
    }
  }

  func activeBinding(expectedTurnID: String?) throws -> ExecutionBinding {
    guard !terminal else { throw ExecutionServiceError.sessionEnded(taskID) }
    guard let binding, startedTurnIDs.contains(binding.turnID) else {
      throw ExecutionServiceError.sessionUnavailable(taskID)
    }
    if let expectedTurnID, expectedTurnID != binding.turnID {
      throw ExecutionServiceError.bindingMismatch
    }
    return binding
  }

  struct ExecutionPosture: Equatable, Sendable {
    let model: String
    let threadSandbox: ThreadSandboxMode
    let sandboxPolicy: CodexSandboxPolicy
    let approvalPolicy: CodexApprovalPolicy
    let approvalsReviewer: String
    let serviceTier: String?
  }

  static func posture(
    for request: ExecutionRequest,
    root: String,
    fastServiceTierID: String?
  ) -> ExecutionPosture {
    let task = request.task
    let projectPolicy = request.project.accessPolicy
    let fullAccess =
      task.accessMode == .fullAccess
      && task.permissionMode == .workspaceWrite
      && task.networkAllowed
      && projectPolicy.write != .denied
      && projectPolicy.network != .denied
    let sandboxPolicy: CodexSandboxPolicy
    let approvalPolicy: CodexApprovalPolicy
    if fullAccess {
      sandboxPolicy = .dangerFullAccess
      approvalPolicy = .never
    } else {
      switch task.permissionMode {
      case .readOnly:
        sandboxPolicy = .readOnly(networkAccess: task.networkAllowed)
      case .workspaceWrite:
        sandboxPolicy = .workspaceWrite(
          writableRoots: [root],
          networkAccess: task.networkAllowed,
          excludeSlashTmp: false,
          excludeTmpdirEnvVar: false
        )
      }
      approvalPolicy = .onRequest
    }
    return ExecutionPosture(
      model: task.executionModel,
      threadSandbox: fullAccess
        ? .dangerFullAccess : (task.permissionMode == .readOnly ? .readOnly : .workspaceWrite),
      sandboxPolicy: sandboxPolicy,
      approvalPolicy: approvalPolicy,
      approvalsReviewer: task.accessMode == .autoReview ? "auto_review" : "user",
      serviceTier: fastServiceTierID
    )
  }

  static func isSafeWireIdentifier(_ value: String) -> Bool {
    do {
      try ExecutionValidation.identifier(value, field: "wire.identifier", maximumBytes: 1_024)
      return true
    } catch {
      return false
    }
  }
}
