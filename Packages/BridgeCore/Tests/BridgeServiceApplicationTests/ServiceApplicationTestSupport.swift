import BridgeCodexRPC
import BridgeCodexService
import BridgeDomain
import BridgeMCP
import BridgeProjects
import BridgeServiceApplication
import BridgeServiceCore
import Foundation
import XCTest

struct ServiceApplicationFixture {
  let root: URL
  let store: SimpleServiceStore
  let projects: ServiceProjectService
  let tasks: ServiceTaskManager
  let settings: ServiceSettings
  let coordinator: ServiceExecutionCoordinator
  let runtimeStatus: ServiceRuntimeStatus
  let project: ServiceProjectRecord
}

func makeServiceApplicationFixture(_ testCase: XCTestCase) async throws
  -> ServiceApplicationFixture
{
  let root = FileManager.default.temporaryDirectory.appending(
    path: "bridge-service-application-tests-\(UUID().uuidString)",
    directoryHint: .isDirectory
  )
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  testCase.addTeardownBlock { try? FileManager.default.removeItem(at: root) }
  let store = try SimpleServiceStore(path: root.appending(path: "service.sqlite").path)
  let projects = ServiceProjectService(
    store: store,
    makeProjectID: { ProjectID(rawValue: "prj-service-app") }
  )
  let tasks = ServiceTaskManager(
    store: store,
    makeTaskID: { TaskID(rawValue: "tsk-service-app") }
  )
  let settings = ServiceSettings(store: store)
  let execution = ExecutionManager(
    configuration: ExecutionManagerConfiguration(
      appServer: AppServerConfiguration(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", serviceExecutionStartScript(root: root.path)]
      ),
      clientInfo: .bridge(version: "service-app-tests")
    )
  )
  let coordinator = ServiceExecutionCoordinator(
    tasks: tasks,
    projects: projects,
    execution: execution
  )
  testCase.addTeardownBlock { await coordinator.shutdown() }
  let runtimeStatus = ServiceRuntimeStatus(
    initial: ServiceRuntimeStatusSnapshot(
      mcpState: "ready",
      tunnelState: "stopped",
      codexVersion: "fixture",
      loginMode: "chatgpt"
    )
  )
  let project = try await projects.register(
    name: "Service Project",
    rootURL: root,
    accessPolicy: ProjectAccessPolicy(
      read: .allowed,
      write: .requiresLocalApproval,
      network: .denied
    ),
    id: ProjectID(rawValue: "prj-service-app")
  )
  return ServiceApplicationFixture(
    root: root,
    store: store,
    projects: projects,
    tasks: tasks,
    settings: settings,
    coordinator: coordinator,
    runtimeStatus: runtimeStatus,
    project: project
  )
}

func makeServiceApplication(
  fixture: ServiceApplicationFixture,
  catalogScript: String,
  agentRegistry: ServiceAgentRegistry? = nil,
  agentRunner: (any AgentTaskRunning)? = nil
) -> BridgeServiceApplication {
  let execution = ExecutionManager(
    configuration: ExecutionManagerConfiguration(
      appServer: AppServerConfiguration(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", serviceExecutionStartScript(root: fixture.root.path)]
      ),
      clientInfo: .bridge(version: "service-app-tests")
    )
  )
  let coordinator = ServiceExecutionCoordinator(
    tasks: fixture.tasks,
    projects: fixture.projects,
    execution: execution,
    agentRunner: agentRunner
  )
  return BridgeServiceApplication(
    appVersion: "0.2.0",
    projects: fixture.projects,
    tasks: fixture.tasks,
    settings: fixture.settings,
    coordinator: coordinator,
    catalog: ServiceCodexCatalog(
      configuration: ServiceCodexCatalogConfiguration(
        appServer: AppServerConfiguration(
          executableURL: URL(fileURLWithPath: "/bin/sh"),
          arguments: ["-c", catalogScript]
        ),
        clientInfo: .bridge(version: "service-app-tests"),
        requestTimeoutNanoseconds: 2_000_000_000
      )
    ),
    runtimeStatus: fixture.runtimeStatus,
    agentRegistry: agentRegistry
  )
}

@discardableResult
func assertAgentSkillInjectedIntoProviderPrompt(
  application: BridgeServiceApplication,
  fixture: ServiceApplicationFixture,
  submission: MCPServiceTaskSubmission,
  expectedPrompt: String,
  deadline: ContinuousClock.Instant,
  providerPrompt: @Sendable @escaping () -> String?
) async throws -> TaskID {
  let receipt = try await application.serviceSubmitTask(submission, deadline: deadline)
  let taskID = TaskID(rawValue: receipt.taskID)
  try await application.resolveTaskStartApproval(
    taskID: taskID,
    approvalID: BridgeServiceApplication.PendingTaskStartApproval.approvalID(for: taskID),
    approved: true,
    deadline: deadline
  )
  let task = try await fixture.tasks.task(id: taskID)
  XCTAssertEqual(task?.state.status, .running)
  XCTAssertEqual(providerPrompt(), expectedPrompt)
  return taskID
}

var serviceModelCatalogScript: String {
  #"""
  IFS= read -r initialize
  printf '%s\n' '{"id":1,"result":{"userAgent":"fixture/1","codexHome":"/private/fixture","platformFamily":"unix","platformOs":"macos"}}'
  IFS= read -r initialized
  IFS= read -r request
  case "$request" in *'"method":"model/list"'*) ;; *) exit 11 ;; esac
  printf '%s\n' '{"id":2,"result":{"data":[{"id":"execution-model","model":"execution-model","displayName":"Execution","description":"Execution","hidden":false,"supportedReasoningEfforts":[{"reasoningEffort":"high","description":"High"}],"defaultReasoningEffort":"high","isDefault":true},{"id":"gpt-5.6-luna","model":"gpt-5.6-luna","displayName":"Luna","description":"Supervisor","hidden":false,"supportedReasoningEfforts":[{"reasoningEffort":"medium","description":"Medium"}],"defaultReasoningEffort":"medium","isDefault":false}],"nextCursor":null}}'
  sleep 1
  """#
}

func serviceCountingModelCatalogScript(spawnLog: String) -> String {
  #"""
  printf 'spawn\n' >> "\#(spawnLog)"
  IFS= read -r initialize
  printf '%s\n' '{"id":1,"result":{"userAgent":"fixture/1","codexHome":"/private/fixture","platformFamily":"unix","platformOs":"macos"}}'
  IFS= read -r initialized
  IFS= read -r request
  case "$request" in *'"method":"model/list"'*) ;; *) exit 11 ;; esac
  printf '%s\n' '{"id":2,"result":{"data":[{"id":"execution-model","model":"execution-model","displayName":"Execution","description":"Execution","hidden":false,"supportedReasoningEfforts":[{"reasoningEffort":"high","description":"High"}],"defaultReasoningEffort":"high","isDefault":true},{"id":"gpt-5.6-luna","model":"gpt-5.6-luna","displayName":"Luna","description":"Supervisor","hidden":false,"supportedReasoningEfforts":[{"reasoningEffort":"medium","description":"Medium"}],"defaultReasoningEffort":"medium","isDefault":false}],"nextCursor":null}}'
  sleep 1
  """#
}

var serviceFastModelCatalogScript: String {
  #"""
  IFS= read -r initialize
  printf '%s\n' '{"id":1,"result":{"userAgent":"fixture/1","codexHome":"/private/fixture","platformFamily":"unix","platformOs":"macos"}}'
  IFS= read -r initialized
  IFS= read -r request
  case "$request" in *'"method":"model/list"'*) ;; *) exit 11 ;; esac
  printf '%s\n' '{"id":2,"result":{"data":[{"id":"execution-model","model":"execution-model","displayName":"Execution","description":"Execution","hidden":false,"supportedReasoningEfforts":[{"reasoningEffort":"high","description":"High"}],"defaultReasoningEffort":"high","isDefault":true,"additionalSpeedTiers":["fast"],"serviceTiers":[{"id":"priority","name":"Fast","description":"Fast"}],"defaultServiceTier":null},{"id":"gpt-5.6-luna","model":"gpt-5.6-luna","displayName":"Luna","description":"Supervisor","hidden":false,"supportedReasoningEfforts":[{"reasoningEffort":"medium","description":"Medium"}],"defaultReasoningEffort":"medium","isDefault":false}],"nextCursor":null}}'
  sleep 1
  """#
}

func serviceThreadListScript(root: String) -> String {
  let matching = serviceThreadJSON(id: "thread-matching", root: root, name: "Matching")
  return serviceCatalogHandshake
    + "\n"
      + #"""
      IFS= read -r request
      case "$request" in *'"method":"thread/list"'*) ;; *) exit 21 ;; esac
      case "$request" in *'"cwd":["__ROOT__"]'*) ;; *) exit 22 ;; esac
      printf '%s\n' '{"id":2,"result":{"data":[__MATCHING__],"nextCursor":null}}'
      sleep 1
      """#
    .replacingOccurrences(of: "__ROOT__", with: root)
    .replacingOccurrences(of: "__MATCHING__", with: matching)
}

func serviceMixedThreadListScript(root: String) -> String {
  let bridge = serviceThreadJSON(id: "thread-bridge", root: root, name: "Bridge")
  let qwen = serviceThreadJSON(id: "thread-qwen", root: root, name: "Qwen")
  let manual = serviceThreadJSON(id: "thread-manual", root: root, name: "Manual")
  return serviceCatalogHandshake
    + "\n"
      + #"""
      IFS= read -r request
      case "$request" in *'"method":"thread/list"'*) ;; *) exit 23 ;; esac
      printf '%s\n' '{"id":2,"result":{"data":[__MANUAL__,__QWEN__,__BRIDGE__],"nextCursor":null}}'
      sleep 1
      """#
    .replacingOccurrences(of: "__MANUAL__", with: manual)
    .replacingOccurrences(of: "__QWEN__", with: qwen)
    .replacingOccurrences(of: "__BRIDGE__", with: bridge)
}

func serviceThreadReadScript(root: String, returnedRoot: String? = nil) -> String {
  let thread = serviceThreadJSON(
    id: "thread-read",
    root: returnedRoot ?? root,
    name: "Read Thread",
    turns: [
      serviceTurnJSON(
        id: "turn-1",
        items: [
          ["type": "userMessage", "text": "Please inspect the project."],
          ["type": "agentMessage", "text": "The project was inspected."],
        ]
      )
    ]
  )
  return serviceCatalogHandshake
    + "\n"
      + #"""
      IFS= read -r request
      case "$request" in *'"method":"thread/read"'*) ;; *) exit 31 ;; esac
      printf '%s\n' '{"id":2,"result":{"thread":__THREAD__}}'
      sleep 1
      """#
    .replacingOccurrences(of: "__THREAD__", with: thread)
}

func serviceThreadReadFailureScript(message: String) -> String {
  serviceCatalogHandshake
    + "\n"
      + #"""
      IFS= read -r request
      case "$request" in *'"method":"thread/read"'*) ;; *) exit 32 ;; esac
      printf '%s\n' '{"id":2,"error":{"code":-32600,"message":"__MESSAGE__"}}'
      sleep 1
      """#
    .replacingOccurrences(of: "__MESSAGE__", with: message)
}

func serviceExecutionStartScript(root: String) -> String {
  let thread = serviceThreadJSON(id: "thread-execution", root: root, name: "Execution")
  let turn = serviceExecutionTurnJSON(id: "turn-execution")
  return #"""
    IFS= read -r initialize
    case "$initialize" in *'"method":"initialize"'*) ;; *) exit 41 ;; esac
    printf '%s\n' '{"id":1,"result":{"userAgent":"fixture/1","codexHome":"/private/fixture","platformFamily":"unix","platformOs":"macos"}}'
    IFS= read -r initialized
    case "$initialized" in *'"method":"initialized"'*) ;; *) exit 42 ;; esac
    IFS= read -r models
    case "$models" in *'"method":"model/list"'*) ;; *) exit 43 ;; esac
    printf '%s\n' '{"id":2,"result":{"data":[{"id":"execution-model","model":"execution-model","displayName":"Execution","description":"Execution","hidden":false,"supportedReasoningEfforts":[{"reasoningEffort":"high","description":"High"}],"defaultReasoningEffort":"high","isDefault":true,"additionalSpeedTiers":["fast"],"serviceTiers":[{"id":"priority","name":"Fast","description":"Fast"}],"defaultServiceTier":null},{"id":"gpt-5.6-luna","model":"gpt-5.6-luna","displayName":"Luna","description":"Supervisor","hidden":false,"supportedReasoningEfforts":[{"reasoningEffort":"medium","description":"Medium"}],"defaultReasoningEffort":"medium","isDefault":false}],"nextCursor":null}}'
    IFS= read -r thread_start
    case "$thread_start" in *'"method":"thread/start"'*) ;; *) exit 44 ;; esac
    case "$thread_start" in *'"cwd":"__ROOT__"'*) ;; *) exit 44 ;; esac
    model=$(printf '%s\n' "$thread_start" | sed -n 's/.*"model":"\([^"]*\)".*/\1/p')
    reviewer=$(printf '%s\n' "$thread_start" | sed -n 's/.*"approvalsReviewer":"\([^"]*\)".*/\1/p')
    tier=$(printf '%s\n' "$thread_start" | sed -n 's/.*"serviceTier":"\([^"]*\)".*/\1/p')
    [ -n "$tier" ] || tier=null
    printf '%s\n' '{"id":3,"result":{"thread":__THREAD__,"model":"'"$model"'","modelProvider":"fixture","reasoningEffort":"high","cwd":"__ROOT__","sandbox":{"type":"workspaceWrite","networkAccess":false,"writableRoots":["__ROOT__"],"excludeSlashTmp":false,"excludeTmpdirEnvVar":false},"approvalPolicy":"on-request","approvalsReviewer":"'"$reviewer"'","serviceTier":"'"$tier"'"}}'
    IFS= read -r turn_start
    case "$turn_start" in *'"method":"turn/start"'*) ;; *) exit 45 ;; esac
    printf '%s\n' '{"method":"turn/started","params":{"threadId":"thread-execution","turn":__TURN__}}'
    printf '%s\n' '{"id":4,"result":{"turn":__TURN__}}'
    sleep 30
    """#
    .replacingOccurrences(of: "__ROOT__", with: root)
    .replacingOccurrences(of: "__THREAD__", with: thread)
    .replacingOccurrences(of: "__TURN__", with: turn)
}

func serviceExecutionTurnJSON(id: String) -> String {
  serviceTestJSON([
    "id": id,
    "status": "inProgress",
    "error": NSNull(),
    "items": [],
    "itemsView": "full",
    "startedAt": 1,
    "completedAt": NSNull(),
    "durationMs": NSNull(),
  ])
}

var serviceCatalogHandshake: String {
  #"""
  IFS= read -r initialize
  printf '%s\n' '{"id":1,"result":{"userAgent":"fixture/1","codexHome":"/private/fixture","platformFamily":"unix","platformOs":"macos"}}'
  IFS= read -r initialized
  """#
}

func serviceThreadJSON(
  id: String,
  root: String,
  name: String,
  turns: [[String: Any]] = []
) -> String {
  serviceTestJSON([
    "id": id,
    "cwd": root,
    "ephemeral": false,
    "modelProvider": "fixture",
    "preview": "Thread preview",
    "turns": turns,
    "name": name,
    "cliVersion": "fixture/1",
    "createdAt": 1,
    "updatedAt": 1,
    "sessionId": "session-1",
    "status": ["type": "idle"],
    "source": "appServer",
  ])
}

func serviceTurnJSON(id: String, items: [[String: Any]]) -> [String: Any] {
  [
    "id": id,
    "status": "completed",
    "error": NSNull(),
    "items": items,
    "itemsView": "full",
    "startedAt": 1,
    "completedAt": 2,
    "durationMs": 1,
  ]
}

func serviceTestJSON(_ object: Any) -> String {
  guard JSONSerialization.isValidJSONObject(object),
    let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
    let text = String(data: data, encoding: .utf8)
  else {
    preconditionFailure("Test JSON must be encodable.")
  }
  return text
}
