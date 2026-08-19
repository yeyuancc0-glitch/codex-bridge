import BridgeIPC
import Foundation
import SwiftUI

@MainActor
public final class TaskConversationModel: ObservableObject, Identifiable {
  public struct Entry: Identifiable, Equatable {
    public let key: String
    public let role: String
    public let kind: String
    public let messageID: Int64?
    public var content: String
    public var toolName: String?
    public var toolStatus: String?
    public var toolArguments: String?
    public var isFinal: Bool

    public var id: String { key }

    init(_ message: IPCTaskConversationMessage, isFinal: Bool) {
      key = message.key
      role = message.role
      kind = message.kind
      messageID = message.messageID
      content = message.content
      toolName = message.toolName
      toolStatus = message.toolStatus
      toolArguments = message.toolArguments
      self.isFinal = isFinal
    }

    init(key: String, role: String, kind: String, content: String, isFinal: Bool) {
      self.key = key
      self.role = role
      self.kind = kind
      messageID = nil
      self.content = content
      toolName = nil
      toolStatus = nil
      toolArguments = nil
      self.isFinal = isFinal
    }
  }

  @Published public private(set) var entries: [Entry] = []
  @Published public private(set) var isStreaming = false
  @Published public private(set) var errorMessage: String?
  @Published public private(set) var isLoadingEarlier = false
  @Published public var autoScroll = true
  @Published public private(set) var scrollAnchor: String?

  public let taskID: String
  public private(set) var subscriptionID = -1

  private static let pushBatchDelay: Duration = .milliseconds(40)

  private let client: any BridgeServiceClientProtocol
  private var index: [String: Int] = [:]
  private var hasAppliedPage = false
  private var streamingTask: Task<Void, Never>?
  private var pushFlushTask: Task<Void, Never>?
  private var pendingPushes: [IPCTaskConversationPush] = []

  public init(taskID: String, client: any BridgeServiceClientProtocol) {
    self.taskID = taskID
    self.client = client
  }

  public var canLoadEarlier: Bool {
    entries.first(where: { $0.messageID != nil }) != nil
  }

  func start() async {
    do {
      let (subscription, updates) = try await client.subscribeTaskConversation(
        taskID: taskID,
        limit: 200
      )
      subscriptionID = subscription.subscriptionID
      applyPage(subscription.page)
      hasAppliedPage = true
      streamingTask = Task { [weak self] in
        for await push in updates {
          guard let self, self.hasAppliedPage else { continue }
          self.enqueuePush(push)
        }
        self?.flushPendingPushes()
      }
    } catch {
      errorMessage = BridgeServiceAppModel.message(error)
      do {
        let page = try await client.taskConversation(
          IPCTaskConversationRequest(taskID: taskID, limit: 200)
        )
        applyPage(page)
      } catch {
        errorMessage = BridgeServiceAppModel.message(error)
      }
    }
  }

  func cancel() {
    streamingTask?.cancel()
    streamingTask = nil
    pushFlushTask?.cancel()
    pushFlushTask = nil
    pendingPushes.removeAll(keepingCapacity: false)
  }

  func loadEarlier() async {
    flushPendingPushes()
    guard canLoadEarlier, !isLoadingEarlier else { return }
    let anchor = entries.first(where: { $0.messageID != nil })?.messageID
    guard let anchor else { return }
    isLoadingEarlier = true
    defer { isLoadingEarlier = false }
    do {
      let page = try await client.taskConversation(
        IPCTaskConversationRequest(taskID: taskID, beforeMessageID: anchor, limit: 100)
      )
      guard !page.messages.isEmpty else { return }
      let older = page.messages
        .filter { index[$0.key] == nil }
        .map { Entry($0, isFinal: true) }
      guard !older.isEmpty else { return }
      entries = older + entries
      rebuildIndex()
      scrollAnchor = entries.last?.key
    } catch {
      errorMessage = BridgeServiceAppModel.message(error)
    }
  }

  private func applyPage(_ page: IPCTaskConversationPage) {
    pushFlushTask?.cancel()
    pushFlushTask = nil
    pendingPushes.removeAll(keepingCapacity: false)
    entries = page.messages.map { Entry($0, isFinal: $0.final) }
    rebuildIndex()
    refreshStreamingState()
    scrollAnchor = entries.last?.key
  }

  private func enqueuePush(_ push: IPCTaskConversationPush) {
    pendingPushes.append(push)
    guard pushFlushTask == nil else { return }
    pushFlushTask = Task { [weak self] in
      do {
        try await Task.sleep(for: Self.pushBatchDelay)
      } catch {
        return
      }
      self?.flushPendingPushes()
    }
  }

  private func flushPendingPushes() {
    pushFlushTask?.cancel()
    pushFlushTask = nil
    guard !pendingPushes.isEmpty else { return }
    let pushes = pendingPushes
    pendingPushes.removeAll(keepingCapacity: true)
    applyPushBatch(pushes)
  }

  private func applyPushBatch(_ pushes: [IPCTaskConversationPush]) {
    var updatedEntries = entries
    var updatedIndex = index
    var changed = false

    for push in pushes {
      if let position = updatedIndex[push.key] {
        var entry = updatedEntries[position]
        if let fullContent = push.fullContent {
          entry.content = fullContent
        } else if let delta = push.delta, entry.content.count == push.baseContentLength {
          entry.content += delta
        }
        if let toolName = push.toolName {
          entry.toolName = toolName
        }
        if let toolStatus = push.toolStatus {
          entry.toolStatus = toolStatus
        }
        if let toolArguments = push.toolArguments {
          entry.toolArguments = toolArguments
        }
        if push.final {
          entry.isFinal = true
        }
        updatedEntries[position] = entry
        changed = true
      } else {
        guard
          let content = push.fullContent
            ?? (push.baseContentLength == 0 ? push.delta : nil)
        else { continue }
        var entry = Entry(
          key: push.key,
          role: push.role,
          kind: push.kind,
          content: content,
          isFinal: push.final
        )
        entry.toolName = push.toolName
        entry.toolStatus = push.toolStatus
        entry.toolArguments = push.toolArguments
        updatedIndex[entry.key] = updatedEntries.count
        updatedEntries.append(entry)
        changed = true
      }
    }

    guard changed else { return }
    entries = updatedEntries
    index = updatedIndex
    refreshStreamingState()
    if autoScroll {
      scrollAnchor = entries.last?.key
    }
  }

  private func rebuildIndex() {
    index.removeAll(keepingCapacity: true)
    for (position, entry) in entries.enumerated() {
      index[entry.key] = position
    }
  }

  private func refreshStreamingState() {
    isStreaming = entries.last(where: { $0.role == "agent" })?.isFinal == false
  }
}
