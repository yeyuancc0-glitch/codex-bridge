import BridgeCodexRPC
import BridgeSecurity
import Foundation
import XCTest

@testable import BridgeSupervisor

final class CodexSupervisorRuntimeTests: XCTestCase {
  func testReusesOneReadOnlyThreadAndDecodesStrictDecisions() async throws {
    let root = try temporaryRoot()
    let registered = try RegisteredRoot(capturing: root)
    let runtime = CodexSupervisorRuntime(
      configuration: configuration(script: supervisorScript(root: registered.canonicalPath))
    )
    addTeardownBlock { await runtime.shutdown() }

    let first = try await runtime.review(
      try checkpoint(sequence: 1, stage: .progress),
      root: registered
    )
    XCTAssertEqual(first.decision, .continue)
    XCTAssertEqual(first.summary, "Execution remains within the approved scope.")

    let second = try await runtime.review(
      try checkpoint(sequence: 2, stage: .final),
      root: registered
    )
    XCTAssertEqual(second.decision, .finalAccept)
    XCTAssertEqual(second.confidence, 0.98)
  }

  func testUnavailableLunaFailsWithoutModelFallback() async throws {
    let root = try temporaryRoot()
    let registered = try RegisteredRoot(capturing: root)
    let runtime = CodexSupervisorRuntime(
      configuration: configuration(script: unavailableModelScript)
    )
    addTeardownBlock { await runtime.shutdown() }

    do {
      _ = try await runtime.review(
        try checkpoint(sequence: 1, stage: .progress),
        root: registered
      )
      XCTFail("Expected the exact Supervisor model to be unavailable")
    } catch CodexSupervisorRuntimeError.modelUnavailable {}
  }

  private func checkpoint(
    sequence: UInt64,
    stage: SupervisorCheckpointStage
  ) throws -> SupervisorCheckpoint {
    try SupervisorCheckpoint(
      sequence: sequence,
      taskID: "task-supervisor",
      turnID: "turn-execution",
      stage: stage,
      triggers: [stage == .final ? .completionClaimed : .planChanged],
      content: SupervisorCheckpointContent(
        taskContract: "Keep the implementation within the approved task contract.",
        executionModel: "gpt-execution",
        executionEffort: "medium",
        remainingAutomaticSteers: 3
      )
    )
  }

  private func configuration(script: String) -> CodexSupervisorRuntimeConfiguration {
    CodexSupervisorRuntimeConfiguration(
      appServer: AppServerConfiguration(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", script],
        environment: ["PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"]
      ),
      clientInfo: .bridge(version: "supervisor-tests"),
      requestTimeoutNanoseconds: 1_000_000_000,
      reviewTimeoutNanoseconds: 1_000_000_000
    )
  }

  private func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "bridge-supervisor-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root.standardizedFileURL.resolvingSymlinksInPath()
  }

  private func supervisorScript(root: String) -> String {
    let thread = threadJSON(root: root)
    let firstDecision =
      #"{\"decision\":\"continue\",\"risk\":\"low\",\"summary\":\"Execution remains within the approved scope.\",\"evidence\":[\"The checkpoint is bounded.\"],\"instruction\":null,\"required_checks\":[],\"scope_violation\":false,\"confidence\":0.93,\"issue_id\":null}"#
    let finalDecision =
      #"{\"decision\":\"final_accept\",\"risk\":\"low\",\"summary\":\"The final checkpoint is accepted.\",\"evidence\":[\"Required evidence is present.\"],\"instruction\":null,\"required_checks\":[],\"scope_violation\":false,\"confidence\":0.98,\"issue_id\":null}"#
    let firstTurn = turnJSON(id: "supervisor-turn-1", decision: firstDecision)
    let finalTurn = turnJSON(id: "supervisor-turn-2", decision: finalDecision)
    return #"""
      IFS= read -r initialize
      printf '%s\n' '{"id":1,"result":{"userAgent":"fixture/1","codexHome":"/private/fixture","platformFamily":"unix","platformOs":"macos"}}'
      IFS= read -r initialized
      IFS= read -r models
      printf '%s\n' '{"id":2,"result":{"data":[{"id":"gpt-5.6-luna","model":"gpt-5.6-luna","displayName":"Luna","description":"Supervisor","hidden":false,"supportedReasoningEfforts":[{"reasoningEffort":"medium","description":"Medium"}],"defaultReasoningEffort":"medium","isDefault":false}],"nextCursor":null}}'
      IFS= read -r thread_start
      case "$thread_start" in *'"method":"thread/start"'*) ;; *) exit 31 ;; esac
      case "$thread_start" in *'"sandbox":"read-only"'*) ;; *) exit 32 ;; esac
      case "$thread_start" in *'"approvalPolicy":"never"'*) ;; *) exit 33 ;; esac
      case "$thread_start" in *'"ephemeral":false'*) ;; *) exit 34 ;; esac
      case "$thread_start" in *'"cwd":"__ROOT__"'*) ;; *) exit 35 ;; esac
      printf '%s\n' '{"id":3,"result":{"thread":__THREAD__,"model":"gpt-5.6-luna","modelProvider":"openai","reasoningEffort":"medium","cwd":"__ROOT__","sandbox":{"type":"readOnly","networkAccess":false},"approvalPolicy":"never","approvalsReviewer":"user","serviceTier":null}}'
      IFS= read -r first_turn
      case "$first_turn" in *'"method":"turn/start"'*) ;; *) exit 41 ;; esac
      case "$first_turn" in *'"approvalPolicy":"never"'*) ;; *) exit 42 ;; esac
      case "$first_turn" in *'"model":"gpt-5.6-luna"'*) ;; *) exit 43 ;; esac
      case "$first_turn" in *'"effort":"medium"'*) ;; *) exit 44 ;; esac
      case "$first_turn" in *'"outputSchema"'*) ;; *) exit 45 ;; esac
      case "$first_turn" in *'"networkAccess":false'*) ;; *) exit 46 ;; esac
      printf '%s\n' '{"id":4,"result":{"turn":__FIRST_TURN__}}'
      printf '%s\n' '{"method":"turn/completed","params":{"threadId":"supervisor-thread","turn":__FIRST_TURN__}}'
      IFS= read -r final_turn
      case "$final_turn" in *'"method":"turn/start"'*) ;; *) exit 51 ;; esac
      case "$final_turn" in *'"threadId":"supervisor-thread"'*) ;; *) exit 52 ;; esac
      printf '%s\n' '{"id":5,"result":{"turn":__FINAL_TURN__}}'
      printf '%s\n' '{"method":"turn/completed","params":{"threadId":"supervisor-thread","turn":__FINAL_TURN__}}'
      sleep 2
      """#
      .replacingOccurrences(of: "__ROOT__", with: root)
      .replacingOccurrences(of: "__THREAD__", with: thread)
      .replacingOccurrences(of: "__FIRST_TURN__", with: firstTurn)
      .replacingOccurrences(of: "__FINAL_TURN__", with: finalTurn)
  }

  private var unavailableModelScript: String {
    #"""
    IFS= read -r initialize
    printf '%s\n' '{"id":1,"result":{"userAgent":"fixture/1","codexHome":"/private/fixture","platformFamily":"unix","platformOs":"macos"}}'
    IFS= read -r initialized
    IFS= read -r models
    printf '%s\n' '{"id":2,"result":{"data":[{"id":"another-model","model":"another-model","displayName":"Other","description":"Other","hidden":false,"supportedReasoningEfforts":[{"reasoningEffort":"medium","description":"Medium"}],"defaultReasoningEffort":"medium","isDefault":true}],"nextCursor":null}}'
    sleep 2
    """#
  }

  private func threadJSON(root: String) -> String {
    #"{"id":"supervisor-thread","cwd":"\#(root)","ephemeral":false,"modelProvider":"openai","preview":"","turns":[],"name":null,"cliVersion":"fixture/1","createdAt":1,"updatedAt":1,"sessionId":"session-supervisor","status":{"type":"idle"},"source":"appServer"}"#
  }

  private func turnJSON(id: String, decision: String) -> String {
    #"{"id":"\#(id)","status":"completed","error":null,"items":[{"id":"message-\#(id)","type":"agentMessage","text":"\#(decision)"}],"itemsView":"full","startedAt":1,"completedAt":2,"durationMs":1}"#
  }
}
