import Foundation

public struct SupervisorReviewPosition: Codable, Equatable, Comparable, Sendable {
  public let checkpointSequence: UInt64
  public let attempt: UInt16

  public init(checkpointSequence: UInt64, attempt: UInt16) {
    self.checkpointSequence = checkpointSequence
    self.attempt = attempt
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    if lhs.checkpointSequence != rhs.checkpointSequence {
      return lhs.checkpointSequence < rhs.checkpointSequence
    }
    return lhs.attempt < rhs.attempt
  }
}

public enum SupervisorModelFailure: String, Codable, Equatable, Sendable {
  case rateLimited = "rate_limited"
  case processExited = "process_exited"
  case modelUnavailable = "model_unavailable"
  case transportFailed = "transport_failed"
}

public enum SupervisorReviewOutcome: Equatable, Sendable {
  case decision(
    position: SupervisorReviewPosition,
    checkpoint: SupervisorCheckpoint,
    decision: SupervisorDecision
  )
  case invalidJSON(position: SupervisorReviewPosition)
  case modelFailure(position: SupervisorReviewPosition, failure: SupervisorModelFailure)

  fileprivate var position: SupervisorReviewPosition {
    switch self {
    case .decision(let position, _, _), .invalidJSON(let position),
      .modelFailure(let position, _):
      position
    }
  }
}

public enum SupervisorSemanticStatus: String, Codable, Equatable, Sendable {
  case active
  case deterministicFallback = "deterministic_fallback"
  case pausedForHuman = "paused_for_human"
}

public enum SupervisorHumanReviewReason: Equatable, Sendable {
  case repeatedIssue(String)
  case turnSteerLimitReached(String)
  case taskSteerLimitReached
  case semanticSupervisionUnavailable
}

public enum SupervisorPauseReason: Equatable, Sendable {
  case supervisorDecision(String)
  case semanticSupervisionUnavailable
}

public enum SupervisorDegradationReason: Equatable, Sendable {
  case invalidJSONLimitReached
  case modelFailure(SupervisorModelFailure)
}

public enum SupervisorAction: Equatable, Sendable {
  case continueExecution
  case steer(String)
  case requestSuspend(SupervisorPauseReason)
  case interrupt(String)
  case finalAccepted
  case finalRejected(String)
  case retrySemanticReview
  case requireHumanReview(SupervisorHumanReviewReason)
  case continueDeterministically(SupervisorDegradationReason)
  case ignoredOutOfOrder
  case rejectedInvalidReview
  case semanticSupervisionUnavailable
}

public struct SupervisorGuardConfiguration: Codable, Equatable, Sendable {
  public let deterministicFallbackAuthorized: Bool
  public let maximumSteersPerTurn: Int
  public let maximumSteersPerTask: Int

  public init(
    deterministicFallbackAuthorized: Bool,
    maximumSteersPerTurn: Int = 3,
    maximumSteersPerTask: Int = 5
  ) {
    self.deterministicFallbackAuthorized = deterministicFallbackAuthorized
    self.maximumSteersPerTurn = min(max(maximumSteersPerTurn, 1), 3)
    self.maximumSteersPerTask = min(max(maximumSteersPerTask, 1), 5)
  }
}

public struct SupervisorGuardState: Codable, Equatable, Sendable {
  public fileprivate(set) var semanticStatus: SupervisorSemanticStatus
  public fileprivate(set) var lastReviewPosition: SupervisorReviewPosition?
  public fileprivate(set) var steersByTurn: [String: Int]
  public fileprivate(set) var taskSteerCount: Int
  public fileprivate(set) var consecutiveInvalidJSONCount: Int
  public fileprivate(set) var lastIssueID: String?
  public fileprivate(set) var consecutiveIssueCount: Int

  public init() {
    semanticStatus = .active
    lastReviewPosition = nil
    steersByTurn = [:]
    taskSteerCount = 0
    consecutiveInvalidJSONCount = 0
    lastIssueID = nil
    consecutiveIssueCount = 0
  }
}

public struct SupervisorReducer: Sendable {
  public private(set) var state: SupervisorGuardState
  public let configuration: SupervisorGuardConfiguration

  public init(
    configuration: SupervisorGuardConfiguration,
    state: SupervisorGuardState = SupervisorGuardState()
  ) {
    self.configuration = configuration
    self.state = state
  }

  public mutating func apply(_ outcome: SupervisorReviewOutcome) -> SupervisorAction {
    guard isNew(outcome.position) else {
      return .ignoredOutOfOrder
    }
    guard isConsistent(outcome) else {
      return .rejectedInvalidReview
    }
    state.lastReviewPosition = outcome.position
    guard state.semanticStatus == .active else {
      return .semanticSupervisionUnavailable
    }
    switch outcome {
    case .decision(_, let checkpoint, let decision):
      return applyDecision(decision, checkpoint: checkpoint)
    case .invalidJSON:
      return applyInvalidJSON()
    case .modelFailure(_, let failure):
      return degrade(after: .modelFailure(failure))
    }
  }

  public mutating func resumeSemanticSupervision() {
    state.semanticStatus = .active
    state.consecutiveInvalidJSONCount = 0
    resetIssueStreak()
  }

  private func isNew(_ position: SupervisorReviewPosition) -> Bool {
    guard let lastReviewPosition = state.lastReviewPosition else {
      return true
    }
    return lastReviewPosition < position
  }

  private func isConsistent(_ outcome: SupervisorReviewOutcome) -> Bool {
    guard case .decision(let position, let checkpoint, let decision) = outcome else {
      return true
    }
    return position.checkpointSequence == checkpoint.sequence
      && (decision.decision != .finalAccept || checkpoint.stage == .final)
  }

  private mutating func applyDecision(
    _ decision: SupervisorDecision,
    checkpoint: SupervisorCheckpoint
  ) -> SupervisorAction {
    state.consecutiveInvalidJSONCount = 0
    if let action = applyIssueStreak(for: decision) {
      return action
    }
    switch decision.decision {
    case .continue:
      return .continueExecution
    case .steer:
      return applySteer(decision, turnID: checkpoint.turnID)
    case .suspend:
      state.semanticStatus = .pausedForHuman
      return .requestSuspend(.supervisorDecision(decision.summary))
    case .interrupt:
      state.semanticStatus = .pausedForHuman
      return .interrupt(decision.summary)
    case .finalAccept:
      return .finalAccepted
    case .finalReject:
      return .finalRejected(decision.summary)
    }
  }

  private mutating func applyIssueStreak(for decision: SupervisorDecision) -> SupervisorAction? {
    guard let issueID = decision.issueID else {
      resetIssueStreak()
      return nil
    }
    if state.lastIssueID == issueID {
      state.consecutiveIssueCount += 1
    } else {
      state.lastIssueID = issueID
      state.consecutiveIssueCount = 1
    }
    guard state.consecutiveIssueCount >= 2 else {
      return nil
    }
    state.semanticStatus = .pausedForHuman
    return .requireHumanReview(.repeatedIssue(issueID))
  }

  private mutating func applySteer(
    _ decision: SupervisorDecision,
    turnID: String
  ) -> SupervisorAction {
    let turnCount = state.steersByTurn[turnID, default: 0]
    guard turnCount < configuration.maximumSteersPerTurn else {
      state.semanticStatus = .pausedForHuman
      return .requireHumanReview(.turnSteerLimitReached(turnID))
    }
    guard state.taskSteerCount < configuration.maximumSteersPerTask else {
      state.semanticStatus = .pausedForHuman
      return .requireHumanReview(.taskSteerLimitReached)
    }
    guard let instruction = decision.instruction else {
      return .rejectedInvalidReview
    }
    state.steersByTurn[turnID] = turnCount + 1
    state.taskSteerCount += 1
    return .steer(instruction)
  }

  private mutating func applyInvalidJSON() -> SupervisorAction {
    state.consecutiveInvalidJSONCount += 1
    guard state.consecutiveInvalidJSONCount >= 2 else {
      return .retrySemanticReview
    }
    return degrade(after: .invalidJSONLimitReached)
  }

  private mutating func degrade(after reason: SupervisorDegradationReason) -> SupervisorAction {
    resetIssueStreak()
    if configuration.deterministicFallbackAuthorized {
      state.semanticStatus = .deterministicFallback
      return .continueDeterministically(reason)
    }
    state.semanticStatus = .pausedForHuman
    return .requestSuspend(.semanticSupervisionUnavailable)
  }

  private mutating func resetIssueStreak() {
    state.lastIssueID = nil
    state.consecutiveIssueCount = 0
  }
}

public actor SupervisorGuard {
  private var reducer: SupervisorReducer

  public init(configuration: SupervisorGuardConfiguration) {
    reducer = SupervisorReducer(configuration: configuration)
  }

  public func apply(_ outcome: SupervisorReviewOutcome) -> SupervisorAction {
    reducer.apply(outcome)
  }

  public func snapshot() -> SupervisorGuardState {
    reducer.state
  }

  public func resumeSemanticSupervision() {
    reducer.resumeSemanticSupervision()
  }
}
