#if canImport(WinSDK)
  import BridgeMCP
  import XCTest

  final class MCPHTTPWindowsTests: XCTestCase {
    func testBindsOnlyIPv4LoopbackAndReportsFixedPortConflict() async throws {
      let first = MCPHTTPListener(
        configuration: try MCPHTTPConfiguration(
          pathSecret: String(repeating: "A", count: 43)
        ),
        handler: { _ in .data(Data("ready".utf8)) }
      )
      let firstEndpoint = try await first.start()
      addTeardownBlock { await first.stop() }
      XCTAssertEqual(firstEndpoint.host, "127.0.0.1")
      XCTAssertGreaterThan(firstEndpoint.port, 0)

      let second = MCPHTTPListener(
        configuration: try MCPHTTPConfiguration(
          pathSecret: String(repeating: "B", count: 43),
          port: firstEndpoint.port
        ),
        handler: { _ in .data(Data("unexpected".utf8)) }
      )
      do {
        _ = try await second.start()
        await second.stop()
        XCTFail("A fixed Qwen loopback port conflict must fail explicitly")
      } catch {
        XCTAssertFalse(String(describing: error).isEmpty)
      }
    }
  }
#endif
