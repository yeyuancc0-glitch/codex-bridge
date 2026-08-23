import BridgePlatform
import Foundation
import XCTest

#if canImport(WinSDK)
  @testable import BridgeIPCWindows
  import WinSDK

  final class WindowsNamedPipeTransportTests: XCTestCase {
    func testEchoTransactOverRealPipe() throws {
      try withEchoServer { path in
        let response = try Self.transactWithRetry(path: path, request: Data("ping".utf8))
        XCTAssertEqual(response, Data("ping".utf8))
      }
    }

    func testConcurrentClientsAreIndependent() throws {
      try withEchoServer { path in
        let results = ConcurrentPipeResults()
        for index in 0..<4 {
          Thread.detachNewThread {
            let request = Data("request-\(index)".utf8)
            let result = Result {
              try Self.transactWithRetry(path: path, request: request)
            }
            results.record(result, for: index)
          }
        }
        XCTAssertTrue(results.waitForCount(4, timeout: 10))
        for index in 0..<4 {
          let result = try XCTUnwrap(results.result(for: index))
          XCTAssertEqual(try result.get(), Data("request-\(index)".utf8))
        }
      }
    }

    func testOversizeDeclarationDropsConnection() throws {
      try withEchoServer { path in
        let connection = try Self.connectWithRetry(path: path)
        defer { connection.close() }
        var hostile = Data([0xFF, 0xFF, 0xFF, 0xFF])
        hostile.append(Data("payload that must never be read".utf8))
        try connection.sendRawFrameForTesting(hostile)
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

    private final class ConcurrentPipeResults: @unchecked Sendable {
      private let condition = NSCondition()
      private var values: [Int: Result<Data, Error>] = [:]

      func record(_ result: Result<Data, Error>, for index: Int) {
        condition.lock()
        values[index] = result
        condition.broadcast()
        condition.unlock()
      }

      func waitForCount(_ count: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while values.count < count {
          if !condition.wait(until: deadline) { return values.count >= count }
        }
        return true
      }

      func result(for index: Int) -> Result<Data, Error>? {
        condition.lock()
        defer { condition.unlock() }
        return values[index]
      }
    }
  }
#endif
