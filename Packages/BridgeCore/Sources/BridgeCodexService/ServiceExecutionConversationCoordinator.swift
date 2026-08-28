import BridgeDomain
import BridgeServiceCore
import Foundation

actor ServiceExecutionConversationCoordinator {
  private let tasks: ServiceTaskManager
  private let conversation: TaskConversationBuffer

  init(
    tasks: ServiceTaskManager,
    conversation: TaskConversationBuffer
  ) {
    self.tasks = tasks
    self.conversation = conversation
  }

  func subscribe(
    taskID: TaskID,
    limit: Int
  ) async throws -> ConversationSubscription {
    guard let task = try await tasks.task(id: taskID) else {
      throw ServiceStoreError.unknownTask(taskID)
    }
    let inMemory = await conversation.entries(taskID: taskID)
    let persistedLimit = inMemory.count >= limit ? 0 : max(1, limit - inMemory.count)
    let persisted = try await tasks.messages(taskID: taskID, limit: persistedLimit)
    let memoryKeys = Set(inMemory.map(\.key))
    var page =
      persisted
      .filter { !memoryKeys.contains($0.key) }
      .map {
        TaskConversationBuffer.Entry(
          key: $0.key,
          role: $0.role,
          kind: $0.kind,
          content: $0.content,
          toolName: $0.toolName,
          toolStatus: $0.toolStatus,
          toolArguments: $0.toolArguments,
          isFinal: $0.isFinal(for: task.state.status)
        )
      }
    page.append(contentsOf: inMemory)
    let subscription = await conversation.subscribe(taskID: taskID)
    let merged =
      subscription.page.isEmpty
      ? page
      : page.filter { entry in
        !subscription.page.contains(where: { $0.key == entry.key })
      } + subscription.page
    return ConversationSubscription(
      subscriptionID: subscription.subscriptionID,
      page: Array(merged.suffix(limit)),
      updates: subscription.updates
    )
  }

  func unsubscribe(taskID: TaskID, subscriptionID: Int) async {
    await conversation.unsubscribe(taskID: taskID, subscriptionID: subscriptionID)
  }

  func page(
    taskID: TaskID,
    beforeMessageID: Int64?,
    limit: Int
  ) async throws -> [ServiceTaskMessageRecord] {
    guard try await tasks.task(id: taskID) != nil else {
      throw ServiceStoreError.unknownTask(taskID)
    }
    return try await tasks.messages(
      taskID: taskID,
      beforeMessageID: beforeMessageID,
      limit: limit
    )
  }

  func liveEntries(taskID: TaskID) async throws -> [TaskConversationBuffer.Entry] {
    guard try await tasks.task(id: taskID) != nil else {
      throw ServiceStoreError.unknownTask(taskID)
    }
    return await conversation.entries(taskID: taskID)
  }

  func purge(taskID: TaskID) async {
    await conversation.purge(taskID: taskID)
  }
}
