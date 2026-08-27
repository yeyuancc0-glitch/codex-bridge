import BridgeACP
import Foundation

@testable import BridgeDeepSeekHarnessACP

actor ScriptedDeepSeekHarnessTransport: ACPTransport {
  nonisolated let incoming: AsyncThrowingStream<Data, any Error>

  private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
  private var handler:
    (@Sendable (ACPWireMessage, ScriptedDeepSeekHarnessTransport) async throws -> Void)?
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

  func setHandler(
    _ handler:
      @escaping @Sendable (ACPWireMessage, ScriptedDeepSeekHarnessTransport) async throws -> Void
  ) {
    self.handler = handler
  }

  func send(_ frame: Data) async throws {
    guard !closed else { throw ACPError.transportClosed }
    let message = try JSONDecoder().decode(ACPWireMessage.self, from: frame)
    sent.append(message)
    try await handler?(message, self)
  }

  func emit(_ message: ACPWireMessage) throws {
    guard !closed else { throw ACPError.transportClosed }
    let result = continuation.yield(try JSONEncoder().encode(message))
    if case .dropped = result {
      closed = true
      continuation.finish(throwing: ACPError.transportClosed)
      throw ACPError.transportClosed
    }
  }

  func sentMessages() -> [ACPWireMessage] {
    sent
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

  func close() async {
    finish()
  }
}

func deepSeekInitializationResult(id: ACPRequestID) -> ACPWireMessage {
  ACPWireMessage(
    id: id,
    result: .object([
      "protocolVersion": .integer(1),
      "agentInfo": .object([
        "name": .string(DeepSeekHarnessACPConstants.agentName),
        "version": .string(DeepSeekHarnessACPConstants.agentVersion),
      ]),
    ])
  )
}

func deepSeekSessionResult(id: ACPRequestID, sessionID: String = "deepseek-session")
  -> ACPWireMessage
{
  ACPWireMessage(
    id: id,
    result: .object(["sessionId": .string(sessionID)])
  )
}

func deepSeekMessageChunk(sessionID: String, text: String) -> ACPWireMessage {
  ACPWireMessage(
    method: "session/update",
    params: .object([
      "sessionId": .string(sessionID),
      "update": .object([
        "sessionUpdate": .string("agent_message_chunk"),
        "content": .object([
          "type": .string("text"),
          "text": .string(text),
        ]),
      ]),
    ])
  )
}

func deepSeekPermissionRequest(
  sessionID: String,
  requestID: ACPRequestID = .string("permission-1"),
  toolCallID: String = "tool-1",
  options: [(String, String)] = [("allow-once", "allow_once"), ("reject-once", "reject_once")]
) -> ACPWireMessage {
  ACPWireMessage(
    id: requestID,
    method: "session/request_permission",
    params: .object([
      "sessionId": .string(sessionID),
      "toolCall": .object(["toolCallId": .string(toolCallID)]),
      "options": .array(
        options.map { optionID, kind in
          .object([
            "optionId": .string(optionID),
            "name": .string(optionID),
            "kind": .string(kind),
          ])
        }
      ),
    ])
  )
}
