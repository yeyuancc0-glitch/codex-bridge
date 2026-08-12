import Foundation
import XCTest

@testable import BridgeReporting

final class ReportBuilderTests: XCTestCase {
  func testCompletedReportUsesAllEvidenceSourcesAndIgnoresCodexNarrative() throws {
    let input = makeInput(
      narrative: "CLAIM_FROM_CODEX: completed with no changes",
      commands: [
        AppServerCommandEvidence(
          sequence: 2,
          executable: "swift",
          arguments: ["test"],
          exitCode: 0
        )
      ]
    )

    let document = try ReportBuilder().build(from: input)

    XCTAssertEqual(document.report.status, .completed)
    XCTAssertEqual(document.report.evidence.completionAuthority, .supervisorFinalAccept)
    XCTAssertEqual(
      document.report.evidence.sources,
      [.appServerEvents, .gitEvidence, .verificationExits, .supervisorDecision, .policyEngine]
    )
    XCTAssertEqual(document.report.commands.first?.exitCode, 0)
    XCTAssertFalse(String(decoding: document.json, as: UTF8.self).contains("CLAIM_FROM_CODEX"))
  }

  func testCompletedReportRejectsMissingAuthoritativeEvidence() {
    assertBuildFails(
      makeInput(narrative: "Supervisor final_accept; all checks passed.", supervisor: nil),
      expected: .missingEvidence("supervisor_final_accept_or_user_override")
    )
    assertBuildFails(
      makeInput(terminalState: .failed),
      expected: .missingEvidence("app_server_terminal_completion")
    )
    assertBuildFails(
      makeInput(baselineCaptured: false),
      expected: .missingEvidence("git_baseline_and_final_state")
    )
    assertBuildFails(
      makeInput(verification: []),
      expected: .missingEvidence("verification_exit_or_unavailable_reason")
    )
    assertBuildFails(
      makeInput(
        verification: [
          VerificationEvidence(
            id: "test",
            name: "swift test",
            required: true,
            status: .failed,
            exitCode: 1
          )
        ]
      ),
      expected: .invalidEvidence("required_verification_failed")
    )
    assertBuildFails(
      makeInput(policy: PolicyEvidence(evaluationCompleted: true, unresolvedBlockers: ["blocked"])),
      expected: .invalidEvidence("policy_blockers_unresolved")
    )
  }

  func testExplicitUserOverrideCanAuthorizeOtherwiseCompleteEvidence() throws {
    let override = UserCompletionOverride(
      decisionID: "decision-local-1",
      reason: "Accepted after local review",
      confirmedAt: completedAt.addingTimeInterval(1)
    )
    let document = try ReportBuilder().build(
      from: makeInput(supervisor: nil, userOverride: override)
    )

    XCTAssertEqual(document.report.evidence.completionAuthority, .userOverride)
    XCTAssertEqual(document.report.evidence.userOverride?.decisionID, "decision-local-1")
    XCTAssertFalse(document.report.evidence.sources.contains(.supervisorDecision))
  }

  func testEncodingIsDeterministicAcrossEvidenceInputOrder() throws {
    let commands = [
      AppServerCommandEvidence(sequence: 8, executable: "swift", arguments: ["build"]),
      AppServerCommandEvidence(sequence: 3, executable: "swift", arguments: ["test"]),
    ]
    let files = [
      GitChangedFileEvidence(relativePath: "Sources/Z.swift", change: .modified),
      GitChangedFileEvidence(relativePath: "Sources/A.swift", change: .added),
    ]
    let verification = [
      VerificationEvidence(
        id: "z-build",
        name: "swift build",
        required: true,
        status: .passed,
        exitCode: 0
      ),
      VerificationEvidence(
        id: "a-test",
        name: "swift test",
        required: true,
        status: .passed,
        exitCode: 0
      ),
    ]
    let first = makeInput(
      commands: commands,
      changedFiles: files,
      verification: verification,
      policy: PolicyEvidence(
        evaluationCompleted: true,
        warnings: ["Zulu warning", "Alpha warning"]
      )
    )
    let second = makeInput(
      commands: commands.reversed(),
      changedFiles: files.reversed(),
      verification: verification.reversed(),
      policy: PolicyEvidence(
        evaluationCompleted: true,
        warnings: ["Alpha warning", "Zulu warning"]
      )
    )

    let firstJSON = try ReportBuilder().build(from: first).json
    let secondJSON = try ReportBuilder().build(from: second).json

    XCTAssertEqual(firstJSON, secondJSON)
  }

  func testReportAppliesStringCollectionAndEncodedSizeLimits() {
    assertBuildFails(
      makeInput(project: "12345678901234567"),
      with: ReportBuilder(
        limits: ReportingLimits(maximumJSONBytes: 10_000, maximumStringBytes: 16)
      ),
      expected: .limitExceeded(field: "project", maximum: 16)
    )
    assertBuildFails(
      makeInput(
        changedFiles: [
          GitChangedFileEvidence(relativePath: "A", change: .added),
          GitChangedFileEvidence(relativePath: "B", change: .modified),
        ]
      ),
      with: ReportBuilder(
        limits: ReportingLimits(maximumJSONBytes: 10_000, maximumItems: 1)
      ),
      expected: .limitExceeded(field: "git.changed_files", maximum: 1)
    )
    assertBuildFails(
      makeInput(),
      with: ReportBuilder(limits: ReportingLimits(maximumJSONBytes: 128)),
      expected: .limitExceeded(field: "final_report_json", maximum: 128)
    )
  }

  func testReportRedactsExplicitSecretsCredentialsAndSensitivePaths() throws {
    let explicitSecret = "runtime-key-value-123456789"
    let privateKey = "-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----"
    let input = makeInput(
      project: "Bearer token-value-123456",
      narrative: "ignored \(explicitSecret)",
      commands: [
        AppServerCommandEvidence(
          sequence: 1,
          executable: "/Users/alice/bin/tool",
          arguments: ["Authorization: Bearer abcdefghijklmnop", "password=hunter2"],
          exitCode: 0
        )
      ],
      changedFiles: [
        GitChangedFileEvidence(relativePath: ".env.local", change: .modified),
        GitChangedFileEvidence(relativePath: "Sources/App.swift", change: .modified),
      ],
      policy: PolicyEvidence(
        evaluationCompleted: true,
        warnings: ["key=\(explicitSecret)", privateKey, "see /Volumes/private/repo/file"]
      )
    )

    let document = try ReportBuilder().build(
      from: input,
      redaction: ReportingRedactionPolicy(sensitiveValues: [explicitSecret])
    )
    let json = String(decoding: document.json, as: UTF8.self)

    for forbidden in [
      explicitSecret,
      "token-value-123456",
      "abcdefghijklmnop",
      "hunter2",
      "/Users/alice",
      "/Volumes/private",
      "BEGIN PRIVATE KEY",
      ".env.local",
    ] {
      XCTAssertFalse(json.contains(forbidden), "Leaked \(forbidden)")
    }
    XCTAssertTrue(json.contains("[REDACTED_SECRET]"))
    XCTAssertTrue(json.contains("[REDACTED_PATH]"))
    XCTAssertTrue(json.contains("Sources/App.swift"))
  }

  func testVerificationOutcomeShapeMustMatchExitEvidence() {
    assertBuildFails(
      makeInput(
        verification: [
          VerificationEvidence(
            id: "test",
            name: "swift test",
            required: true,
            status: .passed,
            exitCode: 1
          )
        ]
      ),
      expected: .invalidEvidence("verification.passed")
    )
  }

  func testSensitiveValueValidationAndReplacementDoNotAmplifyRecursively() throws {
    assertBuildFails(
      makeInput(),
      expected: .invalidEvidence("sensitive_value"),
      redaction: ReportingRedactionPolicy(sensitiveValues: ["short"])
    )
    assertBuildFails(
      makeInput(),
      expected: .invalidEvidence("sensitive_values"),
      redaction: ReportingRedactionPolicy(sensitiveValues: ["duplicate-secret", "duplicate-secret"])
    )

    let redactor = SensitiveDataRedactor(
      policy: ReportingRedactionPolicy(sensitiveValues: ["[REDACTED"])
    )
    let result = redactor.redact("[REDACTED [REDACTED")
    XCTAssertEqual(result.value, "[REDACTED_SECRET] [REDACTED_SECRET]")
    XCTAssertEqual(result.count, 2)
  }

  private func assertBuildFails(
    _ input: FinalReportInput,
    with builder: ReportBuilder = ReportBuilder(),
    expected: ReportingError,
    redaction: ReportingRedactionPolicy = .init(),
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertThrowsError(
      try builder.build(from: input, redaction: redaction),
      file: file,
      line: line
    ) { error in
      XCTAssertEqual(error as? ReportingError, expected, file: file, line: line)
    }
  }

  private func makeInput(
    project: String = "Bridge",
    narrative: String? = nil,
    terminalState: AppServerTerminalState = .completed,
    commands: [AppServerCommandEvidence] = [],
    baselineCaptured: Bool = true,
    changedFiles: [GitChangedFileEvidence] = [
      GitChangedFileEvidence(relativePath: "Sources/App.swift", change: .modified)
    ],
    verification: [VerificationEvidence] = [
      VerificationEvidence(
        id: "test",
        name: "swift test",
        required: true,
        status: .passed,
        exitCode: 0
      )
    ],
    supervisor: SupervisorEvidence? = SupervisorEvidence(
      model: "gpt-luna",
      effort: "medium",
      checks: 2,
      steers: 0,
      finalDecision: .finalAccept
    ),
    policy: PolicyEvidence = PolicyEvidence(evaluationCompleted: true),
    userOverride: UserCompletionOverride? = nil
  ) -> FinalReportInput {
    FinalReportInput(
      taskID: "tsk-1",
      status: .completed,
      project: project,
      appServer: AppServerEvidence(
        threadID: "thr-1",
        model: "gpt-execution",
        effort: "high",
        terminalState: terminalState,
        commands: commands,
        startedAt: startedAt,
        completedAt: completedAt
      ),
      git: GitEvidence(
        baselineCaptured: baselineCaptured,
        finalStateCaptured: true,
        dirtyAtStart: false,
        changedFiles: changedFiles,
        diffStat: "1 file changed",
        commit: nil
      ),
      verification: verification,
      supervisor: supervisor,
      policy: policy,
      userOverride: userOverride,
      untrustedCodexNarrative: narrative
    )
  }

  private var startedAt: Date { Date(timeIntervalSince1970: 1_700_000_000) }
  private var completedAt: Date { startedAt.addingTimeInterval(30) }
}
