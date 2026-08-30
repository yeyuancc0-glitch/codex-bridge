import BridgeDomain
import BridgeSecurity
import Foundation

private struct StagedFile: Sendable {
  let path: SecureRelativePath
  let mode: SecureWriteMode
  let newContent: Data
  let oldRevision: SecureFileRevision?
  let oldContent: Data?
  let expectedSHA256: String?
}

extension RestrictedProjectMutationService {
  public func applyPatch(_ request: ProjectApplyPatchRequest) async throws
    -> [ProjectMutationResult]
  {
    let project = try await requireProject(request.projectID)
    guard !request.operations.isEmpty else { throw ProjectMutationError.invalidRequest }
    let resolver = ProjectPathResolver(root: project.primaryRoot)
    let staged = try stagePatch(request.operations, resolver: resolver)
    return try commitPatch(staged: staged, resolver: resolver)
  }

  private func stagePatch(
    _ operations: [ProjectPatchFileOperation],
    resolver: ProjectPathResolver
  ) throws -> [StagedFile] {
    var staged: [StagedFile] = []
    var paths = Set<String>()
    for operation in operations {
      let path = try securePath(operation.relativePath)
      guard paths.insert(path.value).inserted else {
        throw ProjectMutationError.invalidPatchSyntax
      }
      guard resolver.sensitivePolicy.allows(path) else {
        throw ProjectMutationError.forbiddenPath
      }
      staged.append(try stage(operation, at: path, resolver: resolver))
    }
    return staged
  }

  private func stage(
    _ operation: ProjectPatchFileOperation,
    at path: SecureRelativePath,
    resolver: ProjectPathResolver
  ) throws -> StagedFile {
    switch operation.action {
    case "add":
      return try stageAdd(operation, at: path, resolver: resolver)
    case "update":
      return try stageUpdate(operation, at: path, resolver: resolver)
    default:
      throw ProjectMutationError.invalidPatchSyntax
    }
  }

  private func stageAdd(
    _ operation: ProjectPatchFileOperation,
    at path: SecureRelativePath,
    resolver: ProjectPathResolver
  ) throws -> StagedFile {
    let additions = operation.hunks.flatMap(\.additions)
    let content = additions.joined(separator: "\n") + (additions.isEmpty ? "" : "\n")
    let data = try textContent(content)
    let existing = try mutationErrors {
      try writer.readContent(relativePath: path, through: resolver)
    }
    if existing != nil { throw ProjectMutationError.pathExists }
    return StagedFile(
      path: path,
      mode: .create,
      newContent: data,
      oldRevision: nil,
      oldContent: nil,
      expectedSHA256: nil
    )
  }

  private func stageUpdate(
    _ operation: ProjectPatchFileOperation,
    at path: SecureRelativePath,
    resolver: ProjectPathResolver
  ) throws -> StagedFile {
    guard
      let raw = try mutationErrors({
        try writer.readContent(relativePath: path, through: resolver)
      })
    else {
      throw ProjectMutationError.pathMissing
    }
    guard let current = String(data: raw, encoding: .utf8) else {
      throw ProjectMutationError.binaryContent
    }
    let oldRevision = SecureFileRevision.digest(of: raw)
    if let expectedSHA256 = operation.expectedSHA256,
      expectedSHA256 != oldRevision.sha256
    {
      throw ProjectMutationError.revisionConflictWithContext(
        relativePath: path.value,
        currentSHA256: oldRevision.sha256,
        boundedDiff: BoundedDiffMaker.make(old: "", new: current)
      )
    }
    let updated = try ProjectPatchApplier.apply(hunks: operation.hunks, to: current)
    let newData = try textContent(updated)
    return StagedFile(
      path: path,
      mode: .replace,
      newContent: newData,
      oldRevision: oldRevision,
      oldContent: raw,
      expectedSHA256: oldRevision.sha256
    )
  }

  private func commitPatch(
    staged: [StagedFile],
    resolver: ProjectPathResolver
  ) throws -> [ProjectMutationResult] {
    var committed: [ProjectMutationResult] = []
    var committedFiles: [StagedFile] = []
    do {
      for file in staged {
        committed.append(
          try commitStagedFile(file, resolver: resolver, committedFiles: &committedFiles)
        )
      }
      return committed
    } catch {
      guard !committedFiles.isEmpty else { throw error }
      let rolledBack = rollback(staged: committedFiles, resolver: resolver)
      let changedPaths = committedFiles.map { $0.path.value }
      throw ProjectMutationError.partialCommit(
        changedFiles: changedPaths,
        rollbackStatus: rolledBack == true ? "rolled_back" : "rollback_failed"
      )
    }
  }

  private func commitStagedFile(
    _ file: StagedFile,
    resolver: ProjectPathResolver,
    committedFiles: inout [StagedFile]
  ) throws -> ProjectMutationResult {
    let result: SecureWriteResult
    do {
      result = try writer.write(
        relativePath: file.path,
        through: resolver,
        mode: file.mode,
        content: file.newContent,
        expectedSHA256: file.expectedSHA256,
        createParents: true
      )
    } catch let error as PathSecurityError {
      if case .mutationAppliedDurabilityUncertain = error {
        committedFiles.append(file)
      }
      throw Self.mapSecurityError(error)
    }
    committedFiles.append(file)
    return ProjectMutationResult(
      relativePath: file.path.value,
      operation: file.mode == .create ? "create" : "update",
      oldSHA256: file.oldRevision?.sha256,
      newSHA256: result.newRevision.sha256,
      byteCount: result.newRevision.byteCount,
      boundedDiff: BoundedDiffMaker.make(
        old: file.oldContent.flatMap { String(data: $0, encoding: .utf8) } ?? "",
        new: String(data: file.newContent, encoding: .utf8) ?? ""
      )
    )
  }

  private func rollback(staged: [StagedFile], resolver: ProjectPathResolver) -> Bool {
    var succeeded = true
    for file in staged.reversed() {
      do {
        if let oldContent = file.oldContent {
          _ = try writer.write(
            relativePath: file.path,
            through: resolver,
            mode: .replace,
            content: oldContent,
            expectedSHA256: SecureFileRevision.digest(of: file.newContent).sha256,
            createParents: false
          )
        } else {
          let deletion = try directoryMutation.apply(
            action: .deleteFile(
              expectedSHA256: SecureFileRevision.digest(of: file.newContent).sha256
            ),
            relativePath: file.path,
            destinationRelativePath: nil,
            through: resolver
          )
          _ = deletion
        }
      } catch {
        succeeded = false
      }
    }
    return succeeded
  }
}
