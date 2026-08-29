import BridgeCodexRPC
import BridgeCodexService
import BridgeDomain
import BridgeIPC
import BridgeMCP
import BridgeProjects
import BridgeServiceCore
import Foundation
import XCTest

@testable import BridgeServiceHost

final class ConversationStreamingHostTests: XCTestCase {
  func testXPCListsAndDeniesChatGPTTaskStartApproval() async throws {
    let fixture = try await makeServiceHostFixture(self)
    let projectRoot = fixture.root.appending(path: "Approval Project", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: false)
    let project = try await fixture.composition.projects.register(
      name: "Approval Project",
      rootURL: projectRoot
    )
    let creation = try await fixture.composition.tasks.submit(
      ServiceTaskRequest(
        projectID: project.id,
        source: .mcpClient,
        sourceClientID: MCPClientID.chatGPT.rawValue,
        prompt: "Request Codex through ChatGPT.",
        executionModel: "fixture-model",
        executionEffort: "medium",
        permissionMode: .workspaceWrite
      )
    )
    let controller = BridgeServiceXPCController(composition: fixture.composition)
    let listRequestID = "list-task-start-approval"
    let listRequest = try BridgeServiceIPCCodec.request(
      operation: .listApprovals,
      payload: IPCApprovalListRequest(),
      requestID: listRequestID
    )
    let listResponse = await performXPC(controller, request: listRequest)
    let list = try BridgeServiceIPCCodec.decodeResponse(
      IPCApprovalListResponse.self,
      data: listResponse,
      requestID: listRequestID
    )
    let approval = try XCTUnwrap(list.approvals.first)
    XCTAssertEqual(approval.taskID, creation.task.id.rawValue)
    XCTAssertEqual(approval.kind, "task_start")
    XCTAssertEqual(approval.decisionOptions, ["allow", "deny"])
    XCTAssertTrue(approval.reason?.contains("权限：workspace-write") == true)
    XCTAssertTrue(approval.reason?.contains("网络：未请求") == true)

    let resolveRequestID = "deny-task-start-approval"
    let resolveRequest = try BridgeServiceIPCCodec.request(
      operation: .resolveApproval,
      payload: IPCApprovalResolutionRequest(
        taskID: approval.taskID,
        approvalID: approval.approvalID,
        decision: "deny"
      ),
      requestID: resolveRequestID
    )
    let resolveResponse = await performXPC(controller, request: resolveRequest)
    _ = try BridgeServiceIPCCodec.decodeResponse(
      IPCMutationResponse.self,
      data: resolveResponse,
      requestID: resolveRequestID
    )
    let deniedValue = try await fixture.composition.tasks.task(id: creation.task.id)
    let denied = try XCTUnwrap(deniedValue)
    XCTAssertEqual(denied.state.status, .failed)
    XCTAssertEqual(denied.state.failureCode, "local_approval_denied")
    XCTAssertEqual(denied.state.resultSummary, "The local user denied this provider invocation.")
  }

  func testConcurrentConversationSubscriptionsReplaceWithoutExhaustingSlots() async throws {
    let fixture = try await makeServiceHostFixture(self)
    let projectRoot = fixture.root.appending(
      path: "Concurrent Project", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: false)
    let project = try await fixture.composition.projects.register(
      name: "Concurrent Project",
      rootURL: projectRoot,
      accessPolicy: ProjectAccessPolicy(
        read: .allowed,
        write: .allowed,
        network: .denied
      )
    )
    let task = try await fixture.composition.tasks.submit(
      ServiceTaskRequest(
        projectID: project.id,
        source: .macOSApp,
        prompt: "Exercise concurrent conversation subscriptions.",
        executionModel: "fixture-model",
        executionEffort: "medium",
        permissionMode: .workspaceWrite
      )
    )
    let proxy = TestConversationStreamProxy()
    let controller = BridgeServiceXPCController(
      composition: fixture.composition,
      streamProxy: proxy,
      maximumConcurrentRequests: 16
    )
    let requestIDs = (0..<16).map { "subscribe-\($0)" }
    let requests = try requestIDs.map { requestID in
      try BridgeServiceIPCCodec.request(
        operation: .subscribeTaskConversation,
        payload: IPCTaskConversationRequest(taskID: task.task.id.rawValue),
        requestID: requestID
      )
    }

    let responses = await withTaskGroup(of: (String, Data).self, returning: [(String, Data)].self) {
      group in
      for (requestID, request) in zip(requestIDs, requests) {
        group.addTask {
          (requestID, await performXPC(controller, request: request))
        }
      }
      var values: [(String, Data)] = []
      for await value in group {
        values.append(value)
      }
      return values
    }

    XCTAssertEqual(responses.count, requestIDs.count)
    for (requestID, response) in responses {
      let subscription = try BridgeServiceIPCCodec.decodeResponse(
        IPCTaskConversationSubscription.self,
        data: response,
        requestID: requestID
      )
      XCTAssertGreaterThanOrEqual(subscription.subscriptionID, 0)
    }
    XCTAssertEqual(controller.streams.count(), 1)
    controller.stopStreaming()
  }

  func testStaleConversationUnsubscribeDoesNotCancelReplacement() async throws {
    let fixture = try await makeServiceHostFixture(self)
    let projectRoot = fixture.root.appending(path: "Stale Unsubscribe", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: false)
    let project = try await fixture.composition.projects.register(
      name: "Stale Unsubscribe",
      rootURL: projectRoot
    )
    let task = try await fixture.composition.tasks.submit(
      ServiceTaskRequest(
        projectID: project.id,
        source: .macOSApp,
        prompt: "Exercise stale unsubscribe handling.",
        executionModel: "fixture-model",
        executionEffort: "medium",
        permissionMode: .readOnly
      )
    )
    let controller = BridgeServiceXPCController(
      composition: fixture.composition,
      streamProxy: TestConversationStreamProxy()
    )
    let taskID = task.task.id.rawValue
    let first = try await subscribe(controller, taskID: taskID, requestID: "subscribe-first")
    let second = try await subscribe(controller, taskID: taskID, requestID: "subscribe-second")
    XCTAssertNotEqual(first.subscriptionID, second.subscriptionID)
    XCTAssertEqual(controller.streams.count(), 1)

    let staleRequest = try BridgeServiceIPCCodec.request(
      operation: .unsubscribeTaskConversation,
      payload: IPCTaskConversationUnsubscribeRequest(
        taskID: taskID,
        subscriptionID: first.subscriptionID
      ),
      requestID: "unsubscribe-stale"
    )
    _ = await performXPC(controller, request: staleRequest)
    XCTAssertEqual(controller.streams.count(), 1)
    controller.stopStreaming()
  }

  private func subscribe(
    _ controller: BridgeServiceXPCController,
    taskID: String,
    requestID: String
  ) async throws -> IPCTaskConversationSubscription {
    let request = try BridgeServiceIPCCodec.request(
      operation: .subscribeTaskConversation,
      payload: IPCTaskConversationRequest(taskID: taskID),
      requestID: requestID
    )
    return try BridgeServiceIPCCodec.decodeResponse(
      IPCTaskConversationSubscription.self,
      data: await performXPC(controller, request: request),
      requestID: requestID
    )
  }

  func testConversationSubscriptionResponseFailureReclaimsForwarder() async throws {
    let fixture = try await makeServiceHostFixture(self)
    let projectRoot = fixture.root.appending(path: "Oversized Project", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: false)
    let project = try await fixture.composition.projects.register(
      name: "Oversized Project",
      rootURL: projectRoot,
      accessPolicy: ProjectAccessPolicy(
        read: .allowed,
        write: .allowed,
        network: .denied
      )
    )
    let task = try await fixture.composition.tasks.submit(
      ServiceTaskRequest(
        projectID: project.id,
        source: .macOSApp,
        prompt: "Exercise oversized conversation response cleanup.",
        executionModel: "fixture-model",
        executionEffort: "medium",
        permissionMode: .workspaceWrite
      )
    )
    let content = String(repeating: "x", count: TaskConversationBuffer.maximumMessageBytes)
    for index in 0..<40 {
      try await fixture.composition.tasks.upsertTaskMessage(
        taskID: task.task.id,
        key: "agent:oversized-\(index)",
        role: .agent,
        content: content
      )
    }

    let controller = BridgeServiceXPCController(
      composition: fixture.composition,
      streamProxy: TestConversationStreamProxy()
    )
    let requestID = "oversized-subscribe"
    let request = try BridgeServiceIPCCodec.request(
      operation: .subscribeTaskConversation,
      payload: IPCTaskConversationRequest(taskID: task.task.id.rawValue),
      requestID: requestID
    )
    let response = await performXPC(controller, request: request)

    XCTAssertThrowsError(
      try BridgeServiceIPCCodec.decodeResponse(
        IPCTaskConversationSubscription.self,
        data: response,
        requestID: requestID
      )
    )
    XCTAssertEqual(controller.streams.count(), 0)
  }

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
        clientInfo: .bridge(version: "conversation-streaming-tests"),
        synchronizeCodexProjects: false
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

  func testPersistedConversationPageUsesTaskStateForFinality() async throws {
    let fixture = try await makeServiceHostFixture(self)
    let projectRoot = fixture.root.appending(
      path: "Persisted Conversation Project", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: false)
    let project = try await fixture.composition.projects.register(
      name: "Persisted Conversation Project",
      rootURL: projectRoot,
      accessPolicy: ProjectAccessPolicy(
        read: .allowed,
        write: .allowed,
        network: .denied
      )
    )
    let submitted = try await fixture.composition.tasks.submit(
      ServiceTaskRequest(
        projectID: project.id,
        source: .macOSApp,
        clientRequestID: "request-persisted-conversation",
        prompt: "Exercise persisted conversation finality.",
        executionModel: "fixture-model",
        executionEffort: "medium",
        permissionMode: .workspaceWrite
      )
    )
    let taskID = submitted.task.id
    _ = try await fixture.composition.tasks.begin(taskID: taskID)
    _ = try await fixture.composition.tasks.markExecutionStarted(
      taskID: taskID,
      threadID: "thread-persisted-conversation",
      turnID: "turn-persisted-conversation"
    )
    try await fixture.composition.tasks.upsertTaskMessage(
      taskID: taskID,
      key: "user:prompt",
      role: .user,
      content: "Exercise persisted conversation finality.",
      kind: .user
    )
    try await fixture.composition.tasks.upsertTaskMessage(
      taskID: taskID,
      key: "agent:partial",
      role: .agent,
      content: "Partial response",
      kind: .agent
    )
    try await fixture.composition.tasks.upsertTaskMessage(
      taskID: taskID,
      key: "reasoning:partial",
      role: .agent,
      content: "Partial reasoning",
      kind: .reasoning
    )
    try await fixture.composition.tasks.upsertTaskMessage(
      taskID: taskID,
      key: "tool:completed",
      role: .agent,
      content: "Completed tool",
      kind: .toolCall,
      toolName: "read",
      toolStatus: "completed"
    )
    try await fixture.composition.tasks.upsertTaskMessage(
      taskID: taskID,
      key: "tool:active",
      role: .agent,
      content: "Active tool",
      kind: .toolCall,
      toolName: "write",
      toolStatus: "inProgress"
    )

    let pair = xpcClient(composition: fixture.composition)
    let client = pair.0
    let listener = pair.1
    defer {
      listener.invalidate()
      Task { await client.invalidate() }
    }

    let runningPage = try await client.taskConversation(
      IPCTaskConversationRequest(taskID: taskID.rawValue, limit: 200)
    )
    let runningFinality = Dictionary(
      uniqueKeysWithValues: runningPage.messages.map { ($0.key, $0.final) }
    )
    XCTAssertEqual(runningFinality["user:prompt"], true)
    XCTAssertEqual(runningFinality["agent:partial"], false)
    XCTAssertEqual(runningFinality["reasoning:partial"], false)
    XCTAssertEqual(runningFinality["tool:completed"], true)
    XCTAssertEqual(runningFinality["tool:active"], false)

    let (subscription, _) = try await client.subscribeTaskConversation(
      taskID: taskID.rawValue,
      limit: 200
    )
    let subscriptionFinality = Dictionary(
      uniqueKeysWithValues: subscription.page.messages.map { ($0.key, $0.final) }
    )
    XCTAssertEqual(subscriptionFinality["user:prompt"], true)
    XCTAssertEqual(subscriptionFinality["agent:partial"], false)
    XCTAssertEqual(subscriptionFinality["reasoning:partial"], false)
    XCTAssertEqual(subscriptionFinality["tool:completed"], true)
    XCTAssertEqual(subscriptionFinality["tool:active"], false)
    try await client.unsubscribeTaskConversation(
      taskID: taskID.rawValue,
      subscriptionID: subscription.subscriptionID
    )

    _ = try await fixture.composition.tasks.complete(
      taskID: taskID,
      resultSummary: "Persisted conversation finalized.",
      changedFiles: []
    )
    let completedPage = try await client.taskConversation(
      IPCTaskConversationRequest(taskID: taskID.rawValue, limit: 200)
    )
    XCTAssertTrue(completedPage.messages.allSatisfy(\.final))

    for _ in 0..<2 {
      let (completedSubscription, _) = try await client.subscribeTaskConversation(
        taskID: taskID.rawValue,
        limit: 200
      )
      XCTAssertEqual(completedSubscription.subscriptionID, -1)
      XCTAssertEqual(
        completedSubscription.page.messages.map(\.key),
        completedPage.messages.map(\.key)
      )
      XCTAssertEqual(
        completedSubscription.page.messages.map(\.content),
        completedPage.messages.map(\.content)
      )
      XCTAssertTrue(completedSubscription.page.messages.allSatisfy(\.final))
    }
  }

  func testConversationSubscriptionStreamsReasoningAndToolCalls() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "bridge-conversation-rich-\(UUID().uuidString)",
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
      arguments: ["-c", hostRichConversationScript(root: projectRoot.path)]
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
        clientInfo: .bridge(version: "conversation-rich-tests"),
        synchronizeCodexProjects: false
      ),
      secretStore: secrets,
      randomBytes: { Data(repeating: 0x23, count: $0) }
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
        name: "Rich Streaming Project",
        absolutePath: projectRoot.path,
        writePermission: ProjectPermission.allowed.rawValue
      )
    )
    let submitted = try await composition.tasks.submit(
      ServiceTaskRequest(
        projectID: ProjectID(rawValue: registered.projectID),
        source: .macOSApp,
        clientRequestID: "request-rich-streaming",
        prompt: "Fix the tokenizer.",
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

    let collector = HostChangeCollector()
    let collect = Task { await collector.collect(updates) }

    _ = try await composition.coordinator.start(taskID: taskID)

    let completed = try await waitForHostTask(composition, taskID: taskID) {
      $0.state.status == .completed
    }
    XCTAssertEqual(completed.state.resultSummary, "Final streaming agent text.")

    let pushes = await collector.all()

    let reasoningPushes = pushes.filter { $0.kind == "reasoning" }
    XCTAssertEqual(reasoningPushes.count, 3)
    XCTAssertEqual(reasoningPushes[0].fullContent, "I should inspect")
    XCTAssertEqual(reasoningPushes[0].baseContentLength, 0)
    XCTAssertEqual(reasoningPushes[1].delta, " the parser.")
    XCTAssertEqual(reasoningPushes[1].baseContentLength, 16)
    XCTAssertEqual(reasoningPushes[2].final, true)
    XCTAssertEqual(reasoningPushes[2].fullContent, "I should inspect the parser.")

    let toolPushes = pushes.filter { $0.kind == "tool_call" }
    XCTAssertTrue(toolPushes.count >= 3)
    XCTAssertEqual(toolPushes[0].toolName, "read")
    XCTAssertEqual(toolPushes[0].toolStatus, "inProgress")
    XCTAssertEqual(toolPushes[1].delta, "\nReading Sources/A.swift")
    XCTAssertEqual(toolPushes.last?.toolStatus, "completed")
    XCTAssertEqual(toolPushes.last?.final, true)

    let page = try await client.taskConversation(
      IPCTaskConversationRequest(taskID: taskID.rawValue, limit: 200)
    )
    let reasoning = page.messages.first { $0.kind == "reasoning" }
    XCTAssertNotNil(reasoning)
    XCTAssertTrue(reasoning?.content.contains("I should inspect the parser.") == true)
    let tool = page.messages.first { $0.kind == "tool_call" }
    XCTAssertNotNil(tool)
    XCTAssertEqual(tool?.toolName, "read")
    XCTAssertEqual(tool?.toolStatus, "completed")
    XCTAssertEqual(tool?.toolArguments, #"{"path":"Sources/A.swift"}"#)
    XCTAssertTrue(tool?.content.contains("Reading Sources/A.swift") == true)

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

private final class TestConversationStreamProxy: NSObject, CodexBridgeTaskStreamListener {
  func push(_ payload: Data) {
    _ = payload
  }
}

private func performXPC(
  _ controller: BridgeServiceXPCController,
  request: Data
) async -> Data {
  await withCheckedContinuation { continuation in
    controller.perform(request) { response in
      continuation.resume(returning: response)
    }
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

func hostRichConversationScript(root: String) -> String {
  let thread = hostThreadJSON(id: "thread-host-rich", root: root)
  let turn = hostTurnJSON(id: "turn-host-rich", status: "inProgress")
  let completedItems =
    #"[{"id":"reasoning-main","type":"reasoning","content":["I should inspect the parser."],"summary":[]},"#
    + #"{"id":"tool-read","type":"mcpToolCall","tool":"read","server":"filesystem","arguments":{"path":"Sources/A.swift"},"status":"completed"},"#
    + #"{"id":"item-stream","type":"agentMessage","text":"Final streaming agent text."}]"#
  let completed = hostTurnJSON(id: "turn-host-rich", status: "completed", items: completedItems)
  return hostCommonHandshake()
    + "\n"
      + #"""
      IFS= read -r thread_start
      case "$thread_start" in *'"method":"thread/start"'*) ;; *) exit 21 ;; esac
      printf '%s\n' '{"id":3,"result":{"thread":__THREAD__,"model":"fixture-model","modelProvider":"fixture","reasoningEffort":"medium","cwd":"__ROOT__","sandbox":{"type":"workspaceWrite","networkAccess":false,"writableRoots":["__ROOT__"],"excludeSlashTmp":false,"excludeTmpdirEnvVar":false},"approvalPolicy":"on-request","approvalsReviewer":"user","serviceTier":null}}'
      IFS= read -r turn_start
      case "$turn_start" in *'"method":"turn/start"'*) ;; *) exit 22 ;; esac
      printf '%s\n' '{"method":"turn/started","params":{"threadId":"thread-host-rich","turn":__TURN__}}'
      printf '%s\n' '{"id":4,"result":{"turn":__TURN__}}'
      printf '%s\n' '{"method":"item/reasoning/textDelta","params":{"threadId":"thread-host-rich","turnId":"turn-host-rich","itemId":"reasoning-main","contentIndex":0,"delta":"I should inspect"}}'
      printf '%s\n' '{"method":"item/reasoning/textDelta","params":{"threadId":"thread-host-rich","turnId":"turn-host-rich","itemId":"reasoning-main","contentIndex":0,"delta":" the parser."}}'
      printf '%s\n' '{"method":"item/started","params":{"threadId":"thread-host-rich","turnId":"turn-host-rich","startedAtMs":1,"item":{"id":"tool-read","type":"mcpToolCall","tool":"read","server":"filesystem","arguments":{"path":"Sources/A.swift"},"status":"inProgress"}}}'
      printf '%s\n' '{"method":"item/mcpToolCall/progress","params":{"threadId":"thread-host-rich","turnId":"turn-host-rich","itemId":"tool-read","message":"Reading Sources/A.swift"}}'
      printf '%s\n' '{"method":"item/completed","params":{"threadId":"thread-host-rich","turnId":"turn-host-rich","completedAtMs":2,"item":{"id":"tool-read","type":"mcpToolCall","tool":"read","server":"filesystem","arguments":{"path":"Sources/A.swift"},"status":"completed"}}}'
      printf '%s\n' '{"method":"item/agentMessage/delta","params":{"threadId":"thread-host-rich","turnId":"turn-host-rich","itemId":"item-stream","delta":"Final streaming agent text."}}'
      printf '%s\n' '{"method":"turn/completed","params":{"threadId":"thread-host-rich","turn":__COMPLETED__}}'
      sleep 1
      """#
    .replacingOccurrences(of: "__ROOT__", with: root)
    .replacingOccurrences(of: "__THREAD__", with: thread)
    .replacingOccurrences(of: "__TURN__", with: turn)
    .replacingOccurrences(of: "__COMPLETED__", with: completed)
}
