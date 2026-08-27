import Foundation
import XCTest

@testable import BridgeAntigravityCLI

final class AntigravityCLIProcessTransportTests: XCTestCase {
  func testManagedProcessRoundTripsOneStreamJSONFrame() async throws {
    let transport = try AntigravityCLIProcessTransport.launch(
      configuration: AntigravityCLIProcessConfiguration(
        argv: ["/bin/cat"],
        workingDirectory: FileManager.default.temporaryDirectory.path,
        environment: ["PATH": "/usr/bin:/bin"],
        maximumFrameBytes: 1_024,
        maximumStandardErrorBytes: 1_024,
        maximumLifetime: .seconds(5)
      )
    )
    addTeardownBlock { await transport.close() }

    let frame = Data(#"{"event":"user","message":{"content":"Inspect"}}"#.utf8)
    try await transport.send(frame)
    var iterator = transport.incoming.makeAsyncIterator()
    let echoed = try await iterator.next()

    XCTAssertEqual(echoed, frame)
    await transport.close()
  }

  func testManagedProcessReportsUnexpectedExit() async throws {
    let transport = try AntigravityCLIProcessTransport.launch(
      configuration: AntigravityCLIProcessConfiguration(
        argv: ["/usr/bin/false"],
        workingDirectory: FileManager.default.temporaryDirectory.path,
        environment: ["PATH": "/usr/bin:/bin"],
        maximumFrameBytes: 1_024,
        maximumStandardErrorBytes: 1_024,
        maximumLifetime: .seconds(5)
      )
    )
    addTeardownBlock { await transport.close() }
    var iterator = transport.incoming.makeAsyncIterator()

    do {
      _ = try await iterator.next()
      XCTFail("Expected an unexpected process exit")
    } catch {
      XCTAssertEqual(error as? AntigravityCLIError, .processExited(1))
    }
  }

  func testSendRejectsEmbeddedNewlineAndOversizedFrame() async throws {
    let transport = try AntigravityCLIProcessTransport.launch(
      configuration: AntigravityCLIProcessConfiguration(
        argv: ["/bin/cat"],
        workingDirectory: FileManager.default.temporaryDirectory.path,
        environment: ["PATH": "/usr/bin:/bin"],
        maximumFrameBytes: 8,
        maximumStandardErrorBytes: 1_024,
        maximumLifetime: .seconds(5)
      )
    )
    addTeardownBlock { await transport.close() }

    do {
      try await transport.send(Data("line\nbreak".utf8))
      XCTFail("Expected embedded newline to be rejected")
    } catch {
      XCTAssertEqual(error as? AntigravityCLIError, .oversizedFrame)
    }
    do {
      try await transport.send(Data(repeating: 0x78, count: 9))
      XCTFail("Expected oversized frame to be rejected")
    } catch {
      XCTAssertEqual(error as? AntigravityCLIError, .oversizedFrame)
    }
  }

  func testSendBackpressureTimesOutAndCloseStillCompletes() async throws {
    let transport = try AntigravityCLIProcessTransport.launch(
      configuration: AntigravityCLIProcessConfiguration(
        argv: ["/bin/sleep", "30"],
        workingDirectory: FileManager.default.temporaryDirectory.path,
        environment: ["PATH": "/usr/bin:/bin"],
        maximumFrameBytes: 1_048_576,
        maximumStandardErrorBytes: 1_024,
        maximumLifetime: .seconds(30),
        standardInputTimeout: .milliseconds(100)
      )
    )
    let started = ContinuousClock.now

    do {
      try await transport.send(Data(repeating: 0x78, count: 1_048_576))
      XCTFail("Expected stdin backpressure to close the transport")
    } catch {
      XCTAssertEqual(error as? AntigravityCLIError, .transportClosed)
    }
    await transport.close()

    XCTAssertLessThan(started.duration(to: .now), .seconds(5))
  }
}
