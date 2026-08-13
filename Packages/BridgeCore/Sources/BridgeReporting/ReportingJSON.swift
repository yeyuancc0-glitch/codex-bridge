import Foundation

enum ReportingJSON {
  static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }

  static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    decoder.keyDecodingStrategy = .custom { path in
      ReportingCodingKey(Self.propertyName(for: path.last?.stringValue ?? ""))
    }
    return try decoder.decode(type, from: data)
  }

  private static func propertyName(for key: String) -> String {
    let components = key.split(separator: "_", omittingEmptySubsequences: false)
    guard let first = components.first else { return key }
    var result = String(first)
    for component in components.dropFirst() {
      result += component.prefix(1).uppercased() + component.dropFirst()
    }
    if result.count > 2, result.hasSuffix("Id") {
      result.replaceSubrange(result.index(result.endIndex, offsetBy: -2)..., with: "ID")
    }
    return result
  }
}

private struct ReportingCodingKey: CodingKey {
  let stringValue: String
  let intValue: Int? = nil

  init(_ stringValue: String) {
    self.stringValue = stringValue
  }

  init?(stringValue: String) {
    self.init(stringValue)
  }

  init?(intValue: Int) {
    return nil
  }
}

struct ReportInputValidator {
  let limits: ReportingLimits

  func validate(_ input: FinalReportInput, redaction: ReportingRedactionPolicy) throws {
    try validateLimits()
    try require(input.taskID, field: "task_id")
    try require(input.project, field: "project")
    try validate(input.appServer)
    try validate(input.git)
    try validate(input.verification)
    try validate(input.supervisor)
    try validate(input.policy)
    try validate(input.userOverride)
    if let narrative = input.untrustedCodexNarrative {
      try bounded(
        narrative,
        field: "untrusted_codex_narrative",
        maximum: limits.maximumStringBytes
      )
    }
    try count(
      redaction.sensitiveValues, field: "sensitive_values", maximum: limits.maximumSensitiveValues)
    guard Set(redaction.sensitiveValues).count == redaction.sensitiveValues.count else {
      throw ReportingError.invalidEvidence("sensitive_values")
    }
    for value in redaction.sensitiveValues {
      try require(value, field: "sensitive_value", maximum: limits.maximumStringBytes)
      guard value.utf8.count >= 8 else {
        throw ReportingError.invalidEvidence("sensitive_value")
      }
    }
    guard aggregateStringBytes(input, redaction: redaction) <= limits.maximumJSONBytes else {
      throw ReportingError.limitExceeded(
        field: "final_report_input",
        maximum: limits.maximumJSONBytes
      )
    }
  }

  func require(_ value: String, field: String, maximum: Int? = nil) throws {
    guard !value.isEmpty else { throw ReportingError.invalidEvidence(field) }
    try bounded(value, field: field, maximum: maximum ?? limits.maximumStringBytes)
  }

  func bounded(_ value: String, field: String, maximum: Int) throws {
    guard value.utf8.count <= maximum else {
      throw ReportingError.limitExceeded(field: field, maximum: maximum)
    }
  }

  func count<T>(_ values: [T], field: String, maximum: Int? = nil) throws {
    let bound = maximum ?? limits.maximumItems
    guard values.count <= bound else {
      throw ReportingError.limitExceeded(field: field, maximum: bound)
    }
  }

  private func validateLimits() throws {
    let values = [
      limits.maximumJSONBytes,
      limits.maximumStringBytes,
      limits.maximumPathBytes,
      limits.maximumItems,
      limits.maximumArgumentsPerCommand,
      limits.maximumSensitiveValues,
    ]
    guard values.allSatisfy({ $0 > 0 }) else {
      throw ReportingError.invalidEvidence("reporting_limits")
    }
  }

  private func validate(_ evidence: AppServerEvidence) throws {
    try require(evidence.threadID, field: "app_server.thread_id")
    try require(evidence.model, field: "app_server.model")
    try require(evidence.effort, field: "app_server.effort")
    guard evidence.startedAt <= evidence.completedAt else {
      throw ReportingError.invalidEvidence("app_server.timestamps")
    }
    try count(evidence.commands, field: "app_server.commands")
    try unique(evidence.commands.map(\.sequence), field: "app_server.command_sequence")
    for command in evidence.commands {
      try require(command.executable, field: "app_server.command.executable")
      try count(
        command.arguments,
        field: "app_server.command.arguments",
        maximum: limits.maximumArgumentsPerCommand
      )
      for argument in command.arguments {
        try bounded(
          argument, field: "app_server.command.argument", maximum: limits.maximumStringBytes)
      }
    }
  }

  private func validate(_ evidence: GitEvidence) throws {
    try count(evidence.changedFiles, field: "git.changed_files")
    try bounded(evidence.diffStat, field: "git.diff_stat", maximum: limits.maximumStringBytes)
    try unique(evidence.changedFiles.map(\.relativePath), field: "git.changed_file_path")
    for file in evidence.changedFiles {
      try require(
        file.relativePath,
        field: "git.changed_file.relative_path",
        maximum: limits.maximumPathBytes
      )
    }
    if let commit = evidence.commit {
      try require(commit, field: "git.commit")
    }
  }

  private func validate(_ evidence: [VerificationEvidence]) throws {
    try count(evidence, field: "verification")
    try unique(evidence.map(\.id), field: "verification.id")
    for item in evidence {
      try require(item.id, field: "verification.id")
      try require(item.name, field: "verification.name")
      try validateOutcome(item)
    }
  }

  private func validateOutcome(_ evidence: VerificationEvidence) throws {
    switch evidence.status {
    case .passed:
      guard evidence.exitCode == 0, evidence.unavailableReason == nil else {
        throw ReportingError.invalidEvidence("verification.passed")
      }
    case .failed:
      guard let exitCode = evidence.exitCode, exitCode != 0,
        evidence.unavailableReason == nil
      else {
        throw ReportingError.invalidEvidence("verification.failed")
      }
    case .unavailable:
      guard evidence.exitCode == nil, let reason = evidence.unavailableReason else {
        throw ReportingError.invalidEvidence("verification.unavailable")
      }
      try require(reason, field: "verification.unavailable_reason")
    }
  }

  private func validate(_ evidence: SupervisorEvidence?) throws {
    guard let evidence else { return }
    try require(evidence.model, field: "supervisor.model")
    try require(evidence.effort, field: "supervisor.effort")
    guard evidence.checks >= 0, evidence.steers >= 0 else {
      throw ReportingError.invalidEvidence("supervisor.counts")
    }
  }

  private func validate(_ evidence: PolicyEvidence) throws {
    try count(evidence.unresolvedBlockers, field: "policy.unresolved_blockers")
    try count(evidence.warnings, field: "policy.warnings")
    for blocker in evidence.unresolvedBlockers {
      try require(blocker, field: "policy.unresolved_blocker")
    }
    for warning in evidence.warnings {
      try require(warning, field: "policy.warning")
    }
  }

  private func validate(_ evidence: UserCompletionOverride?) throws {
    guard let evidence else { return }
    try require(evidence.decisionID, field: "user_override.decision_id")
    try require(evidence.reason, field: "user_override.reason")
  }

  private func unique<T: Hashable>(_ values: [T], field: String) throws {
    guard Set(values).count == values.count else {
      throw ReportingError.invalidEvidence(field)
    }
  }

  private func aggregateStringBytes(
    _ input: FinalReportInput,
    redaction: ReportingRedactionPolicy
  ) -> Int {
    var values = [
      input.taskID, input.project, input.appServer.threadID, input.appServer.model,
      input.appServer.effort, input.git.diffStat,
    ]
    values += input.appServer.commands.flatMap { [$0.executable] + $0.arguments }
    values += input.git.changedFiles.map(\.relativePath)
    values += input.verification.flatMap {
      [$0.id, $0.name] + [$0.unavailableReason].compactMap { $0 }
    }
    values += input.policy.unresolvedBlockers + input.policy.warnings
    values += [input.git.commit, input.untrustedCodexNarrative].compactMap { $0 }
    if let supervisor = input.supervisor {
      values += [supervisor.model, supervisor.effort]
    }
    if let userOverride = input.userOverride {
      values += [userOverride.decisionID, userOverride.reason]
    }
    values += redaction.sensitiveValues
    return values.reduce(into: 0) { total, value in
      let (next, overflow) = total.addingReportingOverflow(value.utf8.count)
      total = overflow ? Int.max : next
    }
  }
}
