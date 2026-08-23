import BridgePlatform
import Foundation
import XCTest

#if canImport(WinSDK)
  @testable import BridgeIPCWindows
  import WinSDK

  final class WindowsNamedPipeTransportTests: XCTestCase {
    func testEchoTransactOverRealPipe() {
      let requests = RequestProbe()
      do {
        try withEchoServer(
          onRequest: { requests.record($0) },
          body: { path in
            let response = try Self.transactWithRetry(path: path, request: Data("ping".utf8))
            XCTAssertEqual(response, Data("ping".utf8))
          })
      } catch {
        XCTFail("echo failed after handler requests \(requests.values): \(error)")
      }
    }

    func testConcurrentClientsAreIndependent() throws {
      try withEchoServer { path in
        var connections: [WindowsNamedPipeClient.PipeConnection] = []
        defer {
          for connection in connections { connection.close() }
        }
        for _ in 0..<4 {
          connections.append(try Self.connectWithRetry(path: path))
        }
        for index in 0..<4 {
          try connections[index].send(Data("request-\(index)".utf8))
        }
        for index in 0..<4 {
          let response = try connections[index].receive()
          XCTAssertEqual(response, Data("request-\(index)".utf8))
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

    func testConnectionLimitRejectsExcessClient() throws {
      let path = Self.uniquePipePath()
      let server = WindowsNamedPipeServer(path: path, maximumConnections: 1) { _, request in
        request
      }
      server.start()
      defer { server.stop() }
      let first = try Self.connectWithRetry(path: path)
      defer { first.close() }
      let second = try Self.connectWithRetry(path: path)
      defer { second.close() }
      try second.send(Data("excess".utf8))
      XCTAssertThrowsError(try second.receive())
    }

    func testResponseDeadlineDropsStalledConnection() throws {
      let path = Self.uniquePipePath()
      let server = WindowsNamedPipeServer(path: path, responseTimeout: 0.05) { _, request in
        try? await Task.sleep(for: .seconds(1))
        return request
      }
      server.start()
      defer { server.stop() }
      let connection = try Self.connectWithRetry(path: path)
      defer { connection.close() }
      try connection.send(Data("stall".utf8))
      XCTAssertThrowsError(try connection.receive())
    }

    private static func transactWithRetry(path: String, request: Data) throws -> Data {
      let connection = try connectWithRetry(path: path)
      defer { connection.close() }
      try connection.send(request)
      return try connection.receive()
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

    private func withEchoServer(
      onRequest: @escaping @Sendable (Data) -> Void = { _ in },
      body: (String) throws -> Void
    ) rethrows {
      let path = Self.uniquePipePath()
      let server = WindowsNamedPipeServer(path: path) { _, request in
        onRequest(request)
        return request
      }
      server.start()
      defer { server.stop() }
      try body(path)
    }

    private static func uniquePipePath() -> String {
      "\\\\.\\pipe\\org.codexbridge.test.\(Foundation.UUID().uuidString.lowercased())"
    }

    private final class RequestProbe: @unchecked Sendable {
      private let lock = NSLock()
      private var requests: [Data] = []

      var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return requests.map { String(decoding: $0, as: UTF8.self) }
      }

      func record(_ request: Data) {
        lock.lock()
        requests.append(request)
        lock.unlock()
      }
    }

  }
#endif
