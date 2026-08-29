import AppKit
import BridgeIPC
import BridgeMCP
import SwiftUI
import XCTest

@testable import BridgeServiceAppShell

@MainActor
final class ConversationSwitchPresentationTests: XCTestCase {
  func testConversationStreamRedrawsWhenEntriesArriveWithoutRemounting() async throws {
    let client = TestBridgeServiceClient()
    await client.setConversationPages([
      .init(IPCTaskConversationRequest(taskID: "render-task", limit: 200)):
        conversationPage(taskID: "render-task", content: "Rendered response")
    ])
    let conversation = TaskConversationModel(
      taskID: "render-task",
      client: client,
      isTerminal: true
    )
    let stream = BridgeServiceWorkbenchConversationStream(
      conversation: conversation,
      selectedThread: nil,
      hasSelectedTask: true,
      activity: CodexActivityPresentation(task: nil, activity: .idle),
      providerID: "codex"
    )
    let hostingView = NSHostingView(rootView: stream.frame(width: 480, height: 320))
    hostingView.frame = NSRect(x: 0, y: 0, width: 480, height: 320)
    hostingView.layoutSubtreeIfNeeded()
    let emptyRendering = try renderingData(of: hostingView)

    await conversation.start()
    try await Task.sleep(for: .milliseconds(50))
    hostingView.layoutSubtreeIfNeeded()
    let populatedRendering = try renderingData(of: hostingView)

    XCTAssertEqual(conversation.entries.first?.content, "Rendered response")
    XCTAssertNotEqual(emptyRendering, populatedRendering)
  }

  func testReopeningLoadedConversationShowsItsContentBeforeServiceRefreshCompletes()
    async throws
  {
    let client = TestBridgeServiceClient()
    let first = terminalTask(id: "conversation-a", providerID: "opencode", minute: 0)
    let second = terminalTask(id: "conversation-b", providerID: "deepseek-harness", minute: 1)
    await client.setTaskSnapshots([second, first])
    await client.setConversationPages([
      .init(IPCTaskConversationRequest(taskID: first.taskID, limit: 200)):
        conversationPage(taskID: first.taskID, content: "Conversation A"),
      .init(IPCTaskConversationRequest(taskID: second.taskID, limit: 200)):
        conversationPage(taskID: second.taskID, content: "Conversation B"),
    ])
    let model = BridgeServiceAppModel(
      registration: ConversationSwitchTestRegistration(),
      clientFactory: { client },
      pollInterval: nil,
      connectionRetryDelay: .milliseconds(1),
      maximumConnectionAttempts: 1
    )

    await model.startAsync()
    model.openTask(first.taskID)
    try await waitUntil { model.conversation?.entries.first?.content == "Conversation A" }
    model.openTask(second.taskID)
    try await waitUntil { model.conversation?.entries.first?.content == "Conversation B" }

    await client.setConversationPages([
      .init(IPCTaskConversationRequest(taskID: first.taskID, limit: 200)):
        conversationPage(taskID: first.taskID, content: "Conversation A refreshed")
    ])
    await client.setConversationDelay(.milliseconds(300))
    model.openTask(first.taskID)

    XCTAssertEqual(model.conversation?.taskID, first.taskID)
    XCTAssertEqual(model.conversation?.entries.first?.content, "Conversation A")
    try await waitUntil {
      model.conversation?.entries.first?.content == "Conversation A refreshed"
    }
    await model.shutdownUI()
  }

  private func terminalTask(
    id: String,
    providerID: String,
    minute: Int
  ) -> MCPServiceTaskSnapshot {
    MCPServiceTaskSnapshot(
      taskID: id,
      projectID: "project-1",
      status: "completed",
      providerID: providerID,
      providerRunID: "run-\(id)",
      supervisorStatus: "disabled",
      localApprovalRequired: false,
      updatedAt: String(format: "2026-08-29T12:%02d:00Z", minute)
    )
  }

  private func conversationPage(
    taskID: String,
    content: String
  ) -> IPCTaskConversationPage {
    IPCTaskConversationPage(
      taskID: taskID,
      messages: [
        IPCTaskConversationMessage(
          messageID: 1,
          key: "agent:\(taskID)",
          role: "agent",
          content: content,
          final: true
        )
      ]
    )
  }

  private func renderingData<Content: View>(
    of view: NSHostingView<Content>
  ) throws -> Data {
    guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
      throw RenderingError.unavailable
    }
    view.cacheDisplay(in: view.bounds, to: representation)
    guard let data = representation.representation(using: .png, properties: [:]) else {
      throw RenderingError.unavailable
    }
    return data
  }

  private func waitUntil(
    timeout: Duration = .seconds(2),
    condition: @escaping @MainActor () async -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Condition did not become true before the deadline.")
  }
}

private enum RenderingError: Error {
  case unavailable
}

@MainActor
private final class ConversationSwitchTestRegistration: BridgeServiceRegistrationManaging {
  var status: BridgeServiceRegistrationStatus = .enabled

  func register() throws {}

  func unregister() async throws {
    status = .notRegistered
  }

  func openSystemSettings() {}
}
