import Foundation
import XCTest

@testable import BridgeReporting

final class SupportBundleBuilderTests: XCTestCase {
  func testBundleUsesOnlyTypedAllowedRecordsAndRedactsContent() throws {
    let explicitSecret = "secret-runtime-value-123456"
    let records = [
      AllowedSupportRecord(
        id: "connection-1",
        source: .connectionStatus,
        level: .warning,
        timestamp: later,
        summary: "Bearer bearer-secret-123456 at /Users/alice/Library/file",
        fields: [
          SupportRecordField(key: "runtime", value: explicitSecret),
          SupportRecordField(key: "config", value: "password=hunter2"),
        ]
      ),
      AllowedSupportRecord(
        id: "verification-1",
        source: .verificationResult,
        level: .info,
        timestamp: earlier,
        summary: "Verification passed",
        fields: [SupportRecordField(key: "exit_code", value: "0")]
      ),
    ]
    let document = try SupportBundleBuilder().build(
      from: SupportBundleInput(generatedAt: generatedAt, records: records),
      redaction: ReportingRedactionPolicy(sensitiveValues: [explicitSecret])
    )
    let json = String(decoding: document.json, as: UTF8.self)

    XCTAssertEqual(document.bundle.schemaVersion, 1)
    XCTAssertEqual(document.bundle.records.map(\.id), ["verification-1", "connection-1"])
    XCTAssertGreaterThanOrEqual(document.bundle.redactionCount, 4)
    for forbidden in [explicitSecret, "bearer-secret-123456", "/Users/alice", "hunter2"] {
      XCTAssertFalse(json.contains(forbidden), "Leaked \(forbidden)")
    }
    XCTAssertFalse(json.contains("helper_output"))
    XCTAssertFalse(json.contains("codex_output"))
  }

  func testBundleEncodingIsDeterministic() throws {
    let firstRecord = AllowedSupportRecord(
      id: "a",
      source: .policyDecision,
      level: .info,
      timestamp: earlier,
      summary: "Allowed",
      fields: [
        SupportRecordField(key: "z", value: "2"),
        SupportRecordField(key: "a", value: "1"),
      ]
    )
    let secondRecord = AllowedSupportRecord(
      id: "b",
      source: .reportSummary,
      level: .info,
      timestamp: later,
      summary: "Complete"
    )
    let builder = SupportBundleBuilder()
    let first = try builder.build(
      from: SupportBundleInput(generatedAt: generatedAt, records: [secondRecord, firstRecord])
    )
    let second = try builder.build(
      from: SupportBundleInput(
        generatedAt: generatedAt,
        records: [
          AllowedSupportRecord(
            id: "a",
            source: .policyDecision,
            level: .info,
            timestamp: earlier,
            summary: "Allowed",
            fields: firstRecord.fields.reversed()
          ),
          secondRecord,
        ]
      )
    )

    XCTAssertEqual(first.json, second.json)
  }

  func testBundleEnforcesRecordFieldStringAndJSONLimits() {
    assertBuildFails(
      records: [record(id: "a"), record(id: "b")],
      limits: SupportBundleLimits(maximumJSONBytes: 10_000, maximumRecords: 1),
      expected: .limitExceeded(field: "support_bundle.records", maximum: 1)
    )
    assertBuildFails(
      records: [
        AllowedSupportRecord(
          id: "a",
          source: .applicationDiagnostic,
          level: .info,
          timestamp: earlier,
          summary: "ok",
          fields: [
            SupportRecordField(key: "a", value: "1"),
            SupportRecordField(key: "b", value: "2"),
          ]
        )
      ],
      limits: SupportBundleLimits(
        maximumJSONBytes: 10_000,
        maximumFieldsPerRecord: 1
      ),
      expected: .limitExceeded(field: "support_bundle.record.fields", maximum: 1)
    )
    assertBuildFails(
      records: [record(id: "12345")],
      limits: SupportBundleLimits(maximumJSONBytes: 10_000, maximumStringBytes: 4),
      expected: .limitExceeded(field: "support_bundle.record.id", maximum: 4)
    )
    assertBuildFails(
      records: [record(id: "a")],
      limits: SupportBundleLimits(maximumJSONBytes: 64),
      expected: .limitExceeded(field: "support_bundle_json", maximum: 64)
    )
  }

  func testBundleRejectsRawProcessOutputAndCredentialFields() {
    for key in ["codex_output", "helper-stdout", "authorization_token", "raw_patch"] {
      assertBuildFails(
        records: [
          AllowedSupportRecord(
            id: "a",
            source: .applicationDiagnostic,
            level: .warning,
            timestamp: earlier,
            summary: "Rejected field",
            fields: [SupportRecordField(key: key, value: "not accepted")]
          )
        ],
        limits: .standard,
        expected: .invalidEvidence("support_bundle.raw_or_sensitive_field")
      )
    }
  }

  func testBundleRejectsUnsafeSensitiveValuesAndOversizedAggregateInput() {
    let input = SupportBundleInput(generatedAt: generatedAt, records: [record(id: "a")])
    XCTAssertThrowsError(
      try SupportBundleBuilder().build(
        from: input,
        redaction: ReportingRedactionPolicy(sensitiveValues: ["short"])
      )
    ) { error in
      XCTAssertEqual(
        error as? ReportingError,
        .invalidEvidence("support_bundle.sensitive_value")
      )
    }

    let large = AllowedSupportRecord(
      id: "a",
      source: .applicationDiagnostic,
      level: .info,
      timestamp: earlier,
      summary: String(repeating: "x", count: 80)
    )
    assertBuildFails(
      records: [large],
      limits: SupportBundleLimits(maximumJSONBytes: 64, maximumStringBytes: 128),
      expected: .limitExceeded(field: "support_bundle_input", maximum: 64)
    )
  }

  private func assertBuildFails(
    records: [AllowedSupportRecord],
    limits: SupportBundleLimits,
    expected: ReportingError,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertThrowsError(
      try SupportBundleBuilder(limits: limits).build(
        from: SupportBundleInput(generatedAt: generatedAt, records: records)
      ),
      file: file,
      line: line
    ) { error in
      XCTAssertEqual(error as? ReportingError, expected, file: file, line: line)
    }
  }

  private func record(id: String) -> AllowedSupportRecord {
    AllowedSupportRecord(
      id: id,
      source: .applicationDiagnostic,
      level: .info,
      timestamp: earlier,
      summary: "ok"
    )
  }

  private var generatedAt: Date { Date(timeIntervalSince1970: 1_700_000_100) }
  private var earlier: Date { Date(timeIntervalSince1970: 1_700_000_000) }
  private var later: Date { earlier.addingTimeInterval(30) }
}
