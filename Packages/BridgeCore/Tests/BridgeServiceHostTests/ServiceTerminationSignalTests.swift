import Darwin
import XCTest

@testable import BridgeServiceHost

final class ServiceTerminationSignalTests: XCTestCase {
  func testCancellationResumesWait() async {
    let completed = expectation(description: "cancelled termination wait completed")
    let waiter = Task {
      await ServiceTerminationSignal.wait(for: [SIGUSR1])
      completed.fulfill()
    }

    try? await Task.sleep(for: .milliseconds(20))
    waiter.cancel()

    await fulfillment(of: [completed], timeout: 1)
  }

  func testSignalResumesWaitAndAReleasedWaitCanBeReplaced() async {
    let firstCompleted = expectation(description: "first signal wait completed")
    let firstWaiter = Task {
      await ServiceTerminationSignal.wait(for: [SIGUSR1])
      firstCompleted.fulfill()
    }

    try? await Task.sleep(for: .milliseconds(20))
    XCTAssertEqual(Darwin.raise(SIGUSR1), 0)
    await fulfillment(of: [firstCompleted], timeout: 1)

    let secondCompleted = expectation(description: "second signal wait completed")
    let secondWaiter = Task {
      await ServiceTerminationSignal.wait(for: [SIGUSR1])
      secondCompleted.fulfill()
    }

    try? await Task.sleep(for: .milliseconds(20))
    XCTAssertEqual(Darwin.raise(SIGUSR1), 0)
    await fulfillment(of: [secondCompleted], timeout: 1)

    firstWaiter.cancel()
    secondWaiter.cancel()
  }
}
