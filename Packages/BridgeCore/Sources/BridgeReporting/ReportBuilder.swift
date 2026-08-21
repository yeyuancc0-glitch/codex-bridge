import Foundation

public struct ReportBuilder: Sendable {
  public static let schemaVersion: UInt16 = 1

  private let limits: ReportingLimits

  public init(limits: ReportingLimits = .standard) {
    self.limits = limits
  }

  public func build(
    from input: FinalReportInput,
    redaction: ReportingRedactionPolicy = .init()
  ) throws -> FinalReportDocument {
    let validator = ReportInputValidator(limits: limits)
    try validator.validate(input, redaction: redaction)
    let authority = try completionAuthority(for: input)
    let report = sanitizedReport(
      from: input,
      authority: authority,
      redactor: SensitiveDataRedactor(policy: redaction)
    )
    let json = try ReportingJSON.encode(report)
    guard json.count <= limits.maximumJSONBytes else {
      throw ReportingError.limitExceeded(
        field: "final_report_json",
        maximum: limits.maximumJSONBytes
      )
    }
    return FinalReportDocument(report: report, json: json)
  }

  public func restore(canonicalJSON json: Data) throws -> FinalReportDocument {
    guard !json.isEmpty, json.count <= limits.maximumJSONBytes else {
      throw ReportingError.limitExceeded(
        field: "final_report_json",
        maximum: limits.maximumJSONBytes
      )
    }
    guard let report = try? ReportingJSON.decode(FinalReport.self, from: json),
      report.schemaVersion == Self.schemaVersion,
      try ReportingJSON.encode(report) == json
    else { throw ReportingError.invalidEvidence("final_report_json") }
    return FinalReportDocument(report: report, json: json)
  }

  private func completionAuthority(for input: FinalReportInput) throws -> CompletionAuthority? {
    guard input.status == .completed else { return nil }
    try validateCompletionEvidence(input)
    if input.supervisor?.finalDecision == .finalAccept {
      return .supervisorFinalAccept
    }
    guard input.userOverride != nil else {
      throw ReportingError.missingEvidence("supervisor_final_accept_or_user_override")
    }
    return .userOverride
  }

  private func validateCompletionEvidence(_ input: FinalReportInput) throws {
    guard input.appServer.terminalState == .completed else {
      throw ReportingError.missingEvidence("app_server_terminal_completion")
    }
    guard input.git.baselineCaptured, input.git.finalStateCaptured else {
      throw ReportingError.missingEvidence("git_baseline_and_final_state")
    }
    guard !input.verification.isEmpty else {
      throw ReportingError.missingEvidence("verification_exit_or_unavailable_reason")
    }
    guard !input.verification.contains(where: { $0.required && $0.status == .failed }) else {
      throw ReportingError.invalidEvidence("required_verification_failed")
    }
    guard input.policy.evaluationCompleted else {
      throw ReportingError.missingEvidence("policy_evaluation")
    }
    guard input.policy.unresolvedBlockers.isEmpty else {
      throw ReportingError.invalidEvidence("policy_blockers_unresolved")
    }
  }

  private func sanitizedReport(
    from input: FinalReportInput,
    authority: CompletionAuthority?,
    redactor: SensitiveDataRedactor
  ) -> FinalReport {
    let appServer = sanitizedAppServer(input.appServer, redactor: redactor)
    let git = sanitizedGit(input.git, redactor: redactor)
    let verification = sanitizedVerification(input.verification, redactor: redactor)
    let supervisor = sanitizedSupervisor(input.supervisor, redactor: redactor)
    let policy = sanitizedPolicy(input.policy, redactor: redactor)
    let userOverride = sanitizedOverride(input.userOverride, redactor: redactor)
    let evidence = ReportEvidence(
      sources: evidenceSources(hasSupervisor: supervisor != nil),
      appServer: appServer,
      git: git,
      verification: verification,
      supervisor: supervisor,
      policy: policy,
      completionAuthority: authority,
      userOverride: userOverride
    )
    return FinalReport(
      schemaVersion: Self.schemaVersion,
      taskID: redactor.redact(input.taskID).value,
      status: input.status,
      project: redactor.redact(input.project).value,
      threadID: appServer.threadID,
      execution: ExecutionReport(model: appServer.model, effort: appServer.effort),
      supervisor: supervisor,
      summary: summary(for: input, git: git, verification: verification),
      changedFiles: git.changedFiles,
      diffStat: git.diffStat,
      commands: appServer.commands,
      verification: verification,
      warnings: warnings(for: git, verification: verification, policy: policy),
      unresolvedItems: unresolvedItems(verification: verification, policy: policy),
      commit: git.commit,
      startedAt: appServer.startedAt,
      completedAt: appServer.completedAt,
      evidence: evidence
    )
  }

  private func sanitizedAppServer(
    _ input: AppServerEvidence,
    redactor: SensitiveDataRedactor
  ) -> AppServerReportEvidence {
    let commands = input.commands.map { command in
      AppServerCommandEvidence(
        sequence: command.sequence,
        executable: redactor.redact(command.executable).value,
        arguments: command.arguments.map { redactor.redact($0).value },
        exitCode: command.exitCode
      )
    }.sorted(by: commandOrder)
    return AppServerReportEvidence(
      threadID: redactor.redact(input.threadID).value,
      model: redactor.redact(input.model).value,
      effort: redactor.redact(input.effort).value,
      terminalState: input.terminalState,
      commands: commands,
      startedAt: input.startedAt,
      completedAt: input.completedAt
    )
  }

  private func sanitizedGit(
    _ input: GitEvidence,
    redactor: SensitiveDataRedactor
  ) -> GitEvidence {
    let changedFiles = input.changedFiles.map { file in
      GitChangedFileEvidence(
        relativePath: redactor.redactPath(file.relativePath).value,
        change: file.change
      )
    }.sorted(by: fileOrder)
    return GitEvidence(
      baselineCaptured: input.baselineCaptured,
      finalStateCaptured: input.finalStateCaptured,
      dirtyAtStart: input.dirtyAtStart,
      changedFiles: changedFiles,
      diffStat: redactor.redact(input.diffStat).value,
      commit: input.commit.map { redactor.redact($0).value }
    )
  }

  private func sanitizedVerification(
    _ input: [VerificationEvidence],
    redactor: SensitiveDataRedactor
  ) -> [VerificationEvidence] {
    input.map { evidence in
      VerificationEvidence(
        id: redactor.redact(evidence.id).value,
        name: redactor.redact(evidence.name).value,
        required: evidence.required,
        status: evidence.status,
        exitCode: evidence.exitCode,
        unavailableReason: evidence.unavailableReason.map { redactor.redact($0).value }
      )
    }.sorted(by: verificationOrder)
  }

  private func sanitizedSupervisor(
    _ input: SupervisorEvidence?,
    redactor: SensitiveDataRedactor
  ) -> SupervisorEvidence? {
    guard let input else { return nil }
    return SupervisorEvidence(
      model: redactor.redact(input.model).value,
      effort: redactor.redact(input.effort).value,
      checks: input.checks,
      steers: input.steers,
      finalDecision: input.finalDecision
    )
  }

  private func sanitizedPolicy(
    _ input: PolicyEvidence,
    redactor: SensitiveDataRedactor
  ) -> PolicyEvidence {
    PolicyEvidence(
      evaluationCompleted: input.evaluationCompleted,
      unresolvedBlockers: normalized(input.unresolvedBlockers, redactor: redactor),
      warnings: normalized(input.warnings, redactor: redactor)
    )
  }

  private func sanitizedOverride(
    _ input: UserCompletionOverride?,
    redactor: SensitiveDataRedactor
  ) -> UserCompletionOverride? {
    guard let input else { return nil }
    return UserCompletionOverride(
      decisionID: redactor.redact(input.decisionID).value,
      reason: redactor.redact(input.reason).value,
      confirmedAt: input.confirmedAt
    )
  }

  private func evidenceSources(hasSupervisor: Bool) -> [ReportFactSource] {
    var sources: [ReportFactSource] = [
      .appServerEvents,
      .gitEvidence,
      .verificationExits,
    ]
    if hasSupervisor { sources.append(.supervisorDecision) }
    sources.append(.policyEngine)
    return sources
  }

  private func summary(
    for input: FinalReportInput,
    git: GitEvidence,
    verification: [VerificationEvidence]
  ) -> String {
    let passed = verification.count(where: { $0.status == .passed })
    let unavailable = verification.count(where: { $0.status == .unavailable })
    let failed = verification.count(where: { $0.status == .failed })
    return "App-server terminal state: \(input.appServer.terminalState.rawValue). "
      + "Git captured \(git.changedFiles.count) changed files. "
      + "Verification: \(passed) passed, \(unavailable) unavailable, \(failed) failed."
  }

  private func warnings(
    for git: GitEvidence,
    verification: [VerificationEvidence],
    policy: PolicyEvidence
  ) -> [String] {
    var values = policy.warnings
    if git.dirtyAtStart { values.append("The working tree was dirty before the task started.") }
    values += verification.compactMap { item in
      guard item.status == .unavailable else { return nil }
      return "Verification unavailable: \(item.name)."
    }
    return Array(Set(values)).sorted()
  }

  private func unresolvedItems(
    verification: [VerificationEvidence],
    policy: PolicyEvidence
  ) -> [String] {
    var values = policy.unresolvedBlockers
    values += verification.compactMap { item in
      guard item.required, item.status == .failed else { return nil }
      return "Required verification failed: \(item.name)."
    }
    return Array(Set(values)).sorted()
  }

  private func normalized(
    _ values: [String],
    redactor: SensitiveDataRedactor
  ) -> [String] {
    Array(Set(values.map { redactor.redact($0).value })).sorted()
  }

  private func commandOrder(
    _ lhs: AppServerCommandEvidence,
    _ rhs: AppServerCommandEvidence
  ) -> Bool {
    if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
    if lhs.executable != rhs.executable { return lhs.executable < rhs.executable }
    return lhs.arguments.lexicographicallyPrecedes(rhs.arguments)
  }

  private func fileOrder(_ lhs: GitChangedFileEvidence, _ rhs: GitChangedFileEvidence) -> Bool {
    if lhs.relativePath != rhs.relativePath { return lhs.relativePath < rhs.relativePath }
    return lhs.change.rawValue < rhs.change.rawValue
  }

  private func verificationOrder(_ lhs: VerificationEvidence, _ rhs: VerificationEvidence) -> Bool {
    if lhs.id != rhs.id { return lhs.id < rhs.id }
    return lhs.name < rhs.name
  }
}
