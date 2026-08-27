import Foundation
import XCTest

@testable import BridgeACP

final class ACPProcessTransportTests: XCTestCase {
  func testManagedProcessRoundTripsOneNDJSONFrame() async throws {
    let transport = try ACPProcessTransport.launch(
      configuration: ACPProcessTransportConfiguration(
        argv: ["/bin/cat"],
        workingDirectory: FileManager.default.temporaryDirectory.path,
        environment: ["PATH": "/usr/bin:/bin"],
        maximumLifetime: .seconds(5)
      )
    )
    addTeardownBlock { await transport.close() }

    let frame = Data("{\"jsonrpc\":\"2.0\",\"method\":\"test\"}".utf8)
    try await transport.send(frame)
    var iterator = transport.incoming.makeAsyncIterator()

    let received = try await iterator.next()
    XCTAssertEqual(received, frame)
    await transport.close()
  }

  func testManagedProcessReportsUnexpectedExit() async throws {
    let transport = try ACPProcessTransport.launch(
      configuration: ACPProcessTransportConfiguration(
        argv: ["/usr/bin/false"],
        workingDirectory: FileManager.default.temporaryDirectory.path,
        environment: ["PATH": "/usr/bin:/bin"],
        maximumLifetime: .seconds(5)
      )
    )
    addTeardownBlock { await transport.close() }
    var iterator = transport.incoming.makeAsyncIterator()

    do {
      _ = try await iterator.next()
      XCTFail("Expected the process exit to terminate the transport with an error")
    } catch {
      XCTAssertEqual(error as? ACPError, .processExited(1))
    }
  }

  func testCloseAllowsProcessToFlushOutputAfterInputEOF() async throws {
    let transport = try ACPProcessTransport.launch(
      configuration: ACPProcessTransportConfiguration(
        argv: [
          "/bin/sh",
          "-c",
          "read value; sleep 0.05; printf '{\"flushed\":true}\\n'",
        ],
        workingDirectory: FileManager.default.temporaryDirectory.path,
        environment: ["PATH": "/usr/bin:/bin"],
        maximumLifetime: .seconds(5),
        inputEOFGracePeriod: .seconds(1)
      )
    )
    addTeardownBlock { await transport.close() }

    try await transport.send(Data("input".utf8))
    await transport.close()
    var iterator = transport.incoming.makeAsyncIterator()

    let received = try await iterator.next()
    XCTAssertEqual(received, Data("{\"flushed\":true}".utf8))
    let end = try await iterator.next()
    XCTAssertNil(end)
  }
}
