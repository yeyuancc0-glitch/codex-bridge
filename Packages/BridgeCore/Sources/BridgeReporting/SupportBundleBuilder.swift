import Foundation

public struct SupportBundleBuilder: Sendable {
  public static let schemaVersion: UInt16 = 1

  private let limits: SupportBundleLimits

  public init(limits: SupportBundleLimits = .standard) {
    self.limits = limits
  }

  public func build(
    from input: SupportBundleInput,
    redaction: ReportingRedactionPolicy = .init()
  ) throws -> SupportBundleDocument {
    try validate(input, redaction: redaction)
    let redactor = SensitiveDataRedactor(policy: redaction)
    var redactionCount = 0
    let records = input.records.map { record in
      sanitized(record, redactor: redactor, redactionCount: &redactionCount)
    }.sorted(by: recordOrder)
    let bundle = SupportBundle(
      schemaVersion: Self.schemaVersion,
      generatedAt: input.generatedAt,
      records: records,
      redactionCount: redactionCount
    )
    let json = try ReportingJSON.encode(bundle)
    guard json.count <= limits.maximumJSONBytes else {
      throw ReportingError.limitExceeded(
        field: "support_bundle_json",
        maximum: limits.maximumJSONBytes
      )
    }
    return SupportBundleDocument(bundle: bundle, json: json)
  }

  private func validate(
    _ input: SupportBundleInput,
    redaction: ReportingRedactionPolicy
  ) throws {
    try validateLimits()
    try boundedCount(
      input.records.count, field: "support_bundle.records", limit: limits.maximumRecords)
    try boundedCount(
      redaction.sensitiveValues.count,
      field: "support_bundle.sensitive_values",
      limit: limits.maximumSensitiveValues
    )
    try unique(redaction.sensitiveValues, field: "support_bundle.sensitive_values")
    try unique(input.records.map(\.id), field: "support_bundle.record_id")
    for value in redaction.sensitiveValues {
      try require(value, field: "support_bundle.sensitive_value")
      guard value.utf8.count >= 8 else {
        throw ReportingError.invalidEvidence("support_bundle.sensitive_value")
      }
    }
    for record in input.records {
      try validate(record)
    }
    guard aggregateStringBytes(input, redaction: redaction) <= limits.maximumJSONBytes else {
      throw ReportingError.limitExceeded(
        field: "support_bundle_input",
        maximum: limits.maximumJSONBytes
      )
    }
  }

  private func validate(_ record: AllowedSupportRecord) throws {
    try require(record.id, field: "support_bundle.record.id")
    try bounded(record.summary, field: "support_bundle.record.summary")
    try boundedCount(
      record.fields.count,
      field: "support_bundle.record.fields",
      limit: limits.maximumFieldsPerRecord
    )
    try unique(record.fields.map(\.key), field: "support_bundle.record.field_key")
    for field in record.fields {
      try require(field.key, field: "support_bundle.record.field.key")
      guard !Self.isForbiddenFieldKey(field.key) else {
        throw ReportingError.invalidEvidence("support_bundle.raw_or_sensitive_field")
      }
      try bounded(field.value, field: "support_bundle.record.field.value")
    }
  }

  private func validateLimits() throws {
    let values = [
      limits.maximumJSONBytes,
      limits.maximumStringBytes,
      limits.maximumRecords,
      limits.maximumFieldsPerRecord,
      limits.maximumSensitiveValues,
    ]
    guard values.allSatisfy({ $0 > 0 }) else {
      throw ReportingError.invalidEvidence("support_bundle_limits")
    }
  }

  private func require(_ value: String, field: String) throws {
    guard !value.isEmpty else { throw ReportingError.invalidEvidence(field) }
    try bounded(value, field: field)
  }

  private func bounded(_ value: String, field: String) throws {
    guard value.utf8.count <= limits.maximumStringBytes else {
      throw ReportingError.limitExceeded(field: field, maximum: limits.maximumStringBytes)
    }
  }

  private func boundedCount(_ count: Int, field: String, limit: Int) throws {
    guard count <= limit else {
      throw ReportingError.limitExceeded(field: field, maximum: limit)
    }
  }

  private func unique<T: Hashable>(_ values: [T], field: String) throws {
    guard Set(values).count == values.count else {
      throw ReportingError.invalidEvidence(field)
    }
  }

  private func sanitized(
    _ record: AllowedSupportRecord,
    redactor: SensitiveDataRedactor,
    redactionCount: inout Int
  ) -> AllowedSupportRecord {
    let id = accumulating(redactor.redact(record.id), count: &redactionCount)
    let summary = accumulating(redactor.redact(record.summary), count: &redactionCount)
    let fields = record.fields.map { field in
      let key = accumulating(redactor.redact(field.key), count: &redactionCount)
      let value = accumulating(redactor.redact(field.value), count: &redactionCount)
      return SupportRecordField(key: key, value: value)
    }.sorted(by: fieldOrder)
    return AllowedSupportRecord(
      id: id,
      source: record.source,
      level: record.level,
      timestamp: record.timestamp,
      summary: summary,
      fields: fields
    )
  }

  private func accumulating(_ value: RedactedValue, count: inout Int) -> String {
    count += value.count
    return value.value
  }

  private func recordOrder(_ lhs: AllowedSupportRecord, _ rhs: AllowedSupportRecord) -> Bool {
    if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
    if lhs.source != rhs.source { return lhs.source.rawValue < rhs.source.rawValue }
    return lhs.id < rhs.id
  }

  private func fieldOrder(_ lhs: SupportRecordField, _ rhs: SupportRecordField) -> Bool {
    if lhs.key != rhs.key { return lhs.key < rhs.key }
    return lhs.value < rhs.value
  }

  private func aggregateStringBytes(
    _ input: SupportBundleInput,
    redaction: ReportingRedactionPolicy
  ) -> Int {
    var total = 0
    let values =
      input.records.flatMap { record in
        [record.id, record.summary] + record.fields.flatMap { [$0.key, $0.value] }
      } + redaction.sensitiveValues
    for value in values {
      let (next, overflow) = total.addingReportingOverflow(value.utf8.count)
      if overflow { return Int.max }
      total = next
    }
    return total
  }

  private static func isForbiddenFieldKey(_ key: String) -> Bool {
    let normalized = key.lowercased().replacingOccurrences(of: "-", with: "_")
    return [
      "stdout", "stderr", "raw_output", "codex_output", "helper_output", "command_output",
      "file_content", "diff", "patch", "authorization", "cookie", "password", "token",
      "secret", "credential", "runtime_key",
    ].contains { normalized.contains($0) }
  }
}
