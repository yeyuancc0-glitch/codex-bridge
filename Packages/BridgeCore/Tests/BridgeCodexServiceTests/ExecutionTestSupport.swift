import BridgeCodexRPC
import BridgeCodexService
import BridgeDomain
import BridgeProjects
import BridgeServiceCore
import Foundation
import XCTest

struct ExecutionTestFixture {
  let root: URL
  let databasePath: String
  let store: SimpleServiceStore
  let projects: ServiceProjectService
  let tasks: ServiceTaskManager
  let project: ServiceProjectRecord
}

func makeExecutionFixture(
  _ testCase: XCTestCase,
  accessPolicy: ProjectAccessPolicy = ProjectAccessPolicy(
    read: .allowed,
    write: .allowed,
    network: .allowed
  )
) async throws -> ExecutionTestFixture {
  let root = FileManager.default.temporaryDirectory.appending(
    path: "bridge-codex-service-tests-\(UUID().uuidString)",
    directoryHint: .isDirectory
  )
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  let databasePath = root.appending(path: "service.sqlite").path
  testCase.addTeardownBlock { try? FileManager.default.removeItem(at: root) }
  let store = try SimpleServiceStore(path: databasePath)
  let projectID = ProjectID(rawValue: "prj-execution-fixture")
  let projects = ServiceProjectService(
    store: store,
    makeProjectID: { projectID }
  )
  let tasks = ServiceTaskManager(store: store)
  let project = try await projects.register(
    name: "Execution Fixture",
    rootURL: root,
    accessPolicy: accessPolicy,
    id: projectID
  )
  return ExecutionTestFixture(
    root: root,
    databasePath: databasePath,
    store: store,
    projects: projects,
    tasks: tasks,
    project: project
  )
}

func submitStartedExecutionTask(
  fixture: ExecutionTestFixture,
  taskID: String,
  threadID: String? = nil,
  model: String = "fixture-model",
  effort: String = "medium",
  supervisorModel: String? = nil,
  supervisorEffort: String? = nil,
  permissionMode: ServicePermissionMode = .workspaceWrite,
  accessMode: ServiceAccessMode = .requestApproval,
  fastMode: Bool = false
) async throws -> ServiceTaskRecord {
  let result = try await fixture.tasks.submit(
    ServiceTaskRequest(
      projectID: fixture.project.id,
      source: .chatGPT,
      clientRequestID: "request-\(taskID)",
      prompt: "Implement the requested change and report the result.",
      requestedThreadID: threadID,
      executionModel: model,
      executionEffort: effort,
      supervisorModel: supervisorModel,
      supervisorEffort: supervisorEffort,
      permissionMode: permissionMode,
      accessMode: accessMode,
      fastMode: fastMode
    ),
    taskID: TaskID(rawValue: taskID)
  )
  return try await fixture.tasks.begin(taskID: result.task.id)
}

func makeExecutionManager(
  script: String,
  maximumConcurrentSessions: Int = 4
) -> ExecutionManager {
  ExecutionManager(
    configuration: ExecutionManagerConfiguration(
      appServer: AppServerConfiguration(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", script]
      ),
      clientInfo: .bridge(version: "execution-tests"),
      requestTimeoutNanoseconds: 3_000_000_000,
      turnStartTimeoutNanoseconds: 3_000_000_000,
      maximumSessionNanoseconds: 10_000_000_000,
      maximumConcurrentSessions: maximumConcurrentSessions
    )
  )
}

func waitForTask(
  _ fixture: ExecutionTestFixture,
  taskID: TaskID,
  matching predicate: @escaping (ServiceTaskRecord) -> Bool,
  timeout: Duration = .seconds(6)
) async throws -> ServiceTaskRecord {
  let start = ContinuousClock.now
  while ContinuousClock.now - start < timeout {
    if let task = try await fixture.tasks.task(id: taskID), predicate(task) {
      return task
    }
    try await Task.sleep(for: .milliseconds(10))
  }
  throw ExecutionTestError.timedOut
}

func waitForApproval(
  _ coordinator: ServiceExecutionCoordinator,
  taskID: TaskID,
  timeout: Duration = .seconds(6)
) async throws -> ExecutionApprovalRequest {
  let start = ContinuousClock.now
  while ContinuousClock.now - start < timeout {
    if let request = await coordinator.pendingApprovals(taskID: taskID).first {
      return request
    }
    try await Task.sleep(for: .milliseconds(10))
  }
  throw ExecutionTestError.timedOut
}

enum ExecutionTestError: Error {
  case timedOut
}

func executionThreadJSON(id: String, root: String) -> String {
  """
  {"id":"\(id)","cwd":"\(root)","ephemeral":false,"modelProvider":"fixture","preview":"","turns":[],"name":null,"cliVersion":"fixture/1","createdAt":1,"updatedAt":1,"sessionId":"session-1","status":{"type":"idle"},"source":"appServer"}
  """
}

func executionTurnJSON(
  id: String,
  status: String,
  items: String = "[]"
) -> String {
  """
  {"id":"\(id)","status":"\(status)","error":null,"items":\(items),"itemsView":"full","startedAt":1,"completedAt":null,"durationMs":null}
  """
}

let executionStandardModelJSON =
  #"{"id":"fixture-model","model":"fixture-model","displayName":"Fixture","description":"fixture","hidden":false,"supportedReasoningEfforts":[{"reasoningEffort":"medium","description":"Medium"}],"defaultReasoningEffort":"medium","isDefault":true}"#

let executionFastModelJSON =
  #"{"id":"fixture-model","model":"fixture-model","displayName":"Fixture","description":"fixture","hidden":false,"supportedReasoningEfforts":[{"reasoningEffort":"medium","description":"Medium"}],"defaultReasoningEffort":"medium","isDefault":true,"additionalSpeedTiers":["fast"],"serviceTiers":[{"id":"priority","name":"Fast","description":"Fast"}],"defaultServiceTier":null}"#

func executionCommonHandshake(modelJSON: String = executionStandardModelJSON) -> String {
  #"""
  IFS= read -r initialize
  case "$initialize" in *'"method":"initialize"'*) ;; *) exit 11 ;; esac
  printf '%s\n' '{"id":1,"result":{"userAgent":"fixture/1","codexHome":"/private/fixture","platformFamily":"unix","platformOs":"macos"}}'
  IFS= read -r initialized
  case "$initialized" in *'"method":"initialized"'*) ;; *) exit 12 ;; esac
  IFS= read -r models
  case "$models" in *'"method":"model/list"'*) ;; *) exit 13 ;; esac
  printf '%s\n' '{"id":2,"result":{"data":[__MODEL__],"nextCursor":null}}'
  """#
  .replacingOccurrences(of: "__MODEL__", with: modelJSON)
}

func newThreadProgressScript(root: String) -> String {
  let thread = executionThreadJSON(id: "thread-progress", root: root)
  let turn = executionTurnJSON(id: "turn-progress", status: "inProgress")
  let finalItems = #"[{"type":"agentMessage","text":"Implemented the change and verified it."}]"#
  let completed = executionTurnJSON(
    id: "turn-progress",
    status: "completed",
    items: finalItems
  )
  return executionCommonHandshake()
    + "\n"
      + #"""
      IFS= read -r thread_start
      case "$thread_start" in *'"method":"thread/start"'*) ;; *) exit 21 ;; esac
      case "$thread_start" in *'"cwd":"__ROOT__"'*) ;; *) exit 21 ;; esac
      printf '%s\n' '{"id":3,"result":{"thread":__THREAD__,"model":"fixture-model","modelProvider":"fixture","reasoningEffort":"medium","cwd":"__ROOT__","sandbox":{"type":"workspaceWrite","networkAccess":false,"writableRoots":["__ROOT__"],"excludeSlashTmp":false,"excludeTmpdirEnvVar":false},"approvalPolicy":"on-request","approvalsReviewer":"user","serviceTier":null}}'
      IFS= read -r turn_start
      case "$turn_start" in *'"method":"turn/start"'*) ;; *) exit 22 ;; esac
      printf '%s\n' '{"method":"turn/started","params":{"threadId":"thread-progress","turn":__TURN__}}'
      printf '%s\n' '{"id":4,"result":{"turn":__TURN__}}'
      printf '%s\n' '{"method":"turn/plan/updated","params":{"threadId":"thread-progress","turnId":"turn-progress","explanation":"password=secret","plan":[{"step":"Edit Sources/App.swift","status":"inProgress"}]}}'
      printf '%s\n' '{"method":"item/started","params":{"threadId":"thread-progress","turnId":"turn-progress","startedAtMs":2,"item":{"id":"item-command","type":"commandExecution","command":"swift test","commandActions":[],"cwd":"__ROOT__","status":"inProgress"}}}'
      printf '%s\n' '{"method":"item/completed","params":{"threadId":"thread-progress","turnId":"turn-progress","completedAtMs":3,"item":{"id":"item-command","type":"commandExecution","command":"swift test","commandActions":[],"cwd":"__ROOT__","status":"completed","exitCode":0,"aggregatedOutput":"ignored"}}}'
      printf '%s\n' '{"method":"item/started","params":{"threadId":"thread-progress","turnId":"turn-progress","startedAtMs":4,"item":{"id":"item-file","type":"fileChange","status":"inProgress","changes":[{"path":"Sources/App.swift","diff":"ignored","kind":{"type":"update","move_path":null}}]}}}'
      printf '%s\n' '{"method":"item/completed","params":{"threadId":"thread-progress","turnId":"turn-progress","completedAtMs":5,"item":{"id":"item-file","type":"fileChange","status":"completed","changes":[{"path":"Sources/App.swift","diff":"ignored","kind":{"type":"update","move_path":null}}]}}}'
      printf '%s\n' '{"method":"turn/completed","params":{"threadId":"thread-progress","turn":__COMPLETED__}}'
      sleep 1
      """#
    .replacingOccurrences(of: "__ROOT__", with: root)
    .replacingOccurrences(of: "__THREAD__", with: thread)
    .replacingOccurrences(of: "__TURN__", with: turn)
    .replacingOccurrences(of: "__COMPLETED__", with: completed)
}

func postureExecutionScript(
  root: String,
  threadStartChecks: [String],
  turnStartChecks: [String] = [],
  sandboxJSON: String,
  approvalPolicy: String,
  approvalsReviewer: String,
  modelJSON: String = executionStandardModelJSON
) -> String {
  let thread = executionThreadJSON(id: "thread-posture", root: root)
  let turn = executionTurnJSON(id: "turn-posture", status: "inProgress")
  let completed = executionTurnJSON(
    id: "turn-posture",
    status: "completed",
    items: #"[{"type":"agentMessage","text":"The task completed under the configured posture."}]"#
  )
  let threadChecks = threadStartChecks.enumerated().map { index, check in
    "case \"$thread_start\" in *'\(check)'*) ;; *) exit \(21 + index) ;; esac"
  }.joined(separator: "\n")
  let turnChecks = turnStartChecks.enumerated().map { index, check in
    "case \"$turn_start\" in *'\(check)'*) ;; *) exit \(31 + index) ;; esac"
  }.joined(separator: "\n")
  let body = """
    IFS= read -r thread_start
    case "$thread_start" in *'"method":"thread/start"'*) ;; *) exit 20 ;; esac
    \(threadChecks)
    printf '%s\n' '{"id":3,"result":{"thread":__THREAD__,"model":"fixture-model","modelProvider":"fixture","reasoningEffort":"medium","cwd":"__ROOT__","sandbox":__SANDBOX__,"approvalPolicy":"__APPROVAL__","approvalsReviewer":"__REVIEWER__","serviceTier":null}}'
    IFS= read -r turn_start
    case "$turn_start" in *'"method":"turn/start"'*) ;; *) exit 30 ;; esac
    \(turnChecks)
    printf '%s\n' '{"method":"turn/started","params":{"threadId":"thread-posture","turn":__TURN__}}'
    printf '%s\n' '{"id":4,"result":{"turn":__TURN__}}'
    printf '%s\n' '{"method":"turn/completed","params":{"threadId":"thread-posture","turn":__COMPLETED__}}'
    sleep 1
    """
    .replacingOccurrences(of: "__ROOT__", with: root)
    .replacingOccurrences(of: "__THREAD__", with: thread)
    .replacingOccurrences(of: "__TURN__", with: turn)
    .replacingOccurrences(of: "__COMPLETED__", with: completed)
    .replacingOccurrences(of: "__SANDBOX__", with: sandboxJSON)
    .replacingOccurrences(of: "__APPROVAL__", with: approvalPolicy)
    .replacingOccurrences(of: "__REVIEWER__", with: approvalsReviewer)
  return executionCommonHandshake(modelJSON: modelJSON) + "\n" + body
}

func commandApprovalScript(root: String, expectedDecision: String, finalMessage: String) -> String {
  let thread = executionThreadJSON(id: "thread-approval", root: root)
  let turn = executionTurnJSON(id: "turn-approval", status: "inProgress")
  let completed = executionTurnJSON(
    id: "turn-approval",
    status: "completed",
    items: "[{\"type\":\"agentMessage\",\"text\":\"\(finalMessage)\"}]"
  )
  return executionCommonHandshake()
    + "\n"
      + #"""
      IFS= read -r thread_start
      printf '%s\n' '{"id":3,"result":{"thread":__THREAD__,"model":"fixture-model","modelProvider":"fixture","reasoningEffort":"medium","cwd":"__ROOT__","sandbox":{"type":"workspaceWrite","networkAccess":false,"writableRoots":["__ROOT__"],"excludeSlashTmp":false,"excludeTmpdirEnvVar":false},"approvalPolicy":"on-request","approvalsReviewer":"user","serviceTier":null}}'
      IFS= read -r turn_start
      printf '%s\n' '{"method":"turn/started","params":{"threadId":"thread-approval","turn":__TURN__}}'
      printf '%s\n' '{"id":4,"result":{"turn":__TURN__}}'
      printf '%s\n' '{"method":"item/started","params":{"threadId":"thread-approval","turnId":"turn-approval","startedAtMs":1,"item":{"id":"item-command","type":"commandExecution","command":"/usr/bin/git status","commandActions":[],"cwd":"__ROOT__","status":"inProgress"}}}'
      printf '%s\n' '{"id":"approval-command","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-approval","turnId":"turn-approval","itemId":"item-command","startedAtMs":1,"command":"/usr/bin/git status","cwd":"__ROOT__","reason":"Inspect the working tree."}}'
      IFS= read -r approval
      case "$approval" in *'"id":"approval-command"'*) ;; *) exit 31 ;; esac
      case "$approval" in *'"decision":"__DECISION__"'*) ;; *) exit 32 ;; esac
      printf '%s\n' '{"method":"turn/completed","params":{"threadId":"thread-approval","turn":__COMPLETED__}}'
      sleep 1
      """#
    .replacingOccurrences(of: "__ROOT__", with: root)
    .replacingOccurrences(of: "__THREAD__", with: thread)
    .replacingOccurrences(of: "__TURN__", with: turn)
    .replacingOccurrences(of: "__COMPLETED__", with: completed)
    .replacingOccurrences(of: "__DECISION__", with: expectedDecision)
}

func resumeSteerInterruptExecutionScript(root: String) -> String {
  let thread = executionThreadJSON(id: "thread-existing", root: root)
  let turn = executionTurnJSON(id: "turn-existing", status: "inProgress")
  let interrupted = executionTurnJSON(id: "turn-existing", status: "interrupted")
  return executionCommonHandshake()
    + "\n"
      + #"""
      IFS= read -r thread_read
      case "$thread_read" in *'"method":"thread/read"'*) ;; *) exit 41 ;; esac
      printf '%s\n' '{"id":3,"result":{"thread":__THREAD__}}'
      IFS= read -r thread_resume
      case "$thread_resume" in *'"method":"thread/resume"'*) ;; *) exit 42 ;; esac
      printf '%s\n' '{"id":4,"result":{"thread":__THREAD__,"model":"fixture-model","modelProvider":"fixture","reasoningEffort":"medium","cwd":"__ROOT__","sandbox":{"type":"workspaceWrite","networkAccess":false,"writableRoots":["__ROOT__"],"excludeSlashTmp":false,"excludeTmpdirEnvVar":false},"approvalPolicy":"on-request","approvalsReviewer":"user","serviceTier":null}}'
      IFS= read -r turn_start
      printf '%s\n' '{"method":"turn/started","params":{"threadId":"thread-existing","turn":__TURN__}}'
      printf '%s\n' '{"id":5,"result":{"turn":__TURN__}}'
      IFS= read -r steer
      case "$steer" in *'"method":"turn/steer"'*) ;; *) exit 43 ;; esac
      case "$steer" in *'"expectedTurnId":"turn-existing"'*) ;; *) exit 43 ;; esac
      printf '%s\n' '{"id":6,"result":{"turnId":"turn-existing"}}'
      IFS= read -r interrupt
      case "$interrupt" in *'"method":"turn/interrupt"'*) ;; *) exit 44 ;; esac
      case "$interrupt" in *'"turnId":"turn-existing"'*) ;; *) exit 44 ;; esac
      printf '%s\n' '{"id":7,"result":{}}'
      printf '%s\n' '{"method":"turn/completed","params":{"threadId":"thread-existing","turn":__INTERRUPTED__}}'
      sleep 1
      """#
    .replacingOccurrences(of: "__ROOT__", with: root)
    .replacingOccurrences(of: "__THREAD__", with: thread)
    .replacingOccurrences(of: "__TURN__", with: turn)
    .replacingOccurrences(of: "__INTERRUPTED__", with: interrupted)
}

func unavailableModelScript() -> String {
  #"""
  IFS= read -r initialize
  printf '%s\n' '{"id":1,"result":{"userAgent":"fixture/1","codexHome":"/private/fixture","platformFamily":"unix","platformOs":"macos"}}'
  IFS= read -r initialized
  IFS= read -r models
  printf '%s\n' '{"id":2,"result":{"data":[],"nextCursor":null}}'
  sleep 1
  """#
}
