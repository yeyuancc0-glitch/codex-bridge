import XCTest

@testable import BridgeSupervisor

final class SupervisorCheckpointEgressTests: XCTestCase {
  func testRejectsCredentialFormsAtConstruction() {
    let samples = [
      "runtime_key=1234567890abcdef",
      "api-key: 1234567890abcdef",
      #"{"api_key":"1234567890abcdef"}"#,
      "Authorization: Bearer abcdefghijklmnop",
      "Bearer abcdefghijklmnop",
      "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1c2VyIn0.signature_value",
      "-----BEGIN PRIVATE KEY-----",
      "-----BEGIN ENCRYPTED PRIVATE KEY-----",
      "x-codex-mcp-auth: 1234567890abcdef",
      "x-codex-runtime-key=1234567890abcdef",
      "sk-1234567890abcdef",
      "password=abcdefghijklmnop",
      "secret=abcdefghijklmnop",
      "ghp_1234567890abcdef",
      "github_pat_1234567890abcdef",
      "{'password':'abcdefghijklmnop'}",
      #""passwd": "abcdefghijklmnop""#,
      #""client_secret": 1234567890123456"#,
    ]

    for sample in samples {
      XCTAssertThrowsError(try checkpoint(taskContract: sample), "Accepted: \(sample)") { error in
        guard
          case SupervisorCheckpointValidationError.unsafeOutboundContent("task_contract") =
            error
        else {
          return XCTFail("Unexpected error: \(error)")
        }
      }
    }
  }

  func testRejectsLocalPathsAndFileURIsAtConstruction() {
    let samples = [
      "/Users/example/project/Secrets.swift",
      "Markdown: ](/Volumes/external/project/file.swift)",
      "file:///private/tmp/secret.txt",
      "Open ~/Library/Application Support/Codex/config.json",
      "/mnt/team/private.txt",
      "/srv/project/private.txt",
    ]

    for sample in samples {
      XCTAssertThrowsError(try checkpoint(taskContract: sample), "Accepted: \(sample)")
    }
  }

  func testConstructionRejectsNonstandardAbsoluteProjectRoot() {
    let root = "/workspace-special/project"

    XCTAssertThrowsError(
      try checkpoint(taskContract: "Inspect \(root)/Sources/App.swift")
    ) { error in
      guard
        case SupervisorCheckpointValidationError.unsafeOutboundContent("task_contract") =
          error
      else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  func testPromptPreservesNormalSourceSyntaxWithoutLeakingRoot() throws {
    let checkpoint = try checkpoint(
      taskContract: "Keep Sources/App/Router.swift behavior stable.",
      keyDiffs: [
        "let route = endpoint / component",
        "GET /api/v1/jobs returns the current jobs.",
      ]
    )

    let prompt = try SupervisorCheckpointPrompt.serialize(
      checkpoint,
      projectRoot: "/Volumes/private-project"
    )

    XCTAssertTrue(prompt.contains("Sources/App/Router.swift"))
    XCTAssertTrue(prompt.contains("GET /api/v1/jobs"))
    XCTAssertFalse(prompt.contains("/Volumes/private-project"))
    XCTAssertLessThanOrEqual(prompt.utf8.count, SupervisorCheckpointPrompt.maximumBytes)
  }

  func testRetainsExistingFieldLengthLimit() {
    let oversized = String(repeating: "a", count: 32 * 1024 + 1)
    XCTAssertThrowsError(try checkpoint(taskContract: oversized)) { error in
      guard
        case SupervisorCheckpointValidationError.stringTooLarge(
          field: "task_contract",
          maximumBytes: 32 * 1024
        ) = error
      else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  private func checkpoint(
    taskContract: String,
    keyDiffs: [String] = []
  ) throws -> SupervisorCheckpoint {
    try SupervisorCheckpoint(
      sequence: 1,
      taskID: "task-egress",
      turnID: "turn-egress",
      stage: .progress,
      triggers: [.planChanged],
      content: SupervisorCheckpointContent(
        taskContract: taskContract,
        executionModel: "gpt-execution",
        executionEffort: "medium",
        keyDiffs: keyDiffs,
        remainingAutomaticSteers: 3
      )
    )
  }
}
