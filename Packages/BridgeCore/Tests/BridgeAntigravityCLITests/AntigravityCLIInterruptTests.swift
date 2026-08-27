import BridgeProcess
import Foundation
import XCTest

final class AntigravityCLIInterruptTests: XCTestCase {
  func testManagedProcessInterruptGroupReachesShellFixture() throws {
    let fixture = try AntigravityCLITestSupport.temporaryDirectory(prefix: "agy-sigint")
    let script = URL(fileURLWithPath: fixture, isDirectory: true)
      .appendingPathComponent("wait-for-sigint.sh").path
    defer { try? FileManager.default.removeItem(atPath: fixture) }
    try Data(
      """
      #!/bin/sh
      trap 'echo SIGINT; exit 42' INT
      echo READY
      while :; do sleep 1; done
      """.utf8
    ).write(to: URL(fileURLWithPath: script))
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: script
    )

    let output = BoundedProcessOutputCollector(maximumBytes: 1_024)
    let process = try ManagedStdioProcess(
      argv: ["/bin/sh", script],
      workingDirectory: fixture,
      environment: ["PATH": "/usr/bin:/bin"],
      mergeStandardError: false,
      onStandardOutput: { output.append($0) }
    )
    defer {
      _ = process.terminateAndWait(gracePeriod: .milliseconds(100), killWait: .seconds(1))
      process.drainRemainingOutput()
      process.close()
    }

    for _ in 0..<100 {
      if output.snapshot().tail.contains("READY") { break }
      Thread.sleep(forTimeInterval: 0.01)
    }
    XCTAssertTrue(output.snapshot().tail.contains("READY"))
    process.interruptGroup()
    let termination = process.waitForExit(timeout: .seconds(3))
    process.drainRemainingOutput()

    switch termination {
    case .exited(42):
      XCTAssertTrue(output.snapshot().tail.contains("SIGINT"))
    case .killed(let signal):
      XCTAssertEqual(signal, 2)
    default:
      XCTFail(
        "Expected SIGINT to terminate the process group, got \(String(describing: termination))")
    }
  }
}
