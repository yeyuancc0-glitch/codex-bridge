import BridgeIPC
import Foundation

#if canImport(Combine)
  import Combine
#endif

@MainActor
public final class TaskConversationModel: Identifiable {
  #if canImport(Combine)
    @Published public private(set) var entries: [Entry] = []
    @Published public private(set) var isStreaming = false
    @Published public private(set) var activity: Activity = .idle
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var isLoadingEarlier = false
    @Published public private(set) var canLoadEarlier = false
    @Published public var autoScroll = true
    @Published public private(set) var scrollAnchor: String?
    @Published public private(set) var scrollRevision: UInt64 = 0
  #else
    public private(set) var entries: [Entry] = []
    public private(set) var isStreaming = false
    public private(set) var activity: Activity = .idle
    public private(set) var errorMessage: String?
    public private(set) var isLoadingEarlier = false
    public private(set) var canLoadEarlier = false
    public var autoScroll = true
    public private(set) var scrollAnchor: String?
    public private(set) var scrollRevision: UInt64 = 0
  #endif

  public let id = UUID()
  public let taskID: String
  public private(set) var subscriptionID = -1

  private static let pushBatchDelay: Duration = .milliseconds(16)

  private let client: any BridgeTaskConversationClient
  private let isTerminal: Bool
  private var index: [String: Int] = [:]
  private var hasAppliedPage = false
  private var streamingTask: Task<Void, Never>?
  private var pushFlushTask: Task<Void, Never>?
  private var resyncTask: Task<Void, Never>?
  private var pendingPushes: [IPCTaskConversationPush] = []
  private var pendingResyncPushes: [IPCTaskConversationPush] = []
  private var lifecycleGeneration: UInt64 = 0
  private var loadGeneration: UInt64 = 0
  private var hasLoadedTerminalSnapshot = false
  private var hasRestoredPresentation = false

  private static let maximumPendingPushes = 256
  private static let resyncRetryDelays: [Duration] = [
    .milliseconds(100),
    .milliseconds(250),
    .milliseconds(500),
    .seconds(1),
    .seconds(1),
  ]
  private static let terminalSnapshotRetryDelays: [Duration] = [
    .zero, .milliseconds(80), .milliseconds(200), .milliseconds(400),
  ]

  public init(
    taskID: String,
    client: any BridgeTaskConversationClient,
    isTerminal: Bool = false
  ) {
    self.taskID = taskID
    self.client = client
    self.isTerminal = isTerminal
  }

  public func start() async {
    if isTerminal {
      await reloadAuthoritativeSnapshot()
      return
    }
    let generation = lifecycleGeneration
    loadGeneration &+= 1
    let requestLoadGeneration = self.loadGeneration
    do {
      let (subscription, updates) = try await client.subscribeTaskConversation(
        taskID: taskID,
        limit: 200
      )
      guard isRequestValid(lifecycle: generation, load: requestLoadGeneration) else {
        if subscription.subscriptionID >= 0 {
          try? await client.unsubscribeTaskConversation(
            taskID: taskID,
            subscriptionID: subscription.subscriptionID
          )
        }
        return
      }
      guard applySubscriptionPage(subscription.page) else {
        if subscription.subscriptionID >= 0 {
          try? await client.unsubscribeTaskConversation(
            taskID: taskID,
            subscriptionID: subscription.subscriptionID
          )
        }
        return
      }
      subscriptionID = subscription.subscriptionID
      hasAppliedPage = true
      streamingTask = Task { [weak self] in
        for await push in updates {
          guard let self, self.hasAppliedPage else { continue }
          self.enqueuePush(push)
        }
        self?.flushPendingPushes()
      }
    } catch {
      guard isRequestValid(lifecycle: generation, load: requestLoadGeneration) else { return }
      errorMessage = BridgeServiceErrorMessage.message(error)
      do {
        let page = try await client.taskConversation(
          IPCTaskConversationRequest(taskID: taskID, limit: 200)
        )
        guard isRequestValid(lifecycle: generation, load: requestLoadGeneration) else { return }
        _ = applyAuthoritativePage(page)
      } catch {
        guard isRequestValid(lifecycle: generation, load: requestLoadGeneration) else { return }
        errorMessage = BridgeServiceErrorMessage.message(error)
      }
    }
  }

  public func cancel() {
    lifecycleGeneration &+= 1
    loadGeneration &+= 1
    invalidateLiveSubscription()
    hasAppliedPage = false
    hasLoadedTerminalSnapshot = false
    pushFlushTask?.cancel()
    pushFlushTask = nil
    pendingPushes.removeAll(keepingCapacity: false)
    pendingResyncPushes.removeAll(keepingCapacity: false)
  }

  public func refreshPresentation() {
    guard !entries.isEmpty else { return }
    requestAutoScroll()
  }

  public func presentationSnapshot() -> TaskConversationPresentationSnapshot? {
    flushPendingPushes()
    guard !entries.isEmpty else { return nil }
    return TaskConversationPresentationSnapshot(
      entries: entries,
      canLoadEarlier: canLoadEarlier
    )
  }

  public func restorePresentation(_ snapshot: TaskConversationPresentationSnapshot?) {
    guard let snapshot, !snapshot.entries.isEmpty else { return }
    entries = snapshot.entries
    canLoadEarlier = snapshot.canLoadEarlier
    hasRestoredPresentation = true
    hasLoadedTerminalSnapshot = isTerminal
    rebuildIndex()
    refreshStreamingState()
    requestAutoScroll()
  }

  public func loadEarlier() async {
    flushPendingPushes()
    guard canLoadEarlier, !isLoadingEarlier else { return }
    let anchor = entries.first(where: { $0.messageID != nil })?.messageID
    guard let anchor else { return }
    let lifecycle = lifecycleGeneration
    let load = loadGeneration
    isLoadingEarlier = true
    defer { isLoadingEarlier = false }
    do {
      let page = try await client.taskConversation(
        IPCTaskConversationRequest(taskID: taskID, beforeMessageID: anchor, limit: 100)
      )
      guard isRequestValid(lifecycle: lifecycle, load: load) else { return }
      guard page.taskID == taskID else { return }
      canLoadEarlier = page.messages.count >= 100
      guard !page.messages.isEmpty else { return }
      let older = page.messages
        .filter { index[$0.key] == nil }
        .map { Entry($0, isFinal: true) }
      guard !older.isEmpty else { return }
      entries = older + entries
      rebuildIndex()
      scrollAnchor = entries.last?.key
    } catch {
      guard isRequestValid(lifecycle: lifecycle, load: load) else { return }
      errorMessage = BridgeServiceErrorMessage.message(error)
    }
  }

  func reloadAuthoritativeSnapshot() async {
    loadGeneration &+= 1
    let requestLoadGeneration = self.loadGeneration
    let generation = lifecycleGeneration
    invalidateLiveSubscription()
    let delays = isTerminal ? Self.terminalSnapshotRetryDelays : [.zero]
    var lastError: Error?
    for (index, delay) in delays.enumerated() {
      if delay > .zero {
        do {
          try await Task.sleep(for: delay)
        } catch {
          return
        }
      }
      guard isRequestValid(lifecycle: generation, load: requestLoadGeneration) else { return }
      do {
        let page = try await client.taskConversation(
          IPCTaskConversationRequest(taskID: taskID, limit: 200)
        )
        guard isRequestValid(lifecycle: generation, load: requestLoadGeneration) else { return }
        if isTerminal, page.messages.isEmpty, index < delays.count - 1 {
          continue
        }
        _ = applyAuthoritativePage(page)
        return
      } catch {
        lastError = error
      }
    }
    guard isRequestValid(lifecycle: generation, load: requestLoadGeneration), let lastError else {
      return
    }
    errorMessage = BridgeServiceErrorMessage.message(lastError)
  }

  @discardableResult
  private func applyAuthoritativePage(_ page: IPCTaskConversationPage) -> Bool {
    guard page.taskID == taskID else { return false }
    if isTerminal, hasLoadedTerminalSnapshot, page.messages.isEmpty, !entries.isEmpty {
      return true
    }
    applyPage(page)
    if isTerminal {
      hasLoadedTerminalSnapshot = true
    }
    hasAppliedPage = true
    return true
  }

  @discardableResult
  private func applySubscriptionPage(_ page: IPCTaskConversationPage) -> Bool {
    guard page.taskID == taskID else { return false }
    guard !(isTerminal && hasLoadedTerminalSnapshot) else { return true }
    if hasRestoredPresentation, page.messages.isEmpty, !entries.isEmpty {
      hasRestoredPresentation = false
      return true
    }
    hasRestoredPresentation = false
    applyPage(page)
    return true
  }

  private func applyPage(_ page: IPCTaskConversationPage) {
    pushFlushTask?.cancel()
    pushFlushTask = nil
    pendingPushes.removeAll(keepingCapacity: false)
    pendingResyncPushes.removeAll(keepingCapacity: false)
    entries = page.messages.map { Entry($0, isFinal: $0.final) }
    canLoadEarlier = page.messages.count >= 200
    rebuildIndex()
    refreshStreamingState()
    requestAutoScroll()
  }

  private func isRequestValid(lifecycle: UInt64, load: UInt64) -> Bool {
    lifecycleGeneration == lifecycle && self.loadGeneration == load
  }

  private func invalidateLiveSubscription() {
    streamingTask?.cancel()
    streamingTask = nil
    resyncTask?.cancel()
    resyncTask = nil
    let subscriptionID = self.subscriptionID
    self.subscriptionID = -1
    guard subscriptionID >= 0 else { return }
    let client = self.client
    let taskID = self.taskID
    Task {
      try? await client.unsubscribeTaskConversation(
        taskID: taskID,
        subscriptionID: subscriptionID
      )
    }
  }

  private func enqueuePush(_ push: IPCTaskConversationPush) {
    if pendingPushes.count >= Self.maximumPendingPushes {
      pendingPushes.removeFirst()
      scheduleConversationResync()
    }
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
    var requiresResync = false

    for push in pushes {
      if let position = updatedIndex[push.key] {
        var entry = updatedEntries[position]
        if let fullContent = push.fullContent {
          entry.content = fullContent
        } else if let delta = push.delta, entry.content.count == push.baseContentLength {
          entry.content += delta
        } else if push.delta != nil {
          guard !entry.isFinal else { continue }
          deferPushForResync(push)
          requiresResync = true
          continue
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
        else {
          if push.delta != nil {
            deferPushForResync(push)
            requiresResync = true
          }
          continue
        }
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

    if requiresResync {
      scheduleConversationResync()
    }
    guard changed else { return }
    entries = updatedEntries
    index = updatedIndex
    refreshStreamingState()
    requestAutoScroll()
  }

  private func scheduleConversationResync() {
    guard resyncTask == nil, hasAppliedPage else { return }
    resyncTask = Task { [weak self] in
      for delay in Self.resyncRetryDelays {
        do {
          try await Task.sleep(for: delay)
          guard let self, !Task.isCancelled else { return }
          let page = try await self.client.taskConversation(
            IPCTaskConversationRequest(taskID: self.taskID, limit: 200)
          )
          guard !Task.isCancelled else { return }
          self.mergeResyncPage(page)
          let deferred = self.pendingResyncPushes
          self.pendingResyncPushes.removeAll(keepingCapacity: true)
          self.applyPushBatch(deferred)
          if self.pendingResyncPushes.isEmpty { break }
        } catch {
          continue
        }
      }
      self?.resyncTask = nil
    }
  }

  private func deferPushForResync(_ push: IPCTaskConversationPush) {
    if pendingResyncPushes.count >= Self.maximumPendingPushes {
      pendingResyncPushes.removeFirst()
    }
    pendingResyncPushes.append(push)
  }

  private func mergeResyncPage(_ page: IPCTaskConversationPage) {
    guard page.taskID == taskID else { return }
    var refreshedEntries = entries
    var refreshedIndex = index
    var changed = false

    for message in page.messages {
      if let position = refreshedIndex[message.key] {
        var entry = refreshedEntries[position]
        guard message.final || message.content.count > entry.content.count else {
          continue
        }
        if entry.content != message.content {
          entry.content = message.content
          changed = true
        }
        if entry.toolName != message.toolName, let toolName = message.toolName {
          entry.toolName = toolName
          changed = true
        }
        if entry.toolStatus != message.toolStatus, let toolStatus = message.toolStatus {
          entry.toolStatus = toolStatus
          changed = true
        }
        if entry.toolArguments != message.toolArguments, let toolArguments = message.toolArguments {
          entry.toolArguments = toolArguments
          changed = true
        }
        if message.final && !entry.isFinal {
          entry.isFinal = true
          changed = true
        }
        refreshedEntries[position] = entry
      } else {
        refreshedIndex[message.key] = refreshedEntries.count
        refreshedEntries.append(Entry(message, isFinal: message.final))
        changed = true
      }
    }

    guard changed else { return }
    entries = refreshedEntries
    index = refreshedIndex
    refreshStreamingState()
    requestAutoScroll()
  }

  private func rebuildIndex() {
    index.removeAll(keepingCapacity: true)
    for (position, entry) in entries.enumerated() {
      index[entry.key] = position
    }
  }

  private func requestAutoScroll() {
    guard autoScroll, let key = entries.last?.key else { return }
    scrollAnchor = key
    scrollRevision &+= 1
  }

  private func refreshStreamingState() {
    guard let entry = entries.last(where: { $0.role == "agent" && !$0.isFinal }) else {
      activity = .idle
      isStreaming = false
      return
    }
    switch entry.kind {
    case "reasoning": activity = .thinking
    case "tool_call": activity = .executing(entry.toolName)
    default: activity = .responding
    }
    isStreaming = true
  }
}

#if canImport(Combine)
  extension TaskConversationModel: ObservableObject {}
#endif
