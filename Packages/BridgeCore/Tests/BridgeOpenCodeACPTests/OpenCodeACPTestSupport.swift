import Foundation

@testable import BridgeOpenCodeACP

actor ScriptedACPTransport: OpenCodeACPTransport {
  typealias Handler =
    @Sendable (
      ACPWireMessage,
      ScriptedACPTransport
    ) async throws -> Void

  nonisolated let incoming: AsyncThrowingStream<Data, any Error>

  private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
  private var handler: Handler?
  private var sent: [ACPWireMessage] = []
  private var closed = false

  init(bufferLimit: Int = 256) {
    let pair = AsyncThrowingStream.makeStream(
      of: Data.self,
      throwing: (any Error).self,
      bufferingPolicy: .bufferingOldest(max(1, bufferLimit))
    )
    incoming = pair.stream
    continuation = pair.continuation
  }

  func setHandler(_ handler: @escaping Handler) {
    self.handler = handler
  }

  func send(_ frame: Data) async throws {
    guard !closed else { throw OpenCodeACPError.transportClosed }
    let message = try JSONDecoder().decode(ACPWireMessage.self, from: frame)
    sent.append(message)
    if let handler {
      try await handler(message, self)
    }
  }

  func emit(_ message: ACPWireMessage) throws {
    guard !closed else { throw OpenCodeACPError.transportClosed }
    let result = continuation.yield(try JSONEncoder().encode(message))
    if case .dropped = result {
      closed = true
      continuation.finish(throwing: OpenCodeACPError.transportClosed)
      throw OpenCodeACPError.transportClosed
    }
  }

  func finish(throwing error: (any Error)? = nil) {
    guard !closed else { return }
    closed = true
    if let error {
      continuation.finish(throwing: error)
    } else {
      continuation.finish()
    }
  }

  func sentMessages() -> [ACPWireMessage] {
    sent
  }

  func close() async {
    finish()
  }
}

actor ACPPromptScenarioState {
  private var promptRequestID: ACPRequestID?
  private var permissionReply: ACPWireMessage?

  func setPromptRequestID(_ id: ACPRequestID) {
    promptRequestID = id
  }

  func takePromptRequestID() -> ACPRequestID? {
    defer { promptRequestID = nil }
    return promptRequestID
  }

  func setPermissionReply(_ message: ACPWireMessage) {
    permissionReply = message
  }

  func permissionReplyValue() -> ACPWireMessage? {
    permissionReply
  }
}

final class LockedValue<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: Value?

  func set(_ value: Value) {
    lock.withLock { storage = value }
  }

  func get() -> Value? {
    lock.withLock { storage }
  }
}
