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
  return ACPWireMessage(
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

func deepSeekSessionResult(
  id: ACPRequestID,
  sessionID: String = "deepseek-session",
  configOptions: [ACPJSONValue]? = nil
)
  -> ACPWireMessage
{
  var result: [String: ACPJSONValue] = ["sessionId": .string(sessionID)]
  if let configOptions { result["configOptions"] = .array(configOptions) }
  return ACPWireMessage(
    id: id,
    result: .object(result)
  )
}

func deepSeekModelConfigOptions(
  currentModel: String = "deepseek-v4-pro",
  currentEffort: String = "high"
) -> [ACPJSONValue] {
  [
    .object([
      "id": .string("model"),
      "category": .string("model"),
      "currentValue": .string(currentModel),
      "options": .array([
        .object(["value": .string("deepseek-v4-pro"), "name": .string("DeepSeek V4 Pro")]),
        .object(["value": .string("gateway-new"), "name": .string("Gateway New")]),
      ]),
    ]),
    .object([
      "id": .string("effort"),
      "category": .string("thought_level"),
      "currentValue": .string(currentEffort),
      "options": .array([
        .object(["value": .string("off"), "name": .string("Off")]),
        .object(["value": .string("high"), "name": .string("High")]),
      ]),
    ]),
  ]
}

func deepSeekMessageChunk(sessionID: String, text: String) -> ACPWireMessage {
  return ACPWireMessage(
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
  rawInput: ACPJSONValue? = nil,
  options: [(String, String)] = [("allow-once", "allow_once"), ("reject-once", "reject_once")]
) -> ACPWireMessage {
  var toolCall: [String: ACPJSONValue] = ["toolCallId": .string(toolCallID)]
  toolCall["rawInput"] = rawInput
  return ACPWireMessage(
    id: requestID,
    method: "session/request_permission",
    params: .object([
      "sessionId": .string(sessionID),
      "toolCall": .object(toolCall),
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
