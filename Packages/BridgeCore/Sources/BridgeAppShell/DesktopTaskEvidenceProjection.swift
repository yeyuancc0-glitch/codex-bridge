import BridgeCoordinator
import BridgeDomain
import BridgeGit
import BridgePipeline
import BridgeReporting
import BridgeRepositories
import BridgeSecurity
import BridgeVerification
import Foundation

enum DesktopTaskEvidenceProjectionError: Error, Equatable, Sendable {
  case deadlineExceeded
  case scopeMismatch
  case evidenceMismatch(String)
  case invalidReport
}

struct DesktopTaskEvidenceValues: Equatable, Sendable {
  static let empty = DesktopTaskEvidenceValues()

  let commands: [String]
  let changedFiles: [String]
  let diffSummary: String?
  let supervisionSummary: String?
  let verificationSummary: String?

  init(
    commands: [String] = [],
    changedFiles: [String] = [],
    diffSummary: String? = nil,
    supervisionSummary: String? = nil,
    verificationSummary: String? = nil
  ) {
    self.commands = commands
    self.changedFiles = changedFiles
    self.diffSummary = diffSummary
    self.supervisionSummary = supervisionSummary
    self.verificationSummary = verificationSummary
  }
}

struct DesktopTaskEvidenceIdentity: Equatable, Sendable {
  let taskID: TaskID
  let lastSequence: Int64
  let binding: ExecutionBinding?
  let reportReference: String?

  init(_ projection: TaskProjection) {
    taskID = projection.aggregate.id
    lastSequence = projection.lastSequence
    binding = projection.aggregate.binding
    reportReference = projection.aggregate.reportReference
  }
}

struct DesktopTaskEvidenceProjectionResult: Equatable, Sendable {
  let identity: DesktopTaskEvidenceIdentity
  let values: DesktopTaskEvidenceValues
}

struct DesktopTaskEvidenceProjection: Sendable {
  private static let maximumCommands = 128
  private static let maximumChangedFiles = 256
  private static let maximumCommandBytes = 4 * 1_024
  private static let maximumSummaryBytes = 8 * 1_024

  let artifacts: PipelineArtifactStore
  let patches: GitPatchStore
  let reports: any FinalReportStore
  let coordinator: TaskCoordinator

  func project(
    taskID: TaskID,
    deadline: ContinuousClock.Instant
  ) async throws -> DesktopTaskEvidenceValues {
    try await projectBound(taskID: taskID, deadline: deadline).values
  }

  func projectBound(
    taskID: TaskID,
    deadline: ContinuousClock.Instant
  ) async throws -> DesktopTaskEvidenceProjectionResult {
    try Self.checkDeadline(deadline)
    let task = try await coordinator.task(taskID)
    try Self.checkDeadline(deadline)
    guard let scope = try await artifacts.currentScope(for: taskID) else {
      guard task.aggregate.phase != .completed else {
        throw DesktopTaskEvidenceProjectionError.evidenceMismatch("scope.missing")
      }
      let finalTask = try await coordinator.task(taskID)
      try Self.validateUnchanged(initial: task, final: finalTask)
      return DesktopTaskEvidenceProjectionResult(
        identity: DesktopTaskEvidenceIdentity(finalTask),
        values: .empty
      )
    }
    try Self.validate(scope: scope, task: task)
    let records = try await artifacts.artifacts(for: scope)
    try await validateRequiredEvidence(records, task: task, scope: scope)
    let git = try await gitValues(scope: scope)
    let verification = try await verificationSummary(scope: scope, records: records)
    let supervisor = try await supervisorSummary(scope: scope, records: records)
    let commands = try await commandValues(scope: scope, task: task)
    try Self.checkDeadline(deadline)
    let finalTask = try await coordinator.task(taskID)
    try Self.validateUnchanged(initial: task, final: finalTask)
    return DesktopTaskEvidenceProjectionResult(
      identity: DesktopTaskEvidenceIdentity(finalTask),
      values: DesktopTaskEvidenceValues(
        commands: commands,
        changedFiles: git.changedFiles,
        diffSummary: git.summary,
        supervisionSummary: supervisor,
        verificationSummary: verification
      )
    )
  }

  private func gitValues(
    scope: TaskEvidenceScope
  ) async throws -> (changedFiles: [String], summary: String?) {
    guard
      let final: GitFinalEvidence = try await artifacts.trustedPayload(
        for: scope,
        kind: .gitFinal
      )
    else { return ([], nil) }
    guard final.projectIdentifier == scope.projectID.rawValue else {
      throw DesktopTaskEvidenceProjectionError.evidenceMismatch("git.project")
    }
    let allPaths = Array(Set(final.changedFiles + final.untrackedFiles)).sorted()
    let visiblePaths = allPaths.prefix(Self.maximumChangedFiles).enumerated().map { index, path in
      Self.safeRelativePath(path, index: index)
    }
    var summaryParts = [Self.safeText(final.diffStat, maximumBytes: Self.maximumSummaryBytes)]
    if allPaths.count > visiblePaths.count {
      summaryParts.append("仅展示前 \(visiblePaths.count) 个，共 \(allPaths.count) 个变更路径。")
    }
    if let patch = final.patch {
      summaryParts.append(await patchSummary(patch))
    }
    let summary = Self.joinedSummary(summaryParts)
    return (Array(visiblePaths), summary)
  }

  private func patchSummary(_ handle: GitPatchHandle) async -> String {
    do {
      let page = try await patches.page(for: handle, offset: 0, maximumBytes: 1)
      guard page.totalBytes == handle.totalBytes else { return "Patch 证据当前不可用。" }
      let suffix = page.isTruncated ? "，采集时已截断" : ""
      return "Patch 证据可用：\(page.totalBytes) bytes\(suffix)。"
    } catch {
      return "Patch 证据当前不可用。"
    }
  }

  private func verificationSummary(
    scope: TaskEvidenceScope,
    records: [PipelineArtifactRecord]
  ) async throws -> String? {
    let kinds = records.compactMap { record -> PipelineArtifactKind? in
      if case .verification = record.kind { return record.kind }
      return nil
    }
    var summaries: [String] = []
    for kind in kinds {
      guard
        let evidence: PipelineVerificationEvidence = try await artifacts.trustedPayload(
          for: scope,
          kind: kind
        )
      else { throw DesktopTaskEvidenceProjectionError.evidenceMismatch("verification.missing") }
      guard kind == .verification(evidence.id.rawValue) else {
        throw DesktopTaskEvidenceProjectionError.evidenceMismatch("verification.id")
      }
      summaries.append(Self.verification(evidence))
    }
    return Self.joinedSummary(summaries.sorted())
  }

  private func supervisorSummary(
    scope: TaskEvidenceScope,
    records: [PipelineArtifactRecord]
  ) async throws -> String? {
    guard records.contains(where: { $0.kind == .supervisorFinalDecision }) else { return nil }
    guard
      let evidence: PipelineSupervisorFinalEvidence = try await artifacts.trustedPayload(
        for: scope,
        kind: .supervisorFinalDecision
      ), evidence.scope == scope
    else { throw DesktopTaskEvidenceProjectionError.evidenceMismatch("supervisor.scope") }
    let decision = evidence.decision
    let confidence = Int((decision.confidence * 100).rounded())
    let value =
      "\(decision.decision.rawValue) · 风险 \(decision.risk.rawValue) · "
      + "置信度 \(confidence)% · \(decision.summary)"
    return Self.safeText(value, maximumBytes: Self.maximumSummaryBytes)
  }

  private func commandValues(
    scope: TaskEvidenceScope,
    task: TaskProjection
  ) async throws -> [String] {
    guard let reportReference = task.aggregate.reportReference else {
      guard task.aggregate.phase != .completed else {
        throw DesktopTaskEvidenceProjectionError.invalidReport
      }
      return []
    }
    guard
      let metadata: PipelineReportMetadataEvidence = try await artifacts.trustedPayload(
        for: scope,
        kind: .reportMetadata
      ),
      let stored = try await reports.finalReport(for: scope.taskID)
    else { throw DesktopTaskEvidenceProjectionError.invalidReport }
    guard metadata.scope == scope, metadata.reportJSON == stored.json else {
      throw DesktopTaskEvidenceProjectionError.invalidReport
    }
    guard task.aggregate.phase == .completed, reportReference == metadata.reportReference else {
      throw DesktopTaskEvidenceProjectionError.invalidReport
    }
    let document: FinalReportDocument
    do {
      document = try ReportBuilder().restore(canonicalJSON: stored.json)
    } catch {
      throw DesktopTaskEvidenceProjectionError.invalidReport
    }
    try Self.validate(report: document.report, stored: stored, scope: scope, task: task)
    return document.report.commands.prefix(Self.maximumCommands).map(Self.command)
  }

  private static func validate(scope: TaskEvidenceScope, task: TaskProjection) throws {
    guard let binding = task.aggregate.binding,
      let generation = Int64(exactly: binding.turnGeneration),
      scope.taskID == task.aggregate.id,
      scope.projectID == task.aggregate.submission.projectID,
      scope.threadID == binding.threadID,
      scope.turnID == binding.turnID,
      scope.generation == generation,
      scope.eventSequence <= task.lastSequence
    else { throw DesktopTaskEvidenceProjectionError.scopeMismatch }
  }

  private static func validate(
    report: FinalReport,
    stored: StoredFinalReport,
    scope: TaskEvidenceScope,
    task: TaskProjection
  ) throws {
    guard stored.metadata.taskID == scope.taskID,
      stored.metadata.schemaVersion == report.schemaVersion,
      stored.metadata.status == .completed,
      report.status == .completed,
      stored.metadata.byteCount == stored.json.count,
      stored.metadata.threadID == scope.threadID.rawValue,
      stored.metadata.project == report.project,
      report.taskID == scope.taskID.rawValue,
      report.threadID == scope.threadID.rawValue,
      report.execution.model == task.aggregate.submission.execution.model,
      report.execution.effort == task.aggregate.submission.execution.effort
    else { throw DesktopTaskEvidenceProjectionError.invalidReport }
  }

  private static func validateUnchanged(
    initial: TaskProjection,
    final: TaskProjection
  ) throws {
    guard initial.aggregate.id == final.aggregate.id,
      initial.lastSequence == final.lastSequence,
      initial.aggregate.phase == final.aggregate.phase,
      initial.aggregate.binding == final.aggregate.binding,
      initial.aggregate.reportReference == final.aggregate.reportReference
    else { throw DesktopTaskEvidenceProjectionError.scopeMismatch }
  }

  private func validateRequiredEvidence(
    _ records: [PipelineArtifactRecord],
    task: TaskProjection,
    scope: TaskEvidenceScope
  ) async throws {
    guard task.aggregate.phase == .completed else { return }
    let kinds = Set(records.map(\.kind))
    guard let finalization = try await artifacts.finalization(for: scope.taskID),
      let baseline: GitBaselineEvidence = try await artifacts.trustedPayload(
        for: scope,
        kind: .gitBaseline
      ),
      let final: GitFinalEvidence = try await artifacts.trustedPayload(
        for: scope,
        kind: .gitFinal
      ),
      finalization.scope == scope,
      finalization.stage == .completed,
      kinds.contains(.gitBaseline),
      kinds.contains(.gitFinal),
      kinds.contains(.supervisorFinalDecision),
      kinds.contains(.reportMetadata),
      kinds.contains(where: { kind in
        if case .verification = kind { return true }
        return false
      }),
      baseline.projectIdentifier == scope.projectID.rawValue,
      final.projectIdentifier == scope.projectID.rawValue,
      baseline.canonicalRootPath == final.canonicalRootPath,
      baseline.rootIdentity != nil,
      final.patch?.isTruncated != true
    else { throw DesktopTaskEvidenceProjectionError.evidenceMismatch("completed.missing") }
  }

  private static func command(_ value: AppServerCommandEvidence) -> String {
    let executable = URL(fileURLWithPath: value.executable).lastPathComponent
    let arguments = value.arguments.map { argument in
      if argument.hasPrefix("/") || argument.hasPrefix("~") { return "[path]" }
      return safeText(argument, maximumBytes: 1_024)
    }
    let exit = value.exitCode.map { " exit=\($0)" } ?? ""
    return safeText(
      ([executable] + arguments).joined(separator: " ") + exit,
      maximumBytes: maximumCommandBytes
    )
  }

  private static func verification(_ value: PipelineVerificationEvidence) -> String {
    switch value {
    case .run(let result):
      let executable = URL(fileURLWithPath: result.executableName).lastPathComponent
      let required = result.required ? "必需" : "可选"
      let exit = result.exitCode.map { "，exit=\($0)" } ?? ""
      return safeText(
        "\(executable)：\(result.status.rawValue)（\(required)\(exit)）",
        maximumBytes: maximumCommandBytes
      )
    case .unavailable(_, let name, let required, let reason):
      let requirement = required ? "必需" : "可选"
      return safeText(
        "\(name)：unavailable（\(requirement)）· \(reason)",
        maximumBytes: maximumCommandBytes
      )
    }
  }

  private static func safeRelativePath(_ value: String, index: Int) -> String {
    guard OutboundContentSecurity.isSafeOutboundRelativePath(value, maximumUTF8Bytes: 4_096)
    else { return "[redacted-sensitive-path-\(index)]" }
    return value
  }

  private static func joinedSummary(_ values: [String]) -> String? {
    let nonempty = values.filter { !$0.isEmpty }
    guard !nonempty.isEmpty else { return nil }
    return safeText(nonempty.joined(separator: "\n"), maximumBytes: maximumSummaryBytes)
  }

  private static func safeText(_ value: String, maximumBytes: Int) -> String {
    OutboundContentSecurity.redacted(value, maximumUTF8Bytes: maximumBytes)
  }

  private static func checkDeadline(_ deadline: ContinuousClock.Instant) throws {
    guard ContinuousClock.now < deadline else {
      throw DesktopTaskEvidenceProjectionError.deadlineExceeded
    }
  }
}
