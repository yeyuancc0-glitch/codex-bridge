import BridgeDomain
import BridgeSecurity
import Foundation

extension RestrictedProjectMutationService {
  public func write(_ request: ProjectWriteRequest) async throws -> ProjectMutationResult {
    let project = try await requireProject(request.projectID)
    let path = try securePath(request.relativePath)
    let data = try textContent(request.content)

    let resolver = ProjectPathResolver(root: project.primaryRoot)
    guard resolver.sensitivePolicy.allows(path) else { throw ProjectMutationError.forbiddenPath }

    let mode: SecureWriteMode = request.mode == .create ? .create : .replace
    let oldText: String?
    if mode == .replace {
      guard
        let raw = try mutationErrors({
          try writer.readContent(relativePath: path, through: resolver)
        })
      else {
        throw ProjectMutationError.pathMissing
      }
      guard let text = String(data: raw, encoding: .utf8) else {
        throw ProjectMutationError.binaryContent
      }
      oldText = text
    } else {
      oldText = nil
    }
    let result = try mutationErrors {
      try writer.write(
        relativePath: path,
        through: resolver,
        mode: mode,
        content: data,
        expectedSHA256: request.expectedSHA256,
        createParents: request.createParents
      )
    }
    let diff = oldText.map { BoundedDiffMaker.make(old: $0, new: request.content) } ?? .empty
    return ProjectMutationResult(
      relativePath: path.value,
      operation: request.mode.rawValue,
      oldSHA256: result.oldRevision?.sha256,
      newSHA256: result.newRevision.sha256,
      byteCount: result.newRevision.byteCount,
      boundedDiff: diff
    )
  }

  public func edit(_ request: ProjectEditRequest) async throws -> ProjectMutationResult {
    let project = try await requireProject(request.projectID)
    let path = try securePath(request.relativePath)
    let resolver = ProjectPathResolver(root: project.primaryRoot)
    guard resolver.sensitivePolicy.allows(path) else { throw ProjectMutationError.forbiddenPath }

    guard !request.oldText.isEmpty, !request.newText.isEmpty else {
      throw ProjectMutationError.invalidRequest
    }
    guard request.expectedReplacements >= 1 else { throw ProjectMutationError.invalidRequest }

    guard
      let raw = try mutationErrors({ try writer.readContent(relativePath: path, through: resolver) }
      )
    else {
      throw ProjectMutationError.pathMissing
    }
    guard let current = String(data: raw, encoding: .utf8) else {
      throw ProjectMutationError.binaryContent
    }
    let currentRevision = SecureFileRevision.digest(of: raw)
    guard currentRevision.sha256 == request.expectedSHA256 else {
      throw ProjectMutationError.revisionConflictWithContext(
        relativePath: path.value,
        currentSHA256: currentRevision.sha256,
        boundedDiff: BoundedDiffMaker.make(old: "", new: current)
      )
    }

    let occurrences = countOccurrences(of: request.oldText, in: current)
    guard occurrences == request.expectedReplacements else {
      throw ProjectMutationError.revisionConflictWithContext(
        relativePath: path.value,
        currentSHA256: currentRevision.sha256,
        boundedDiff: BoundedDiffMaker.make(old: "", new: current)
      )
    }
    let updated = current.replacingOccurrences(
      of: request.oldText,
      with: request.newText
    )
    let updatedData = try textContent(updated)
    let result = try mutationErrors {
      try writer.write(
        relativePath: path,
        through: resolver,
        mode: .replace,
        content: updatedData,
        expectedSHA256: request.expectedSHA256,
        createParents: false
      )
    }
    return ProjectMutationResult(
      relativePath: path.value,
      operation: "edit",
      oldSHA256: result.oldRevision?.sha256,
      newSHA256: result.newRevision.sha256,
      byteCount: result.newRevision.byteCount,
      boundedDiff: BoundedDiffMaker.make(old: current, new: updated)
    )
  }

  private func countOccurrences(of needle: String, in haystack: String) -> Int {
    var count = 0
    var searchRange = haystack.startIndex..<haystack.endIndex
    while let range = haystack.range(of: needle, options: .literal, range: searchRange) {
      count += 1
      searchRange = range.upperBound..<haystack.endIndex
    }
    return count
  }
}
