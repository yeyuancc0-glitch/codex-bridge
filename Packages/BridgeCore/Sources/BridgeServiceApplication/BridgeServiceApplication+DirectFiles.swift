import BridgeFiles
import BridgeMCP
import BridgeServiceCore
import Foundation

extension BridgeServiceApplication {
  public func serviceDirectWriteFile(
    _ request: MCPDirectWriteRequest,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectWriteReceipt {
    try Self.checkDeadline(deadline)
    let project = try await readableProject(request.projectID)
    if project.accessPolicy.write == .requiresLocalApproval {
      try await requireDirectApproval(
        project: project,
        kind: .fileWrite,
        summary: "Write \(request.relativePath)",
        payload: request,
        clientRequestID: request.clientRequestID
      )
    }
    let operationID = "op-" + UUID().uuidString.lowercased()
    let lease = try await acquireDirectLease(
      project: project, owner: .directFileOperation(operationID: operationID))
    do {
      let result = try await mutations.write(
        ProjectWriteRequest(
          projectID: project.id,
          relativePath: request.relativePath,
          mode: request.mode == "create" ? .create : .replace,
          content: request.content,
          expectedSHA256: request.expectedSHA256,
          createParents: request.createParents
        )
      )
      await lease.release()
      return MCPDirectWriteReceipt(
        relativePath: result.relativePath,
        operation: result.operation,
        oldSHA256: result.oldSHA256,
        newSHA256: result.newSHA256,
        byteCount: result.byteCount,
        boundedDiff: MCPBoundedDiff(
          removedLines: result.boundedDiff.removedLines,
          addedLines: result.boundedDiff.addedLines,
          truncated: result.boundedDiff.truncated,
          byteCount: result.boundedDiff.byteCount
        )
      )
    } catch {
      await lease.release()
      throw Self.publicMutationError(error)
    }
  }

  public func serviceDirectEditFile(
    _ request: MCPDirectEditRequest,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectEditReceipt {
    try Self.checkDeadline(deadline)
    let project = try await readableProject(request.projectID)
    if project.accessPolicy.write == .requiresLocalApproval {
      try await requireDirectApproval(
        project: project,
        kind: .fileWrite,
        summary: "Edit \(request.relativePath)",
        payload: request,
        clientRequestID: request.clientRequestID
      )
    }
    let operationID = "op-" + UUID().uuidString.lowercased()
    let lease = try await acquireDirectLease(
      project: project, owner: .directFileOperation(operationID: operationID))
    do {
      let result = try await mutations.edit(
        ProjectEditRequest(
          projectID: project.id,
          relativePath: request.relativePath,
          expectedSHA256: request.expectedSHA256,
          oldText: request.oldText,
          newText: request.newText,
          expectedReplacements: request.expectedReplacements
        )
      )
      await lease.release()
      return MCPDirectWriteReceipt(
        relativePath: result.relativePath,
        operation: result.operation,
        oldSHA256: result.oldSHA256,
        newSHA256: result.newSHA256,
        byteCount: result.byteCount,
        boundedDiff: MCPBoundedDiff(
          removedLines: result.boundedDiff.removedLines,
          addedLines: result.boundedDiff.addedLines,
          truncated: result.boundedDiff.truncated,
          byteCount: result.boundedDiff.byteCount
        )
      )
    } catch {
      await lease.release()
      throw Self.publicMutationError(error)
    }
  }

  public func serviceDirectApplyPatch(
    _ request: MCPDirectPatchRequest,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectPatchReceipt {
    try Self.checkDeadline(deadline)
    let project = try await readableProject(request.projectID)
    if project.accessPolicy.write == .requiresLocalApproval {
      try await requireDirectApproval(
        project: project,
        kind: .fileWrite,
        summary: "Apply patch",
        payload: request,
        clientRequestID: request.clientRequestID
      )
    }
    let operationID = "op-" + UUID().uuidString.lowercased()
    let lease = try await acquireDirectLease(
      project: project, owner: .directFileOperation(operationID: operationID))
    do {
      let operations: [ProjectPatchFileOperation]
      do {
        operations = try ProjectPatchParser.parse(request.patch)
      } catch {
        throw BridgeMCPQueryError.invalidPatch
      }
      let results = try await mutations.applyPatch(
        ProjectApplyPatchRequest(
          projectID: project.id,
          operations: operations
        )
      )
      await lease.release()
      let receipts = results.map { result in
        MCPDirectWriteReceipt(
          relativePath: result.relativePath,
          operation: result.operation,
          oldSHA256: result.oldSHA256,
          newSHA256: result.newSHA256,
          byteCount: result.byteCount,
          boundedDiff: MCPBoundedDiff(
            removedLines: result.boundedDiff.removedLines,
            addedLines: result.boundedDiff.addedLines,
            truncated: result.boundedDiff.truncated,
            byteCount: result.boundedDiff.byteCount
          )
        )
      }
      return MCPDirectPatchReceipt(operations: receipts)
    } catch let error as ProjectMutationError {
      await lease.release()
      if case .partialCommit(let changedFiles, let rollbackStatus) = error {
        return MCPDirectPatchReceipt(
          operations: [],
          partialCommit: MCPPartialCommit(
            changedFiles: changedFiles,
            rollbackStatus: rollbackStatus
          )
        )
      }
      throw Self.publicMutationError(error)
    } catch {
      await lease.release()
      throw error
    }
  }

  public func serviceDirectManagePath(
    _ request: MCPDirectManagePathRequest,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectManagePathReceipt {
    try Self.checkDeadline(deadline)
    let project = try await readableProject(request.projectID)
    let destructive = ["delete_file", "move_file", "delete_empty_directory"].contains(
      request.action)
    if project.accessPolicy.write == .requiresLocalApproval || destructive {
      try await requireDirectApproval(
        project: project,
        kind: .pathAction,
        summary: "\(request.action) \(request.relativePath)",
        payload: request,
        clientRequestID: request.clientRequestID
      )
    }
    let operationID = "op-" + UUID().uuidString.lowercased()
    let lease = try await acquireDirectLease(
      project: project, owner: .directFileOperation(operationID: operationID))
    do {
      let action = ProjectPathAction(rawValue: request.action) ?? .deleteFile
      let result = try await mutations.managePath(
        ProjectManagePathRequest(
          projectID: project.id,
          action: action,
          relativePath: request.relativePath,
          expectedSHA256: request.expectedSHA256,
          destinationRelativePath: request.destinationRelativePath,
          sourceExpectedSHA256: request.sourceExpectedSHA256,
          destinationExpectedAbsent: request.destinationExpectedAbsent
        )
      )
      await lease.release()
      return MCPDirectManagePathReceipt(
        relativePath: result.relativePath,
        sourceRelativePath: result.relativePath,
        destinationRelativePath: result.destinationRelativePath,
        operation: result.operation,
        sha256: result.oldSHA256,
        oldSHA256: result.oldSHA256,
        newSHA256: result.newSHA256,
        byteCount: result.byteCount
      )
    } catch {
      await lease.release()
      throw Self.publicMutationError(error)
    }
  }

  func acquireDirectLease(
    project: ServiceProjectRecord,
    owner: ServiceWorkspaceOwner
  ) async throws -> DirectWorkspaceLease {
    do {
      return try await workspaceGate.acquireDirectLease(
        projectID: project.id,
        owner: owner,
        activeCodexWriteTask: { try await self.tasks.activeWriteTask(projectID: project.id) }
      )
    } catch {
      throw Self.publicWorkspaceBusyError(error)
    }
  }
}
