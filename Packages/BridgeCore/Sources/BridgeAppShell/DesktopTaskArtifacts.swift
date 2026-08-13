import BridgeApplication
import BridgeDomain
import BridgeGit
import BridgeMCP
import BridgePipeline
import BridgeSecurity
import Foundation

struct DesktopTaskArtifactQueries: TaskArtifactQuerying {
  private enum Cursor: Equatable {
    case files(Int)
    case patch(Int)
  }

  let artifacts: PipelineArtifactStore
  let patches: GitPatchStore

  func summary(
    taskID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> TaskArtifactSummary {
    try Self.checkDeadline(deadline)
    guard let scope = try await artifacts.currentScope(for: TaskID(rawValue: taskID)) else {
      return TaskArtifactSummary()
    }
    let final: GitFinalEvidence? = try await artifacts.trustedPayload(
      for: scope,
      kind: .gitFinal
    )
    let verificationCount = try await artifacts.artifacts(for: scope).count { record in
      if case .verification = record.kind { return true }
      return false
    }
    try Self.checkDeadline(deadline)
    return TaskArtifactSummary(
      changedFileCount: final?.changedFiles.count ?? 0,
      verificationSummary: verificationCount == 0 ? nil : "已记录 \(verificationCount) 项验证证据"
    )
  }

  func diff(
    taskID: String,
    cursor: String?,
    limit: Int,
    includePatch: Bool,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPTaskDiffPage {
    guard (1...100).contains(limit) else { throw BridgeApplicationError.invalidArgument }
    try Self.checkDeadline(deadline)
    guard let scope = try await artifacts.currentScope(for: TaskID(rawValue: taskID)),
      let baseline: GitBaselineEvidence = try await artifacts.trustedPayload(
        for: scope,
        kind: .gitBaseline
      ),
      let final: GitFinalEvidence = try await artifacts.trustedPayload(
        for: scope,
        kind: .gitFinal
      )
    else {
      throw BridgeMCPQueryError.unavailable
    }
    let parsedCursor = try Self.cursor(cursor)
    let response = try await page(
      taskID: taskID,
      cursor: parsedCursor,
      limit: limit,
      includePatch: includePatch,
      baseline: baseline,
      final: final
    )
    try Self.checkDeadline(deadline)
    return response
  }

  private func page(
    taskID: String,
    cursor: Cursor,
    limit: Int,
    includePatch: Bool,
    baseline: GitBaselineEvidence,
    final: GitFinalEvidence
  ) async throws -> MCPTaskDiffPage {
    switch cursor {
    case .files(let start):
      return try filesPage(
        taskID: taskID,
        start: start,
        limit: limit,
        includePatch: includePatch,
        baseline: baseline,
        final: final
      )
    case .patch(let offset):
      guard includePatch, let handle = final.patch else {
        throw BridgeApplicationError.invalidArgument
      }
      let page = try await patches.page(
        for: handle,
        offset: offset,
        maximumBytes: 24 * 1_024
      )
      let decoded = try Self.utf8Page(page.bytes)
      return try Self.encodablePatchPage(
        taskID: taskID,
        offset: offset,
        totalBytes: page.totalBytes,
        decoded: decoded,
        diffStat: Self.safeDiffStat(final.diffStat),
        baselineWasDirty: baseline.status.isDirty
      )
    }
  }

  private func filesPage(
    taskID: String,
    start: Int,
    limit: Int,
    includePatch: Bool,
    baseline: GitBaselineEvidence,
    final: GitFinalEvidence
  ) throws -> MCPTaskDiffPage {
    guard start <= final.changedFiles.count else {
      throw BridgeApplicationError.invalidArgument
    }
    let changes = Dictionary(uniqueKeysWithValues: final.status.entries.map { ($0.path, $0) })
    let requestedEnd = min(final.changedFiles.count, start + limit)
    let requested = final.changedFiles[start..<requestedEnd].enumerated().map { offset, path in
      MCPTaskDiffFile(
        relativePath: Self.safeRelativePath(path, index: start + offset),
        status: Self.status(changes[path])
      )
    }
    return try Self.encodableFilesPage(
      taskID: taskID,
      start: start,
      totalFiles: final.changedFiles.count,
      files: requested,
      diffStat: Self.safeDiffStat(final.diffStat),
      includePatch: includePatch,
      hasPatch: final.patch != nil,
      baselineWasDirty: baseline.status.isDirty
    )
  }

  private static func cursor(_ value: String?) throws -> Cursor {
    guard let value else { return .files(0) }
    let parts = value.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2, let offset = Int(parts[1]), offset >= 0 else {
      throw BridgeApplicationError.invalidArgument
    }
    switch parts[0] {
    case "files": return .files(offset)
    case "patch": return .patch(offset)
    default: throw BridgeApplicationError.invalidArgument
    }
  }

  private static func status(_ change: GitFileChange?) -> String {
    guard let change else { return "modified" }
    switch change.kind {
    case .untracked: return "untracked"
    case .unmerged: return "unmerged"
    case .renamedOrCopied: return "renamed_or_copied"
    case .ordinary:
      let codes = [change.indexStatus, change.workTreeStatus].compactMap { $0 }
      if codes.contains(where: { $0.contains("D") }) { return "deleted" }
      if codes.contains(where: { $0.contains("A") }) { return "added" }
      return "modified"
    }
  }

  private static func utf8Page(_ data: Data) throws -> String {
    var end = data.count
    while end > max(0, data.count - 3) {
      if let value = String(data: data.prefix(end), encoding: .utf8) { return value }
      end -= 1
    }
    throw BridgeMCPQueryError.unavailable
  }

  private static func encodablePatchPage(
    taskID: String,
    offset: Int,
    totalBytes: Int,
    decoded: String,
    diffStat: String,
    baselineWasDirty: Bool
  ) throws -> MCPTaskDiffPage {
    let encoder = MCPToolResultEncoder()
    var maximumBytes = decoded.utf8.count
    while maximumBytes > 0 {
      let bytes = Data(decoded.utf8.prefix(maximumBytes))
      let patch = try utf8Page(bytes)
      let consumed = patch.utf8.count
      let nextOffset = offset + consumed
      let candidate = MCPTaskDiffPage(
        taskID: taskID,
        files: [],
        diffStat: diffStat,
        patch: patch,
        nextCursor: nextOffset < totalBytes ? "patch:\(nextOffset)" : nil,
        baselineWasDirty: baselineWasDirty
      )
      do {
        _ = try encoder.encodeTaskDiffPage(candidate)
        return candidate
      } catch MCPToolResultEncodingError.resultTooLarge {
        maximumBytes = max(0, consumed / 2)
      }
    }
    throw BridgeMCPQueryError.unavailable
  }

  private static func encodableFilesPage(
    taskID: String,
    start: Int,
    totalFiles: Int,
    files: [MCPTaskDiffFile],
    diffStat: String,
    includePatch: Bool,
    hasPatch: Bool,
    baselineWasDirty: Bool
  ) throws -> MCPTaskDiffPage {
    let encoder = MCPToolResultEncoder()
    var count = files.count
    while count > 0 || files.isEmpty {
      let end = start + count
      let nextCursor: String?
      if end < totalFiles {
        nextCursor = "files:\(end)"
      } else if includePatch, hasPatch {
        nextCursor = "patch:0"
      } else {
        nextCursor = nil
      }
      let candidate = MCPTaskDiffPage(
        taskID: taskID,
        files: Array(files.prefix(count)),
        diffStat: diffStat,
        nextCursor: nextCursor,
        baselineWasDirty: baselineWasDirty
      )
      do {
        _ = try encoder.encodeTaskDiffPage(candidate)
        return candidate
      } catch MCPToolResultEncodingError.resultTooLarge {
        guard count > 1 else { break }
        count = max(1, count / 2)
      }
    }
    throw BridgeMCPQueryError.unavailable
  }

  private static func safeRelativePath(_ value: String, index: Int) -> String {
    guard OutboundContentSecurity.isSafeOutboundRelativePath(value)
    else {
      return "[redacted-sensitive-path-\(index)]"
    }
    return value
  }

  private static func safeDiffStat(_ value: String) -> String {
    OutboundContentSecurity.redacted(value, maximumUTF8Bytes: 8 * 1_024)
  }

  private static func checkDeadline(_ deadline: ContinuousClock.Instant) throws {
    guard ContinuousClock.now < deadline else { throw BridgeMCPQueryError.timeout }
  }
}
