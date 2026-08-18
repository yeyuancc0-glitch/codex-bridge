import BridgeIPC
import Foundation
import SwiftUI

@MainActor
public final class TaskConversationModel: ObservableObject, Identifiable {
  public struct Entry: Identifiable, Equatable {
    public let key: String
    public let role: String
    public let messageID: Int64?
    public var content: String
    public var isFinal: Bool

    public var id: String { key }

    init(_ message: IPCTaskConversationMessage, isFinal: Bool) {
      key = message.key
      role = message.role
      messageID = message.messageID
      content = message.content
      self.isFinal = isFinal
    }

    init(key: String, role: String, content: String, isFinal: Bool) {
      self.key = key
      self.role = role
      messageID = nil
      self.content = content
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

  private let client: any BridgeServiceClientProtocol
  private var index: [String: Int] = [:]
  private var hasAppliedPage = false
  private var streamingTask: Task<Void, Never>?

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
          self.applyPush(push)
        }
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
  }

  func loadEarlier() async {
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
    entries = page.messages.map { Entry($0, isFinal: $0.final) }
    rebuildIndex()
    refreshStreamingState()
    scrollAnchor = entries.last?.key
  }

  private func applyPush(_ push: IPCTaskConversationPush) {
    if let position = index[push.key] {
      var entry = entries[position]
      if let fullContent = push.fullContent {
        entry.content = fullContent
      } else if let delta = push.delta, entry.content.count == push.baseContentLength {
        entry.content += delta
      }
      if push.final {
        entry.isFinal = true
      }
      entries[position] = entry
    } else {
      guard
        let content = push.fullContent
          ?? (push.baseContentLength == 0 ? push.delta : nil)
      else { return }
      let entry = Entry(
        key: push.key,
        role: push.role,
        content: content,
        isFinal: push.final
      )
      index[entry.key] = entries.count
      entries.append(entry)
    }
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