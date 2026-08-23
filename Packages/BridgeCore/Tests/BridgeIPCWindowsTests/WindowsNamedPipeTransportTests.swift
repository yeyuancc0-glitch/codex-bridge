import BridgePlatform
import XCTest

#if canImport(WinSDK)
  import BridgeIPCWindows
  import WinSDK

  final class WindowsNamedPipeTransportTests: XCTestCase {
    func testEchoTransactOverRealPipe() throws {
      try withEchoServer { path in
        let response = try Self.transactWithRetry(path: path, request: Data("ping".utf8))
        XCTAssertEqual(response, Data("ping".utf8))
      }
    }

    func testConcurrentClientsAreIndependent() async throws {
      try withEchoServer { path in
        await withTaskGroup(of: Void.self) { group in
          for index in 0..<4 {
            group.addTask {
              let request = Data("request-\(index)".utf8)
              let response = try Self.transactWithRetry(path: path, request: request)
              XCTAssertEqual(response, request)
            }
          }
        }
      }
    }

    func testOversizeDeclarationDropsConnection() throws {
      try withEchoServer { path in
        let connection = try Self.connectWithRetry(path: path)
        defer { connection.close() }
        var hostile = Data([0xFF, 0xFF, 0xFF, 0xFF])
        hostile.append(Data("payload that must never be read".utf8))
        try connection.send(hostile)
        // The server must drop us without echoing anything readable.
        XCTAssertThrowsError(try connection.receive())
      }
    }

    private static func transactWithRetry(path: String, request: Data) throws -> Data {
      for attempt in 0..<100 {
        do {
          return try WindowsNamedPipeClient.transact(path: path, request: request)
        } catch PipeTransportError.connectionFailed {
          if attempt == 99 { throw PipeTransportError.connectionFailed(-1) }
          Thread.sleep(forTimeInterval: 0.02)
        }
      }
      throw PipeTransportError.connectionFailed(-1)
    }

    private static func connectWithRetry(
      path: String
    ) throws -> WindowsNamedPipeClient.PipeConnection {
      for attempt in 0..<100 {
        do {
          return try WindowsNamedPipeClient.connect(path: path)
        } catch PipeTransportError.connectionFailed {
          if attempt == 99 { throw PipeTransportError.connectionFailed(-1) }
          Thread.sleep(forTimeInterval: 0.02)
        }
      }
      throw PipeTransportError.connectionFailed(-1)
    }

    private func withEchoServer(_ body: (String) throws -> Void) rethrows {
      let path = "\\\\.\\pipe\\org.codexbridge.test.\(Foundation.UUID().uuidString.lowercased())"
      let server = WindowsNamedPipeServer(path: path) { _, request in
        request
      }
      server.start()
      defer { server.stop() }
      try body(path)
    }
  }
#endif
