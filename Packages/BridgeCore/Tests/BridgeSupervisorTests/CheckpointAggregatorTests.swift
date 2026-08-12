import XCTest

@testable import BridgeSupervisor

final class CheckpointAggregatorTests: XCTestCase {
  func testTriggerAggregationDeduplicatesWithinOneCheckpoint() {
    var aggregator = SupervisorCheckpointAggregator()

    XCTAssertEqual(
      aggregator.record(.init(sequence: 1, trigger: .planChanged)),
      .accepted(newTrigger: true)
    )
    XCTAssertEqual(
      aggregator.record(.init(sequence: 2, trigger: .planChanged)),
      .accepted(newTrigger: false)
    )
    XCTAssertEqual(
      aggregator.record(.init(sequence: 3, trigger: .commandFailed)),
      .accepted(newTrigger: true)
    )

    XCTAssertEqual(
      aggregator.drain(),
      SupervisorCheckpointTriggerBatch(
        sequence: 3,
        triggers: [.planChanged, .commandFailed]
      )
    )
    XCTAssertNil(aggregator.drain())
  }

  func testDuplicateAndOutOfOrderSignalsAreIgnored() {
    var aggregator = SupervisorCheckpointAggregator()
    _ = aggregator.record(.init(sequence: 5, trigger: .manual))

    XCTAssertEqual(
      aggregator.record(.init(sequence: 5, trigger: .policyConcern)),
      .ignoredDuplicate
    )
    XCTAssertEqual(
      aggregator.record(.init(sequence: 4, trigger: .policyConcern)),
      .ignoredOutOfOrder
    )
    XCTAssertEqual(
      aggregator.drain(),
      SupervisorCheckpointTriggerBatch(sequence: 5, triggers: [.manual])
    )
  }

  func testSameTriggerCanCreateANewCheckpointAfterDrain() {
    var aggregator = SupervisorCheckpointAggregator()
    _ = aggregator.record(.init(sequence: 1, trigger: .verificationFailed))
    XCTAssertNotNil(aggregator.drain())

    XCTAssertEqual(
      aggregator.record(.init(sequence: 2, trigger: .verificationFailed)),
      .accepted(newTrigger: true)
    )
    XCTAssertEqual(
      aggregator.drain(),
      SupervisorCheckpointTriggerBatch(sequence: 2, triggers: [.verificationFailed])
    )
  }

  func testOnlySemanticCheckpointTriggersExist() {
    XCTAssertEqual(SupervisorCheckpointTrigger.allCases.count, 10)
    XCTAssertFalse(
      SupervisorCheckpointTrigger.allCases.map(\.rawValue).contains("output_fragment")
    )
    XCTAssertFalse(
      SupervisorCheckpointTrigger.allCases.map(\.rawValue).contains("token")
    )
  }
}
