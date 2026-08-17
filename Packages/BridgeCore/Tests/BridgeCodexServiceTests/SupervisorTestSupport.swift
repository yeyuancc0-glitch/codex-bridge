import BridgeCodexRPC
import BridgeCodexService
import BridgeDomain
import BridgeServiceCore
import Foundation
import XCTest

func makeSupervisorManager(
  fixture: ExecutionTestFixture,
  script: String,
  maximumAutomaticSteers: Int = 3,
  reviewTimeoutNanoseconds: UInt64 = 5_000_000_000
) throws -> SupervisorManager {
  let scratch = fixture.root.appending(
    path: "supervisor-scratch-" + UUID().uuidString.lowercased(),
    directoryHint: .isDirectory
  )
  try FileManager.default.createDirectory(
    at: scratch,
    withIntermediateDirectories: false,
    attributes: [.posixPermissions: NSNumber(value: 0o700)]
  )
  try FileManager.default.setAttributes(
    [.posixPermissions: NSNumber(value: 0o700)],
    ofItemAtPath: scratch.path
  )
  return SupervisorManager(
    configuration: SupervisorManagerConfiguration(
      appServer: AppServerConfiguration(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", script]
      ),
      clientInfo: .bridge(version: "supervisor-service-tests"),
      scratchRootURL: scratch,
      requestTimeoutNanoseconds: 5_000_000_000,
      reviewTimeoutNanoseconds: reviewTimeoutNanoseconds,
      maximumAutomaticSteers: maximumAutomaticSteers
    )
  )
}

func supervisorDecisionJSON(
  decision: String,
  summary: String,
  instruction: String? = nil,
  issueID: String? = nil
) -> String {
  testJSONString([
    "decision": decision,
    "risk": "low",
    "summary": summary,
    "evidence": ["The bounded observation was reviewed."],
    "instruction": instruction.map { $0 as Any } ?? NSNull(),
    "required_checks": [],
    "scope_violation": false,
    "confidence": 0.93,
    "issue_id": issueID.map { $0 as Any } ?? NSNull(),
  ])
}

func supervisorTurnJSON(id: String, decision: String) -> String {
  testJSONString([
    "id": id,
    "status": "completed",
    "error": NSNull(),
    "items": [
      [
        "id": "message-\(id)",
        "type": "agentMessage",
        "text": decision,
      ]
    ],
    "itemsView": "full",
    "startedAt": 1,
    "completedAt": 2,
    "durationMs": 1,
  ])
}

private func testJSONString(_ object: Any) -> String {
  guard JSONSerialization.isValidJSONObject(object),
    let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
    let text = String(data: data, encoding: .utf8)
  else {
    preconditionFailure("The test JSON fixture must be encodable.")
  }
  return text
}

func supervisorScript(
  decisions: [String],
  firstReviewDelay: Double = 0,
  requestApproval: Bool = false
) -> String {
  var reviews = ""
  for (index, decision) in decisions.enumerated() {
    let requestID = index + 4
    let turnID = "supervisor-turn-\(index + 1)"
    let turn = supervisorTurnJSON(id: turnID, decision: decision)
    let delay: String
    if index == 0, firstReviewDelay > 0 {
      delay = "sleep \(firstReviewDelay)\n"
    } else {
      delay = ""
    }
    let approval: String
    if index == 0, requestApproval {
      approval = #"""
        printf '%s\n' '{"id":"supervisor-approval","method":"item/commandExecution/requestApproval","params":{"threadId":"supervisor-thread","turnId":"supervisor-turn-1","itemId":"item-1","command":"cat secret","cwd":"/private","reason":"unsafe"}}'
        IFS= read -r rejected
        case "$rejected" in *'"id":"supervisor-approval"'*) ;; *) exit 70 ;; esac
        """#
    } else {
      approval = ""
    }
    reviews += """
      IFS= read -r review_\(index)
      case "$review_\(index)" in *'"method":"turn/start"'*) ;; *) exit \(50 + index) ;; esac
      case "$review_\(index)" in *'"approvalPolicy":"never"'*) ;; *) exit \(60 + index) ;; esac
      \(approval)
      \(delay)printf '%s\n' '{"id":\(requestID),"result":{"turn":\(turn)}}'
      printf '%s\n' '{"method":"turn/completed","params":{"threadId":"supervisor-thread","turn":\(turn)}}'

      """
  }
  return #"""
    IFS= read -r initialize
    printf '%s\n' '{"id":1,"result":{"userAgent":"fixture/1","codexHome":"/private/fixture","platformFamily":"unix","platformOs":"macos"}}'
    IFS= read -r initialized
    IFS= read -r models
    printf '%s\n' '{"id":2,"result":{"data":[{"id":"supervisor-model","model":"supervisor-model","displayName":"Supervisor","description":"Supervisor","hidden":false,"supportedReasoningEfforts":[{"reasoningEffort":"medium","description":"Medium"}],"defaultReasoningEffort":"medium","isDefault":false}],"nextCursor":null}}'
    IFS= read -r thread_start
    case "$thread_start" in *'"method":"thread/start"'*) ;; *) exit 31 ;; esac
    case "$thread_start" in *'"sandbox":"read-only"'*) ;; *) exit 32 ;; esac
    case "$thread_start" in *'"approvalPolicy":"never"'*) ;; *) exit 33 ;; esac
    cwd=$(printf '%s' "$thread_start" | sed -n 's/.*"cwd":"\([^"]*\)".*/\1/p')
    test -n "$cwd" || exit 34
    printf '%s\n' "{\"id\":3,\"result\":{\"thread\":{\"id\":\"supervisor-thread\",\"cwd\":\"$cwd\",\"ephemeral\":false,\"modelProvider\":\"fixture\",\"preview\":\"\",\"turns\":[],\"name\":null,\"cliVersion\":\"fixture/1\",\"createdAt\":1,\"updatedAt\":1,\"sessionId\":\"session-supervisor\",\"status\":{\"type\":\"idle\"},\"source\":\"appServer\"},\"model\":\"supervisor-model\",\"modelProvider\":\"fixture\",\"reasoningEffort\":\"medium\",\"cwd\":\"$cwd\",\"sandbox\":{\"type\":\"readOnly\",\"networkAccess\":false},\"approvalPolicy\":\"never\",\"approvalsReviewer\":\"user\",\"serviceTier\":null}}"
    __REVIEWS__
    sleep 2
    """#
    .replacingOccurrences(of: "__REVIEWS__", with: reviews)
}

var unavailableSupervisorModelScript: String {
  #"""
  IFS= read -r initialize
  printf '%s\n' '{"id":1,"result":{"userAgent":"fixture/1","codexHome":"/private/fixture","platformFamily":"unix","platformOs":"macos"}}'
  IFS= read -r initialized
  IFS= read -r models
  printf '%s\n' '{"id":2,"result":{"data":[],"nextCursor":null}}'
  sleep 2
  """#
}

func executionWaitForSupervisorSteerScript(root: String) -> String {
  let thread = executionThreadJSON(id: "thread-supervised", root: root)
  let turn = executionTurnJSON(id: "turn-supervised", status: "inProgress")
  let completed = executionTurnJSON(
    id: "turn-supervised",
    status: "completed",
    items: #"[{"type":"agentMessage","text":"Completed after Supervisor steer."}]"#
  )
  return executionCommonHandshake
    + "\n"
      + #"""
      IFS= read -r thread_start
      printf '%s\n' '{"id":3,"result":{"thread":__THREAD__,"model":"fixture-model","modelProvider":"fixture","reasoningEffort":"medium","cwd":"__ROOT__","sandbox":{"type":"workspaceWrite","networkAccess":false,"writableRoots":["__ROOT__"],"excludeSlashTmp":false,"excludeTmpdirEnvVar":false},"approvalPolicy":"on-request","approvalsReviewer":"user","serviceTier":null}}'
      IFS= read -r turn_start
      printf '%s\n' '{"method":"turn/started","params":{"threadId":"thread-supervised","turn":__TURN__}}'
      printf '%s\n' '{"id":4,"result":{"turn":__TURN__}}'
      printf '%s\n' '{"method":"turn/plan/updated","params":{"threadId":"thread-supervised","turnId":"turn-supervised","explanation":"Initial plan","plan":[{"step":"Implement broad changes","status":"inProgress"}]}}'
      IFS= read -r steer
      case "$steer" in *'"method":"turn/steer"'*) ;; *) exit 81 ;; esac
      case "$steer" in *'"expectedTurnId":"turn-supervised"'*) ;; *) exit 82 ;; esac
      case "$steer" in *'Keep the change scoped'*) ;; *) exit 83 ;; esac
      printf '%s\n' '{"id":5,"result":{"turnId":"turn-supervised"}}'
      printf '%s\n' '{"method":"turn/completed","params":{"threadId":"thread-supervised","turn":__COMPLETED__}}'
      sleep 1
      """#
    .replacingOccurrences(of: "__ROOT__", with: root)
    .replacingOccurrences(of: "__THREAD__", with: thread)
    .replacingOccurrences(of: "__TURN__", with: turn)
    .replacingOccurrences(of: "__COMPLETED__", with: completed)
}

func collectSupervisorEvents(
  _ stream: AsyncStream<SupervisorEvent>,
  count: Int,
  timeout: Duration = .seconds(6)
) async throws -> [SupervisorEvent] {
  try await withThrowingTaskGroup(of: [SupervisorEvent].self) { group in
    group.addTask {
      var result: [SupervisorEvent] = []
      for await event in stream {
        result.append(event)
        if result.count >= count { return result }
      }
      return result
    }
    group.addTask {
      try await Task.sleep(for: timeout)
      throw ExecutionTestError.timedOut
    }
    let result = try await group.next() ?? []
    group.cancelAll()
    return result
  }
}
