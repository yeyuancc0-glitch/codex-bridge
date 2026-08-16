import BridgeDomain
import BridgeSupervisor
import Foundation
import XCTest

@testable import BridgePipeline

/// Completes the "continuous checkpoint projection" acceptance criteria from
/// docs/FOLLOW_UP_PLAN.md section 8:
///   "有界投影、游标、重启重放和 UI loading/unknown 状态"
///
/// The durable cursor is `DurableSupervisionLedger.checkpoints(for:after:limit:)`.
/// Existing tests verify checkpoint capacity/limit rejection and single-record
/// reopen. These tests add the remaining evidence:
///   - cursor pagination never exceeds the requested bound and replays in order;
///   - a multi-checkpoint history survives reopen without loss or reordering,
///     so callers replay from a persisted cursor instead of guessing state.
final class SupervisionCheckpointProjectionTests: XCTestCase {
  func testCheckpointCursorPaginationIsBoundedAndReplaysInOrder() async throws {
    let ledger = try DurableSupervisionLedger.inMemory()
    let scope = try makeScope()
    _ = try await ledger.begin(scope: scope, configuration: configuration())
    for sequence in 1...7 {
      _ = try await ledger.appendCheckpoint(
        scope: scope,
        checkpoint: makeCheckpoint(
          scope: scope,
          sequence: UInt64(sequence),
          triggers: [.manual]
        )
      )
    }

    let firstPage = try await ledger.checkpoints(for: scope, after: 0, limit: 3)
    let secondPage = try await ledger.checkpoints(for: scope, after: 3, limit: 3)
    let lastPage = try await ledger.checkpoints(for: scope, after: 6, limit: 3)
    let emptyPage = try await ledger.checkpoints(for: scope, after: 7, limit: 3)

    XCTAssertEqual(firstPage.map(\.checkpoint.sequence), [1, 2, 3])
    XCTAssertEqual(secondPage.map(\.checkpoint.sequence), [4, 5, 6])
    XCTAssertEqual(lastPage.map(\.checkpoint.sequence), [7])
    XCTAssertTrue(emptyPage.isEmpty)

    do {
      _ = try await ledger.checkpoints(for: scope, limit: 0)
      XCTFail("Expected zero limit rejection")
    } catch {
      XCTAssertEqual(error as? DurableSupervisionLedgerError, .invalidArgument("limit"))
    }
    do {
      _ = try await ledger.checkpoints(
        for: scope,
        limit: DurableSupervisionLedger.maximumQueryLimit + 1
      )
      XCTFail("Expected over-limit rejection")
    } catch {
      XCTAssertEqual(error as? DurableSupervisionLedgerError, .invalidArgument("limit"))
    }
  }

  func testMultiCheckpointProjectionSurvivesRestartWithoutLossOrReordering() async throws {
    let location = try temporaryDatabase()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let scope = try makeScope()
    let ledger = try DurableSupervisionLedger(path: location.database.path)
    _ = try await ledger.begin(scope: scope, configuration: configuration())
    for sequence in 1...5 {
      _ = try await ledger.appendCheckpoint(
        scope: scope,
        checkpoint: makeCheckpoint(scope: scope, sequence: UInt64(sequence))
      )
    }

    let reopened = try DurableSupervisionLedger(path: location.database.path)
    var replayed: [UInt64] = []
    var cursor: UInt64 = 0
    while true {
      let page = try await reopened.checkpoints(for: scope, after: cursor, limit: 2)
      guard let last = page.last else { break }
      replayed.append(contentsOf: page.map(\.checkpoint.sequence))
      cursor = last.checkpoint.sequence
    }

    XCTAssertEqual(replayed, [1, 2, 3, 4, 5])
    let summary = try await reopened.evidenceSummary(for: scope)
    XCTAssertEqual(summary.checkpointCount, 5)
    XCTAssertEqual(summary.reviewCount, 0)
  }

  private func makeScope(
    taskID: String = "task-projection",
    turnID: String = "turn-projection",
    generation: Int64 = 1
  ) throws -> DurableSupervisionScope {
    try DurableSupervisionScope(
      taskID: TaskID(rawValue: taskID),
      projectID: ProjectID(rawValue: "project-projection"),
      threadID: ThreadID(rawValue: "thread-projection"),
      turnID: TurnID(rawValue: turnID),
      generation: generation
    )
  }

  private func configuration() -> SupervisorGuardConfiguration {
    SupervisorGuardConfiguration(
      deterministicFallbackAuthorized: false,
      maximumSteersPerTurn: 3,
      maximumSteersPerTask: 5
    )
  }

  private func makeCheckpoint(
    scope: DurableSupervisionScope,
    sequence: UInt64,
    triggers: [SupervisorCheckpointTrigger] = [.planChanged],
    stage: SupervisorCheckpointStage = .progress
  ) throws -> SupervisorCheckpoint {
    try SupervisorCheckpoint(
      sequence: sequence,
      taskID: scope.taskID.rawValue,
      turnID: scope.turnID.rawValue,
      stage: stage,
      triggers: triggers,
      content: SupervisorCheckpointContent(
        taskContract: "Replay the durable supervision ledger.",
        executionModel: "gpt-5.6",
        executionEffort: "medium",
        recentEvents: ["A bounded checkpoint was persisted."],
        remainingAutomaticSteers: 5
      )
    )
  }

  private func temporaryDatabase() throws -> (directory: URL, database: URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "bridge-supervision-projection-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return (directory, directory.appendingPathComponent("ledger.sqlite"))
  }
}
