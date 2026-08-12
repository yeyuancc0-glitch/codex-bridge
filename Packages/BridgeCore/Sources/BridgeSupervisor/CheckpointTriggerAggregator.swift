import Foundation

public struct SupervisorCheckpointSignal: Codable, Equatable, Sendable {
  public let sequence: UInt64
  public let trigger: SupervisorCheckpointTrigger

  public init(sequence: UInt64, trigger: SupervisorCheckpointTrigger) {
    self.sequence = sequence
    self.trigger = trigger
  }
}

public enum SupervisorCheckpointSignalDisposition: Equatable, Sendable {
  case accepted(newTrigger: Bool)
  case ignoredDuplicate
  case ignoredOutOfOrder
}

public struct SupervisorCheckpointTriggerBatch: Equatable, Sendable {
  public let sequence: UInt64
  public let triggers: [SupervisorCheckpointTrigger]

  public init(sequence: UInt64, triggers: [SupervisorCheckpointTrigger]) {
    self.sequence = sequence
    self.triggers = triggers
  }
}

public struct SupervisorCheckpointAggregator: Sendable {
  public private(set) var lastObservedSequence: UInt64?
  private var pendingTriggers: Set<SupervisorCheckpointTrigger>

  public init() {
    lastObservedSequence = nil
    pendingTriggers = []
  }

  @discardableResult
  public mutating func record(_ signal: SupervisorCheckpointSignal)
    -> SupervisorCheckpointSignalDisposition
  {
    if let lastObservedSequence {
      if signal.sequence == lastObservedSequence {
        return .ignoredDuplicate
      }
      if signal.sequence < lastObservedSequence {
        return .ignoredOutOfOrder
      }
    }
    lastObservedSequence = signal.sequence
    let inserted = pendingTriggers.insert(signal.trigger).inserted
    return .accepted(newTrigger: inserted)
  }

  public mutating func drain() -> SupervisorCheckpointTriggerBatch? {
    guard let sequence = lastObservedSequence, !pendingTriggers.isEmpty else {
      return nil
    }
    let triggers = SupervisorCheckpointTrigger.allCases.filter(pendingTriggers.contains)
    pendingTriggers.removeAll(keepingCapacity: true)
    return SupervisorCheckpointTriggerBatch(sequence: sequence, triggers: triggers)
  }
}
