public struct TaskConversationPresentationSnapshot {
  public   let entries: [TaskConversationModel.Entry]
  public   let canLoadEarlier: Bool
}

public struct TaskConversationPresentationCache {
  public init() {}
  private static let maximumTaskCount = 8
  private static let maximumEntryCount = 400
  private static let maximumSnapshotBytes = 2 * 1_024 * 1_024

  private var snapshots: [String: TaskConversationPresentationSnapshot] = [:]
  private var recency: [String] = []

  public mutating func snapshot(for taskID: String) -> TaskConversationPresentationSnapshot? {
    guard let snapshot = snapshots[taskID] else { return nil }
    touch(taskID)
    return snapshot
  }

  public mutating func store(
    _ snapshot: TaskConversationPresentationSnapshot?,
    for taskID: String
  ) {
    guard let snapshot, !snapshot.entries.isEmpty else { return }
    let entries = Self.boundedEntries(snapshot.entries)
    snapshots[taskID] = TaskConversationPresentationSnapshot(
      entries: entries,
      canLoadEarlier: snapshot.canLoadEarlier || entries.count < snapshot.entries.count
    )
    touch(taskID)
    while recency.count > Self.maximumTaskCount {
      snapshots.removeValue(forKey: recency.removeFirst())
    }
  }

  public mutating func removeAll() {
    snapshots.removeAll(keepingCapacity: false)
    recency.removeAll(keepingCapacity: false)
  }

  private mutating func touch(_ taskID: String) {
    recency.removeAll(where: { $0 == taskID })
    recency.append(taskID)
  }

  private static func boundedEntries(
    _ entries: [TaskConversationModel.Entry]
  ) -> [TaskConversationModel.Entry] {
    var retained: [TaskConversationModel.Entry] = []
    var retainedBytes = 0
    for entry in entries.reversed() {
      let entryBytes = presentationBytes(entry)
      let exceedsLimit = retainedBytes + entryBytes > maximumSnapshotBytes
      if !retained.isEmpty && (retained.count >= maximumEntryCount || exceedsLimit) {
        break
      }
      retained.append(entry)
      retainedBytes += entryBytes
    }
    return retained.reversed()
  }

  private static func presentationBytes(_ entry: TaskConversationModel.Entry) -> Int {
    entry.content.utf8.count
      + (entry.toolName?.utf8.count ?? 0)
      + (entry.toolStatus?.utf8.count ?? 0)
      + (entry.toolArguments?.utf8.count ?? 0)
  }
}
