import BridgeFiles
import BridgeMCP
import BridgeSecurity
import BridgeServiceCore
import Foundation

extension BridgeServiceApplication {
  public func serviceDirectWriteFile(
    _ request: MCPDirectWriteRequest,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectWriteReceipt {
    try Self.checkDeadline(deadline)
    let project = try await approvedDirectProject(
      projectID: request.projectID,
      kind: .fileWrite,
      summary: "Write \(request.relativePath)",
      payload: request,
      clientRequestID: request.clientRequestID
    )
    let operationID = "op-" + UUID().uuidString.lowercased()
    do {
      return try await withDirectLease(
        project: project,
        owner: .directFileOperation(operationID: operationID)
      ) {
        let result = try await self.mutations.write(
          ProjectWriteRequest(
            projectID: project.id,
            relativePath: request.relativePath,
            mode: request.mode == "create" ? .create : .replace,
            content: request.content,
            expectedSHA256: request.expectedSHA256,
            createParents: request.createParents
          )
        )
        return MCPDirectWriteReceipt(
          relativePath: result.relativePath,
          operation: result.operation,
          oldSHA256: result.oldSHA256,
          newSHA256: result.newSHA256,
          byteCount: result.byteCount,
          boundedDiff: Self.safeBoundedDiff(result.boundedDiff)
        )
      }
    } catch {
      throw Self.publicMutationError(error)
    }
  }

  public func serviceDirectEditFile(
    _ request: MCPDirectEditRequest,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectEditReceipt {
    try Self.checkDeadline(deadline)
    let project = try await approvedDirectProject(
      projectID: request.projectID,
      kind: .fileWrite,
      summary: "Edit \(request.relativePath)",
      payload: request,
      clientRequestID: request.clientRequestID
    )
    let operationID = "op-" + UUID().uuidString.lowercased()
    do {
      return try await withDirectLease(
        project: project,
        owner: .directFileOperation(operationID: operationID)
      ) {
        let result = try await self.mutations.edit(
          ProjectEditRequest(
            projectID: project.id,
            relativePath: request.relativePath,
            expectedSHA256: request.expectedSHA256,
            oldText: request.oldText,
            newText: request.newText,
            expectedReplacements: request.expectedReplacements
          )
        )
        return MCPDirectWriteReceipt(
          relativePath: result.relativePath,
          operation: result.operation,
          oldSHA256: result.oldSHA256,
          newSHA256: result.newSHA256,
          byteCount: result.byteCount,
          boundedDiff: Self.safeBoundedDiff(result.boundedDiff)
        )
      }
    } catch {
      throw Self.publicMutationError(error)
    }
  }

  public func serviceDirectApplyPatch(
    _ request: MCPDirectPatchRequest,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectPatchReceipt {
    try Self.checkDeadline(deadline)
    let project = try await approvedDirectProject(
      projectID: request.projectID,
      kind: .fileWrite,
      summary: "Apply patch",
      payload: request,
      clientRequestID: request.clientRequestID
    )
    let operationID = "op-" + UUID().uuidString.lowercased()
    do {
      return try await withDirectLease(
        project: project,
        owner: .directFileOperation(operationID: operationID)
      ) {
        let operations: [ProjectPatchFileOperation]
        do {
          operations = try ProjectPatchParser.parse(request.patch)
        } catch {
          throw BridgeMCPQueryError.invalidPatch
        }
        let results = try await self.mutations.applyPatch(
          ProjectApplyPatchRequest(
            projectID: project.id,
            operations: operations
          )
        )
        let receipts = results.map { result in
          MCPDirectWriteReceipt(
            relativePath: result.relativePath,
            operation: result.operation,
            oldSHA256: result.oldSHA256,
            newSHA256: result.newSHA256,
            byteCount: result.byteCount,
            boundedDiff: Self.safeBoundedDiff(result.boundedDiff)
          )
        }
        return MCPDirectPatchReceipt(operations: receipts)
      }
    } catch let error as ProjectMutationError {
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
      throw error
    }
  }

  private static func safeBoundedDiff(_ diff: BoundedDiff) -> MCPBoundedDiff {
    MCPBoundedDiff(
      removedLines: diff.removedLines.map {
        OutboundContentSecurity.redacted($0, maximumUTF8Bytes: 64 * 1_024)
      },
      addedLines: diff.addedLines.map {
        OutboundContentSecurity.redacted($0, maximumUTF8Bytes: 64 * 1_024)
      },
      truncated: diff.truncated,
      byteCount: diff.byteCount
    )
  }

  public func serviceDirectManagePath(
    _ request: MCPDirectManagePathRequest,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectManagePathReceipt {
    try Self.checkDeadline(deadline)
    let project = try await approvedDirectProject(
      projectID: request.projectID,
      kind: .pathAction,
      summary: "\(request.action) \(request.relativePath)",
      payload: request,
      clientRequestID: request.clientRequestID
    )
    let operationID = "op-" + UUID().uuidString.lowercased()
    do {
      return try await withDirectLease(
        project: project,
        owner: .directFileOperation(operationID: operationID)
      ) {
        let action = ProjectPathAction(rawValue: request.action) ?? .deleteFile
        let result = try await self.mutations.managePath(
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
      }
    } catch {
      throw Self.publicMutationError(error)
    }
  }

  func withDirectLease<Result>(
    project: ServiceProjectRecord,
    owner: ServiceWorkspaceOwner,
    operation: () async throws -> Result
  ) async throws -> Result {
    let lease = try await acquireDirectLease(project: project, owner: owner)
    do {
      let result = try await operation()
      await lease.release()
      return result
    } catch {
      await lease.release()
      throw error
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
