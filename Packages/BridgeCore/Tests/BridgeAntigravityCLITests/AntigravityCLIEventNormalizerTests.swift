import BridgeAgentCore
import BridgeDomain
import BridgeProcess
import Foundation
import XCTest

@testable import BridgeAntigravityCLI

final class AntigravityCLIEventNormalizerTests: XCTestCase {
  func testNormalizesTextToolUsageAndTerminalCompletion() async throws {
    let projectRoot = try AntigravityCLITestSupport.temporaryDirectory(prefix: "agy-normalizer")
    defer { try? FileManager.default.removeItem(atPath: projectRoot) }
    let normalizer = try makeNormalizer(projectRoot: projectRoot)

    let first = try await normalizer.normalize(
      try XCTUnwrap(
        AntigravityCLITestSupport.decode(
          AntigravityStreamEnvelope.self,
          String(
            decoding: AntigravityCLITestSupport.stepUpdateFrame(textDelta: "Hello "),
            as: UTF8.self
          )
        ).stepUpdate
      )
    )
    let second = try await normalizer.normalize(
      try XCTUnwrap(
        AntigravityCLITestSupport.decode(
          AntigravityStreamEnvelope.self,
          String(
            decoding: AntigravityCLITestSupport.stepUpdateFrame(
              stepIndex: 1,
              textDelta: "world"
            ),
            as: UTF8.self
          )
        ).stepUpdate
      )
    )
    let tool = try await normalizer.normalize(
      try XCTUnwrap(
        AntigravityCLITestSupport.decode(
          AntigravityStreamEnvelope.self,
          String(
            decoding: AntigravityCLITestSupport.stepUpdateFrame(
              stepIndex: 2,
              state: "DONE",
              stepType: "tool",
              textDelta: nil,
              toolName: "read_file",
              toolInfo:
                "{\"name\":\"read_file\",\"parameters\":{\"path\":\"Sources/main.swift\",\"outside\":\"/tmp/outside\"},\"output\":\"ok\",\"error\":null}",
              usage: "{\"total_tokens\":5}"
            ),
            as: UTF8.self
          )
        ).stepUpdate
      )
    )

    XCTAssertTrue(first.isEmpty)
    XCTAssertTrue(second.isEmpty)
    guard case .tool(let toolUpdate) = try XCTUnwrap(tool.first).event,
      case .usage(let usageUpdate) = try XCTUnwrap(tool.last).event
    else {
      return XCTFail("Expected tool and usage events")
    }
    XCTAssertEqual(toolUpdate.name, "read_file")
    XCTAssertEqual(toolUpdate.status, .completed)
    XCTAssertEqual(toolUpdate.locations, [projectRoot + "/Sources/main.swift"])
    XCTAssertEqual(toolUpdate.output, "ok")
    XCTAssertEqual(usageUpdate.usedTokens, 5)

    let resultEnvelope = try AntigravityCLITestSupport.decode(
      AntigravityStreamEnvelope.self,
      String(
        decoding: try AntigravityCLITestSupport.resultFrame(response: "All done."),
        as: UTF8.self
      )
    )
    let result = try await normalizer.normalize(
      try XCTUnwrap(resultEnvelope.result),
      permissionDenied: false,
      terminal: true
    )

    guard case .content(let finalUpdate) = try XCTUnwrap(result.first).event,
      case .completed(let summary, let stopReason) = try XCTUnwrap(result.last).event
    else {
      return XCTFail("Expected authoritative content followed by completion")
    }
    XCTAssertEqual(finalUpdate.mode, .full)
    XCTAssertEqual(finalUpdate.content, "All done.")
    XCTAssertTrue(finalUpdate.isFinal)
    XCTAssertTrue(finalUpdate.authoritative)
    XCTAssertEqual(summary, "All done.")
    XCTAssertEqual(stopReason, "SUCCESS")

    let all = tool + result
    XCTAssertEqual(all.map(\.providerSequence), Array(0..<all.count).map(Int64.init))
  }

  func testNormalizesSubagentAndFailedToolEvents() async throws {
    let projectRoot = try AntigravityCLITestSupport.temporaryDirectory(prefix: "agy-subagent")
    defer { try? FileManager.default.removeItem(atPath: projectRoot) }
    let normalizer = try makeNormalizer(projectRoot: projectRoot)

    let subagentUpdate = try AntigravityCLITestSupport.decode(
      AntigravityStreamEnvelope.self,
      """
      {"event":"step_update","step_update":{"conversation_id":"conversation-1","step_index":4,"state":"ACTIVE","step_type":"subagent","tool_name":null,"text_delta":null,"duration_seconds":null,"usage":null,"tool_info":null,"subagent_info":{"subagents":[{"type_name":"reviewer","role":"review","conversation_id":"sub-1","log_uri":null,"workspace_uris":null}]}}}
      """
    )
    let subagent = try await normalizer.normalize(try XCTUnwrap(subagentUpdate.stepUpdate))
    guard case .tool(let subagentTool) = try XCTUnwrap(subagent.first).event else {
      return XCTFail("Expected subagent tool event")
    }
    XCTAssertEqual(subagentTool.kind, "subagent")
    XCTAssertEqual(subagentTool.status, .inProgress)
    XCTAssertTrue(subagentTool.output?.contains("review") == true)

    let failedToolUpdate = try AntigravityCLITestSupport.decode(
      AntigravityStreamEnvelope.self,
      """
      {"event":"step_update","step_update":{"conversation_id":"conversation-1","step_index":5,"state":"DONE","step_type":"tool","tool_name":"run_command","text_delta":null,"duration_seconds":null,"usage":null,"tool_info":{"name":"run_command","parameters":{"command":"git status"},"output":null,"error":{"type":"permission","message":"requires approval"}},"subagent_info":null}}
      """
    )
    let failed = try await normalizer.normalize(try XCTUnwrap(failedToolUpdate.stepUpdate))
    guard case .tool(let failedTool) = try XCTUnwrap(failed.first).event else {
      return XCTFail("Expected failed tool event")
    }
    XCTAssertEqual(failedTool.status, .failed)
    XCTAssertEqual(failedTool.output, "requires approval")
  }

  func testSoftPermissionDenialFailsInsteadOfCompleting() async throws {
    let normalizer = try makeNormalizer()
    let resultEnvelope = try AntigravityCLITestSupport.decode(
      AntigravityStreamEnvelope.self,
      String(
        decoding: try AntigravityCLITestSupport.resultFrame(response: "Looks complete."),
        as: UTF8.self
      )
    )

    let events = try await normalizer.normalize(
      try XCTUnwrap(resultEnvelope.result),
      permissionDenied: true,
      terminal: true,
      permissionMode: "request-review"
    )

    XCTAssertEqual(events.count, 3)
    guard case .content = events[0].event,
      case .approvalAutomaticallyDenied(let reason) = events[1].event,
      case .failed(let code, _) = events[2].event
    else {
      return XCTFail("Expected content, automatic denial, and failure")
    }
    XCTAssertEqual(reason, "antigravity-soft-denial")
    XCTAssertEqual(code, "antigravity_permission_denied")
    guard case .failed(_, let summary) = events[2].event else {
      return XCTFail("Expected a permission-denied summary")
    }
    XCTAssertTrue(summary.contains("permission_mode=request-review"))
    XCTAssertTrue(summary.contains("toolPermission=proceed-in-sandbox"))
    XCTAssertTrue(summary.contains("provider response was preserved"))
    XCTAssertFalse(
      events.contains { event in
        if case .completed = event.event { return true }
        return false
      })
  }

  func testRedactsBearerAndPrivateKeyMaterialFromResultContent() async throws {
    let normalizer = try makeNormalizer()
    let result = try AntigravityCLITestSupport.decode(
      AntigravityStreamEnvelope.self,
      #"""
      {"event":"result","result":{"conversation_id":"conversation-1","status":"SUCCESS","response":"Bearer abc123\n-----BEGIN PRIVATE KEY-----\nprivate-value\n-----END PRIVATE KEY-----","error":null,"duration_seconds":null,"num_turns":1,"usage":null}}
      """#
    )
    let events = try await normalizer.normalize(
      try XCTUnwrap(result.result),
      permissionDenied: false,
      terminal: true
    )

    guard case .content(let content) = try XCTUnwrap(events.first).event,
      case .completed(let summary, _) = try XCTUnwrap(events.last).event
    else {
      return XCTFail("Expected redacted content followed by completion")
    }
    XCTAssertTrue(content.content.contains("[REDACTED]"))
    XCTAssertFalse(content.content.contains("abc123"))
    XCTAssertFalse(content.content.contains("private-value"))
    XCTAssertTrue(summary.contains("[REDACTED]"))
    XCTAssertFalse(summary.contains("abc123"))
  }

  func testPermissionEvidenceIsCaseInsensitiveAndBoundedToOutput() {
    XCTAssertTrue(
      AntigravityPermissionEvidence.detected(
        in: BoundedProcessOutput(
          head: "agy: permission denied while opening file",
          tail: "",
          byteCount: 42,
          truncated: false
        )
      )
    )
    XCTAssertTrue(
      AntigravityPermissionEvidence.detected(
        in: BoundedProcessOutput(
          head: "",
          tail: "The operation REQUIRES APPROVAL in headless mode",
          byteCount: 49,
          truncated: false
        )
      )
    )
    XCTAssertFalse(
      AntigravityPermissionEvidence.detected(
        in: BoundedProcessOutput(
          head: "completed successfully", tail: "", byteCount: 22, truncated: false)
      )
    )
  }

  func testRejectsWrongSessionAndInvalidStepState() async throws {
    let normalizer = try makeNormalizer()
    let wrongSession = try AntigravityCLITestSupport.decode(
      AntigravityStreamEnvelope.self,
      String(
        decoding: AntigravityCLITestSupport.stepUpdateFrame(
          conversationID: "other-conversation"
        ),
        as: UTF8.self
      )
    )
    do {
      _ = try await normalizer.normalize(try XCTUnwrap(wrongSession.stepUpdate))
      XCTFail("Expected a session mismatch")
    } catch {
      XCTAssertEqual(error as? AntigravityCLIError, .sessionMismatch)
    }

    let invalidState = try AntigravityCLITestSupport.decode(
      AntigravityStreamEnvelope.self,
      String(
        decoding: AntigravityCLITestSupport.stepUpdateFrame(state: "PAUSED"),
        as: UTF8.self
      )
    )
    do {
      _ = try await normalizer.normalize(try XCTUnwrap(invalidState.stepUpdate))
      XCTFail("Expected an invalid state rejection")
    } catch {
      XCTAssertEqual(error as? AntigravityCLIError, .invalidMessage)
    }
  }

  func testRejectsOversizedContentWithoutRetainingIt() async throws {
    let normalizer = try makeNormalizer()
    let oversized = String(repeating: "x", count: 256 * 1_024 + 1)
    let update = try AntigravityCLITestSupport.decode(
      AntigravityStreamEnvelope.self,
      """
      {"event":"step_update","step_update":{"conversation_id":"conversation-1","step_index":0,"state":"ACTIVE","step_type":"agent_response","tool_name":null,"text_delta":"\(oversized)","duration_seconds":null,"usage":null,"tool_info":null,"subagent_info":null}}
      """
    )
    do {
      _ = try await normalizer.normalize(try XCTUnwrap(update.stepUpdate))
      XCTFail("Expected oversized content to be rejected")
    } catch {
      XCTAssertEqual(error as? AntigravityCLIError, .oversizedFrame)
    }
  }

  private func makeNormalizer(projectRoot: String? = nil) throws -> AntigravityCLIEventNormalizer {
    let binding = try AgentBinding(
      providerID: .antigravity,
      installationID: AgentInstallationID(rawValue: "agy-test"),
      providerSessionID: "conversation-1",
      providerRunID: "run-1"
    )
    return AntigravityCLIEventNormalizer(
      taskID: TaskID(rawValue: "task-agy"),
      binding: binding,
      projectRoot: projectRoot ?? "/tmp/project"
    )
  }
}
