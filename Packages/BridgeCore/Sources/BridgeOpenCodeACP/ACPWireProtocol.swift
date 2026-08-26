import BridgeAgentCore
import Foundation

public struct ACPWireError: Codable, Equatable, Sendable {
  public let code: Int
  public let message: String
  public let data: ACPJSONValue?

  public init(code: Int, message: String, data: ACPJSONValue? = nil) {
    self.code = code
    self.message = message
    self.data = data
  }
}

public struct ACPWireMessage: Codable, Equatable, Sendable {
  public let jsonrpc: String
  public let id: ACPRequestID?
  public let method: String?
  public let params: ACPJSONValue?
  public let result: ACPJSONValue?
  public let error: ACPWireError?

  public init(
    id: ACPRequestID? = nil,
    method: String? = nil,
    params: ACPJSONValue? = nil,
    result: ACPJSONValue? = nil,
    error: ACPWireError? = nil
  ) {
    jsonrpc = "2.0"
    self.id = id
    self.method = method
    self.params = params
    self.result = result
    self.error = error
  }

  private enum CodingKeys: String, CodingKey {
    case jsonrpc
    case id
    case method
    case params
    case result
    case error
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    jsonrpc = try container.decode(String.self, forKey: .jsonrpc)
    id = try container.decodeIfPresent(ACPRequestID.self, forKey: .id)
    method = try container.decodeIfPresent(String.self, forKey: .method)
    params = try container.decodeIfPresent(ACPJSONValue.self, forKey: .params)
    result =
      container.contains(.result)
      ? try container.decodeIfPresent(ACPJSONValue.self, forKey: .result) ?? .null
      : nil
    error = try container.decodeIfPresent(ACPWireError.self, forKey: .error)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(jsonrpc, forKey: .jsonrpc)
    try container.encodeIfPresent(id, forKey: .id)
    try container.encodeIfPresent(method, forKey: .method)
    try container.encodeIfPresent(params, forKey: .params)
    try container.encodeIfPresent(result, forKey: .result)
    try container.encodeIfPresent(error, forKey: .error)
  }
}

public struct OpenCodeACPNotification: Equatable, Sendable {
  public let method: String
  public let params: ACPJSONValue?

  public init(method: String, params: ACPJSONValue?) {
    self.method = method
    self.params = params
  }
}

public struct OpenCodeACPPermissionRequest: Equatable, Sendable {
  public let approvalID: String
  public let requestID: ACPRequestID
  public let sessionID: String
  public let toolCallID: String
  public let title: String
  public let kind: String?
  public let rawInput: ACPJSONValue?
  public let options: [AgentApprovalOption]

  public init(
    approvalID: String? = nil,
    requestID: ACPRequestID,
    sessionID: String,
    toolCallID: String,
    title: String,
    kind: String?,
    rawInput: ACPJSONValue?,
    options: [AgentApprovalOption]
  ) {
    self.approvalID = approvalID ?? "opencode-\(UUID().uuidString.lowercased())"
    self.requestID = requestID
    self.sessionID = sessionID
    self.toolCallID = toolCallID
    self.title = title
    self.kind = kind
    self.rawInput = rawInput
    self.options = options
  }
}

public enum OpenCodeACPClientEvent: Equatable, Sendable {
  case notification(OpenCodeACPNotification)
  case permissionRequested(OpenCodeACPPermissionRequest)
}
public struct OpenCodeACPClientEventEnvelope: Equatable, Sendable {
  public let sequence: Int64
  public let event: OpenCodeACPClientEvent

  public init(sequence: Int64, event: OpenCodeACPClientEvent) {
    self.sequence = sequence
    self.event = event
  }
}

public enum OpenCodeACPError: Error, Equatable, Sendable {
  case notInitialized
  case operationInProgress
  case invalidMessage
  case malformedResponse
  case remote(code: Int, message: String)
  case requestTimedOut
  case transportClosed
  case processExited(Int32?)
  case oversizedFrame
  case sessionMismatch
  case unsupportedProtocol(Int)
}

public struct ACPLineDecoder: Sendable {
  public let maximumFrameBytes: Int
  private var buffer = Data()

  public init(maximumFrameBytes: Int = 1_048_576) {
    self.maximumFrameBytes = max(1, maximumFrameBytes)
  }

  public mutating func append(_ data: Data) throws -> [Data] {
    guard !data.isEmpty else { return [] }
    buffer.append(data)
    var frames: [Data] = []

    while let newline = buffer.firstIndex(of: 0x0A) {
      var frame = Data(buffer[..<newline])
      buffer.removeSubrange(...newline)
      if frame.last == 0x0D { frame.removeLast() }
      if frame.isEmpty { continue }
      guard frame.count <= maximumFrameBytes else { throw OpenCodeACPError.oversizedFrame }
      frames.append(frame)
    }

    guard buffer.count <= maximumFrameBytes else { throw OpenCodeACPError.oversizedFrame }
    return frames
  }

  public mutating func finish() throws -> [Data] {
    guard !buffer.isEmpty else { return [] }
    var frame = buffer
    buffer.removeAll(keepingCapacity: false)
    if frame.last == 0x0D { frame.removeLast() }
    guard frame.count <= maximumFrameBytes else { throw OpenCodeACPError.oversizedFrame }
    return frame.isEmpty ? [] : [frame]
  }
}
