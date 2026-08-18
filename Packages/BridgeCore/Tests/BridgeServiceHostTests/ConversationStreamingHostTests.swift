import BridgeCodexRPC
import BridgeDomain
import BridgeIPC
import BridgeProjects
import BridgeServiceCore
import BridgeServiceHost
import Foundation
import XCTest

final class ConversationStreamingHostTests: XCTestCase {
  func testConversationSubscriptionStreamsDeltasFromServiceExecution() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "bridge-conversation-streaming-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let secrets = ServiceHostTestSecretStore()
    let projectRoot = root.appending(path: "Project", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: false)
    let execution = AppServerConfiguration(
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", hostAgentDeltaScript(root: projectRoot.path)]
    )
    let unavailable = AppServerConfiguration(
      executableURL: URL(fileURLWithPath: "/bin/false"),
      arguments: []
    )
    let composition = try await ServiceComposition.make(
      configuration: ServiceCompositionConfiguration(
        appVersion: "0.2.0",
        dataRootURL: root,
        executionAppServer: execution,
        supervisorAppServer: unavailable,
        catalogAppServer: unavailable,
        clientInfo: .bridge(version: "conversation-streaming-tests")
      ),
      secretStore: secrets,
      randomBytes: { Data(repeating: 0x21, count: $0) }
    )
    addTeardownBlock { await composition.shutdown() }

    let pair = xpcClient(composition: composition)
    let client = pair.0
    let listener = pair.1
    defer {
      listener.invalidate()
      Task { await client.invalidate() }
    }

    let registered = try await client.registerProject(
      IPCProjectRegistrationRequest(
        name: "Streaming Project",
        absolutePath: projectRoot.path,
        writePermission: ProjectPermission.allowed.rawValue
      )
    )
    let submitted = try await composition.tasks.submit(
      ServiceTaskRequest(
        projectID: ProjectID(rawValue: registered.projectID),
        source: .macOSApp,
        clientRequestID: "request-streaming",
        prompt: "Implement the streaming change.",
        executionModel: "fixture-model",
        executionEffort: "medium",
        permissionMode: .workspaceWrite
      )
    )
    let taskID = submitted.task.id
    _ = try await composition.tasks.begin(taskID: taskID)

    let (subscription, updates) = try await client.subscribeTaskConversation(
      taskID: taskID.rawValue,
      limit: 200
    )
    XCTAssertEqual(subscription.subscriptionID, 0)
    XCTAssertTrue(subscription.page.messages.isEmpty)

    let collector = HostChangeCollector()
    let collect = Task { await collector.collect(updates) }

    _ = try await composition.coordinator.start(taskID: taskID)

    let completed = try await waitForHostTask(composition, taskID: taskID) {
      $0.state.status == .completed
    }
    XCTAssertEqual(completed.state.resultSummary, "Final streaming agent text.")

    let pushes = await collector.all()
    let userPushes = pushes.filter { $0.role == "user" }
    XCTAssertEqual(userPushes.count, 1)
    XCTAssertEqual(userPushes[0].fullContent, "Implement the streaming change.")
    XCTAssertEqual(userPushes[0].final, true)

    let agentPushes = pushes.filter { $0.key == "agent:item-stream" }
    XCTAssertEqual(agentPushes.count, 4)
    XCTAssertEqual(agentPushes[0].fullContent, "I will fix")
    XCTAssertEqual(agentPushes[0].baseContentLength, 0)
    XCTAssertEqual(agentPushes[1].delta, " the parser")
    XCTAssertEqual(agentPushes[1].baseContentLength, 10)
    XCTAssertEqual(agentPushes[2].delta, " now.")
    XCTAssertEqual(agentPushes[2].baseContentLength, 21)
    XCTAssertEqual(agentPushes[3].fullContent, "Final streaming agent text.")
    XCTAssertEqual(agentPushes[3].final, true)

    let page = try await client.taskConversation(
      IPCTaskConversationRequest(taskID: taskID.rawValue, limit: 200)
    )
    XCTAssertEqual(page.messages.count, 2)
    XCTAssertEqual(page.messages[1].key, "agent:item-stream")
    XCTAssertEqual(page.messages[1].content, "Final streaming agent text.")
    XCTAssertEqual(page.messages[1].final, true)

    try await client.unsubscribeTaskConversation(
      taskID: taskID.rawValue,
      subscriptionID: subscription.subscriptionID
    )
    collect.cancel()
  }

  func testDeleteTaskRemovesTaskAndConversation() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "bridge-conversation-delete-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let secrets = ServiceHostTestSecretStore()
    let unavailable = AppServerConfiguration(
      executableURL: URL(fileURLWithPath: "/bin/false"),
      arguments: []
    )
    let composition = try await ServiceComposition.make(
      configuration: ServiceCompositionConfiguration(
        appVersion: "0.2.0",
        dataRootURL: root,
        executionAppServer: unavailable,
        supervisorAppServer: unavailable,
        catalogAppServer: unavailable,
        clientInfo: .bridge(version: "conversation-delete-tests")
      ),
      secretStore: secrets,
      randomBytes: { Data(repeating: 0x22, count: $0) }
    )
    addTeardownBlock { await composition.shutdown() }

    let pair = xpcClient(composition: composition)
    let client = pair.0
    let listener = pair.1
    defer {
      listener.invalidate()
      Task { await client.invalidate() }
    }

    let projectRoot = root.appending(path: "Project", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: false)
    let registered = try await client.registerProject(
      IPCProjectRegistrationRequest(
        name: "Delete Project",
        absolutePath: projectRoot.path
      )
    )
    let submitted = try await composition.tasks.submit(
      ServiceTaskRequest(
        projectID: ProjectID(rawValue: registered.projectID),
        source: .macOSApp,
        clientRequestID: "request-delete",
        prompt: "Delete me.",
        executionModel: "fixture-model",
        executionEffort: "medium",
        permissionMode: .workspaceWrite
      )
    )
    let taskID = submitted.task.id
    _ = try await composition.tasks.begin(taskID: taskID)
    _ = try await composition.tasks.markExecutionStarted(
      taskID: taskID,
      threadID: "thread-delete",
      turnID: "turn-delete"
    )
    _ = try await composition.tasks.complete(
      taskID: taskID,
      resultSummary: "Done.",
      changedFiles: []
    )

    try await client.deleteTask(taskID: taskID.rawValue)

    let stored = try await composition.tasks.task(id: taskID)
    XCTAssertNil(stored)
    do {
      _ = try await client.taskConversation(
        IPCTaskConversationRequest(taskID: taskID.rawValue, limit: 200)
      )
      XCTFail("Expected task_not_found error after deletion")
    } catch let error as BridgeServiceIPCCodecError {
      guard case .remoteError(let remote) = error, remote.code == "task_not_found" else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  private func waitForHostTask(
    _ composition: ServiceComposition,
    taskID: TaskID,
    matching predicate: @escaping (ServiceTaskRecord) -> Bool,
    timeout: Duration = .seconds(6)
  ) async throws -> ServiceTaskRecord {
    let start = ContinuousClock.now
    while ContinuousClock.now - start < timeout {
      if let task = try await composition.tasks.task(id: taskID), predicate(task) {
        return task
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw HostTestError.timedOut
  }
}

enum HostTestError: Error {
  case timedOut
}

private actor HostChangeCollector {
  private var pushes: [IPCTaskConversationPush] = []

  func collect(_ stream: AsyncStream<IPCTaskConversationPush>) async {
    for await push in stream {
      pushes.append(push)
    }
  }

  func all() -> [IPCTaskConversationPush] {
    pushes
  }
}

private func hostThreadJSON(id: String, root: String) -> String {
  """
  {"id":"\(id)","cwd":"\(root)","ephemeral":false,"modelProvider":"fixture","preview":"","turns":[],"name":null,"cliVersion":"fixture/1","createdAt":1,"updatedAt":1,"sessionId":"session-1","status":{"type":"idle"},"source":"appServer"}
  """
}

private func hostTurnJSON(
  id: String,
  status: String,
  items: String = "[]"
) -> String {
  """
  {"id":"\(id)","status":"\(status)","error":null,"items":\(items),"itemsView":"full","startedAt":1,"completedAt":null,"durationMs":null}
  """
}

private func hostCommonHandshake() -> String {
  let model =
    #"{"id":"fixture-model","model":"fixture-model","displayName":"Fixture","description":"fixture","hidden":false,"supportedReasoningEfforts":[{"reasoningEffort":"medium","description":"Medium"}],"defaultReasoningEffort":"medium","isDefault":true}"#
  return #"""
    IFS= read -r initialize
    case "$initialize" in *'"method":"initialize"'*) ;; *) exit 11 ;; esac
    printf '%s\n' '{"id":1,"result":{"userAgent":"fixture/1","codexHome":"/private/fixture","platformFamily":"unix","platformOs":"macos"}}'
    IFS= read -r initialized
    case "$initialized" in *'"method":"initialized"'*) ;; *) exit 12 ;; esac
    IFS= read -r models
    case "$models" in *'"method":"model/list"'*) ;; *) exit 13 ;; esac
    printf '%s\n' '{"id":2,"result":{"data":[__MODEL__],"nextCursor":null}}'
    """#
    .replacingOccurrences(of: "__MODEL__", with: model)
}

func hostAgentDeltaScript(root: String) -> String {
  let thread = hostThreadJSON(id: "thread-host", root: root)
  let turn = hostTurnJSON(id: "turn-host", status: "inProgress")
  let completed = hostTurnJSON(
    id: "turn-host",
    status: "completed",
    items: #"[{"id":"item-stream","type":"agentMessage","text":"Final streaming agent text."}]"#
  )
  return hostCommonHandshake()
    + "\n"
      + #"""
      IFS= read -r thread_start
      case "$thread_start" in *'"method":"thread/start"'*) ;; *) exit 21 ;; esac
      printf '%s\n' '{"id":3,"result":{"thread":__THREAD__,"model":"fixture-model","modelProvider":"fixture","reasoningEffort":"medium","cwd":"__ROOT__","sandbox":{"type":"workspaceWrite","networkAccess":false,"writableRoots":["__ROOT__"],"excludeSlashTmp":false,"excludeTmpdirEnvVar":false},"approvalPolicy":"on-request","approvalsReviewer":"user","serviceTier":null}}'
      IFS= read -r turn_start
      case "$turn_start" in *'"method":"turn/start"'*) ;; *) exit 22 ;; esac
      printf '%s\n' '{"method":"turn/started","params":{"threadId":"thread-host","turn":__TURN__}}'
      printf '%s\n' '{"id":4,"result":{"turn":__TURN__}}'
      printf '%s\n' '{"method":"item/agentMessage/delta","params":{"threadId":"thread-host","turnId":"turn-host","itemId":"item-stream","delta":"I will fix"}}'
      printf '%s\n' '{"method":"item/agentMessage/delta","params":{"threadId":"thread-host","turnId":"turn-host","itemId":"item-stream","delta":" the parser"}}'
      printf '%s\n' '{"method":"item/agentMessage/delta","params":{"threadId":"thread-host","turnId":"turn-host","itemId":"item-stream","delta":" now."}}'
      printf '%s\n' '{"method":"turn/completed","params":{"threadId":"thread-host","turn":__COMPLETED__}}'
      sleep 1
      """#
    .replacingOccurrences(of: "__ROOT__", with: root)
    .replacingOccurrences(of: "__THREAD__", with: thread)
    .replacingOccurrences(of: "__TURN__", with: turn)
    .replacingOccurrences(of: "__COMPLETED__", with: completed)
}
