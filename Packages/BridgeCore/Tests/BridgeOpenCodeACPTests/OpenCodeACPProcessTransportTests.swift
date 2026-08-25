import Foundation
import XCTest

@testable import BridgeOpenCodeACP

final class OpenCodeACPProcessTransportTests: XCTestCase {
  func testManagedProcessRoundTripsOneNDJSONFrame() async throws {
    let transport = try OpenCodeACPProcessTransport.launch(
      configuration: OpenCodeACPProcessTransportConfiguration(
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

    let echoed = try await iterator.next()

    XCTAssertEqual(echoed, frame)
    await transport.close()
  }

  func testManagedProcessReportsUnexpectedExit() async throws {
    let transport = try OpenCodeACPProcessTransport.launch(
      configuration: OpenCodeACPProcessTransportConfiguration(
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
      XCTAssertEqual(error as? OpenCodeACPError, .processExited(1))
    }
  }
}
