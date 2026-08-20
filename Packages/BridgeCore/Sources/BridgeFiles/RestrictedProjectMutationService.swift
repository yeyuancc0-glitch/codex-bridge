import BridgeDomain
import BridgeProjects
import BridgeSecurity
import Foundation

public struct RestrictedProjectMutationService: Sendable {
  private let repository: any ProjectRepository
  private let writer = SecureProjectFileWriter()
  private let directoryMutation = SecureProjectDirectoryMutation()
  private let gitInspector = ProjectGitInspector()

  public init(repository: any ProjectRepository) {
    self.repository = repository
  }

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

  public func applyPatch(_ request: ProjectApplyPatchRequest) async throws
    -> [ProjectMutationResult]
  {
    let project = try await requireProject(request.projectID)
    guard !request.operations.isEmpty else { throw ProjectMutationError.invalidRequest }
    let resolver = ProjectPathResolver(root: project.primaryRoot)

    var staged: [StagedFile] = []
    var paths = Set<String>()
    for operation in request.operations {
      let path = try securePath(operation.relativePath)
      guard paths.insert(path.value).inserted else {
        throw ProjectMutationError.invalidPatch
      }
      guard resolver.sensitivePolicy.allows(path) else {
        throw ProjectMutationError.forbiddenPath
      }
      switch operation.action {
      case "add":
        let additions = operation.hunks.flatMap(\.additions)
        let content = additions.joined(separator: "\n") + (additions.isEmpty ? "" : "\n")
        let data = try textContent(content)
        let existing = try mutationErrors({
          try writer.readContent(relativePath: path, through: resolver)
        })
        if existing != nil { throw ProjectMutationError.pathExists }
        staged.append(
          StagedFile(
            path: path,
            mode: .create,
            newContent: data,
            oldRevision: nil,
            oldContent: nil,
            expectedSHA256: nil
          )
        )
      case "update":
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
        var updated = current
        for hunk in operation.hunks {
          updated = try apply(hunk: hunk, to: updated)
        }
        let newData = try textContent(updated)
        staged.append(
          StagedFile(
            path: path,
            mode: .replace,
            newContent: newData,
            oldRevision: oldRevision,
            oldContent: raw,
            expectedSHA256: oldRevision.sha256
          )
        )
      default:
        throw ProjectMutationError.invalidPatch
      }
    }

    var committed: [ProjectMutationResult] = []
    var committedFiles: [StagedFile] = []
    do {
      for file in staged {
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
        } catch let PathSecurityError.mutationAppliedDurabilityUncertain(code) {
          committedFiles.append(file)
          throw PathSecurityError.mutationAppliedDurabilityUncertain(code)
        }
        committedFiles.append(file)
        committed.append(
          ProjectMutationResult(
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
        )
      }
      return committed
    } catch {
      let rolledBack = rollback(staged: committedFiles, resolver: resolver)
      let changedPaths = committedFiles.map { $0.path.value }
      throw ProjectMutationError.partialCommit(
        changedFiles: changedPaths,
        rollbackStatus: rolledBack == true ? "rolled_back" : "rollback_failed"
      )
    }
  }

  public func managePath(_ request: ProjectManagePathRequest) async throws
    -> ProjectMutationResult
  {
    let project = try await requireProject(request.projectID)
    let path = try securePath(request.relativePath)
    var destination: SecureRelativePath?
    if let destinationPath = request.destinationRelativePath {
      destination = try securePath(destinationPath)
    }
    let resolver = ProjectPathResolver(root: project.primaryRoot)

    let action: SecureDirectoryAction
    switch request.action {
    case .deleteFile:
      action = .deleteFile(expectedSHA256: request.expectedSHA256)
    case .moveFile:
      action = .moveFile(
        sourceExpectedSHA256: request.sourceExpectedSHA256,
        destinationExpectedAbsent: request.destinationExpectedAbsent
      )
    case .createDirectory:
      action = .createDirectory
    case .deleteEmptyDirectory:
      action = .deleteEmptyDirectory
    }
    let result = try mutationErrors {
      try directoryMutation.apply(
        action: action,
        relativePath: path,
        destinationRelativePath: destination,
        through: resolver
      )
    }
    return ProjectMutationResult(
      relativePath: path.value,
      destinationRelativePath: destination?.value,
      operation: request.action.rawValue,
      oldSHA256: result.revision?.sha256,
      newSHA256: nil,
      byteCount: result.revision?.byteCount ?? 0
    )
  }

  public func changes(projectID: ProjectID) async throws -> ProjectChangesResult {
    let project = try await requireProject(projectID)
    return try await gitInspector.changes(root: project.primaryRoot)
  }

  private func mutationErrors<T>(_ body: () throws -> T) throws -> T {
    do {
      return try body()
    } catch let error as PathSecurityError {
      throw Self.mapSecurityError(error)
    }
  }

  private static func mapSecurityError(_ error: PathSecurityError) -> ProjectMutationError {
    switch error {
    case .invalidRelativePath, .sensitiveFileBlocked, .pathEscapeBlocked:
      return .forbiddenPath
    case .rootUnavailable, .rootIdentityChanged, .fileIdentityChanged:
      return .unsafeFilesystemState
    case .pathDoesNotExist:
      return .pathMissing
    case .unsupportedFileType, .targetNotRegularFile:
      return .invalidRequest
    case .fileTooLarge:
      return .contentTooLarge
    case .binaryFileBlocked:
      return .binaryContent
    case .readFailed, .writeFailed:
      return .unsafeFilesystemState
    case .mutationAppliedDurabilityUncertain:
      return .durabilityUncertain
    case .targetAlreadyExists:
      return .pathExists
    case .unsupportedHardLink:
      return .unsupportedHardLink
    case .revisionConflict:
      return .revisionConflict
    case .pathChanged:
      return .pathChanged
    }
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
            action: .deleteFile(expectedSHA256: nil),
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

  private func apply(hunk: ProjectPatchHunk, to content: String) throws -> String {
    let before = hunk.removals
    let after = hunk.additions
    guard !before.isEmpty else { throw ProjectMutationError.invalidPatch }
    let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let matches = indices(of: before, in: lines)
    guard !matches.isEmpty else {
      throw ProjectMutationError.invalidPatch
    }
    let candidates =
      matches.count == 1
      ? matches
      : narrow(matches: matches, using: hunk.context, in: lines)
    guard candidates.count == 1, let matchIndex = candidates.first else {
      throw ProjectMutationError.invalidPatch
    }
    var updated = lines
    updated.replaceSubrange(matchIndex..<(matchIndex + before.count), with: after)
    return updated.joined(separator: "\n")
  }

  private func indices(of sequence: [String], in lines: [String]) -> [Int] {
    guard !sequence.isEmpty, sequence.count <= lines.count else { return [] }
    var matches: [Int] = []
    for index in 0...(lines.count - sequence.count) {
      if Array(lines[index..<(index + sequence.count)]) == sequence {
        matches.append(index)
      }
    }
    return matches
  }

  private func narrow(matches: [Int], using context: String, in lines: [String]) -> [Int] {
    let context = context.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !context.isEmpty else { return matches }

    let parts = context.components(separatedBy: "@@")
    let rangeParts = parts[0].split(whereSeparator: { $0 == " " || $0 == "\t" })
    if rangeParts.count >= 2,
      rangeParts[0].hasPrefix("-"),
      rangeParts[1].hasPrefix("+")
    {
      let sourceStart = rangeParts[0].dropFirst().split(separator: ",").first
        .flatMap { Int($0) }
      guard let sourceStart, sourceStart > 0 else { return [] }
      return matches.filter { $0 == sourceStart - 1 }
    }

    let label =
      parts.count > 1
      ? parts.dropFirst().joined(separator: "@@").trimmingCharacters(in: .whitespacesAndNewlines)
      : context
    guard !label.isEmpty else { return matches }
    return matches.filter { index in
      lines[..<index].contains { line in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed == label || trimmed.contains(label)
      }
    }
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

  private func textContent(_ value: String) throws -> Data {
    guard let data = value.data(using: .utf8) else { throw ProjectMutationError.binaryContent }
    guard !data.contains(0) else { throw ProjectMutationError.binaryContent }
    guard data.count <= writer.maximumBytes else { throw ProjectMutationError.contentTooLarge }
    return data
  }

  private func securePath(_ value: String) throws -> SecureRelativePath {
    do {
      return try SecureRelativePath(value)
    } catch {
      throw ProjectMutationError.forbiddenPath
    }
  }

  private func requireProject(_ id: ProjectID) async throws -> RegisteredProject {
    guard let project = try await repository.project(id: id) else {
      throw ProjectMutationError.unknownProject
    }
    try project.validateCurrentRoots()
    guard project.accessPolicy.read == .allowed else {
      throw ProjectMutationError.readNotAllowed
    }
    guard project.accessPolicy.write != .denied else {
      throw ProjectMutationError.writeNotAllowed
    }
    return project
  }
}

private struct StagedFile: Sendable {
  let path: SecureRelativePath
  let mode: SecureWriteMode
  let newContent: Data
  let oldRevision: SecureFileRevision?
  let oldContent: Data?
  let expectedSHA256: String?
}

enum BoundedDiffMaker {
  static let maximumLines = 500
  static let maximumBytes = 60 * 1_024

  static func make(old: String, new: String) -> BoundedDiff {
    let oldLines = old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let newLines = new.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let commonPrefix = zip(oldLines, newLines).prefix { $0 == $1 }.count
    let commonSuffix = zip(oldLines.reversed(), newLines.reversed()).prefix { $0 == $1 }.count
    let removed = oldLines[commonPrefix..<max(commonPrefix, oldLines.count - commonSuffix)]
    let added = newLines[commonPrefix..<max(commonPrefix, newLines.count - commonSuffix)]
    let boundedRemoved = Array(removed.prefix(maximumLines))
    let boundedAdded = Array(added.prefix(maximumLines))
    let truncated = removed.count > maximumLines || added.count > maximumLines
    return BoundedDiff(
      removedLines: boundedRemoved,
      addedLines: boundedAdded,
      truncated: truncated,
      byteCount: min(
        maximumBytes,
        boundedRemoved.reduce(0) { $0 + $1.utf8.count }
          + boundedAdded.reduce(0) { $0 + $1.utf8.count }
      )
    )
  }
}
