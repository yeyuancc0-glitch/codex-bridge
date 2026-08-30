import Foundation

public enum ACPError: Error, Equatable, Sendable {
  case invalidMessage
  case malformedResponse
  case remote(code: Int, message: String)
  case requestTimedOut
  case transportClosed
  case processExited(Int32?)
  case oversizedFrame
}

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

public enum ACPIncomingMessage: Equatable, Sendable {
  case serverRequest(id: ACPRequestID, method: String, params: ACPJSONValue?)
  case response(id: ACPRequestID, result: ACPJSONValue?, error: ACPWireError?)
  case notification(method: String, params: ACPJSONValue?)
}

public enum ACPMessageDispatcher {
  public static func dispatch(_ message: ACPWireMessage) throws -> ACPIncomingMessage {
    guard message.jsonrpc == "2.0" else { throw ACPError.invalidMessage }

    if let id = message.id, let method = message.method {
      guard message.result == nil, message.error == nil,
        isValidRequestID(id), isValidMethod(method)
      else { throw ACPError.invalidMessage }
      return .serverRequest(id: id, method: method, params: message.params)
    }

    if let id = message.id {
      guard message.method == nil, isValidRequestID(id),
        (message.result != nil) != (message.error != nil)
      else { throw ACPError.invalidMessage }
      return .response(id: id, result: message.result, error: message.error)
    }

    if let method = message.method {
      guard message.result == nil, message.error == nil, isValidMethod(method)
      else { throw ACPError.invalidMessage }
      return .notification(method: method, params: message.params)
    }

    throw ACPError.invalidMessage
  }

  public static func isValidRequestID(_ id: ACPRequestID) -> Bool {
    switch id {
    case .integer:
      true
    case .string(let value):
      !value.isEmpty && value.utf8.count <= 256 && !value.contains("\0")
    }
  }

  public static func isValidMethod(_ method: String) -> Bool {
    !method.isEmpty && method.utf8.count <= 256 && !method.contains("\0")
  }
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
      guard frame.count <= maximumFrameBytes else { throw ACPError.oversizedFrame }
      frames.append(frame)
    }

    guard buffer.count <= maximumFrameBytes else { throw ACPError.oversizedFrame }
    return frames
  }

  public mutating func finish() throws -> [Data] {
    guard !buffer.isEmpty else { return [] }
    var frame = buffer
    buffer.removeAll(keepingCapacity: false)
    if frame.last == 0x0D { frame.removeLast() }
    guard frame.count <= maximumFrameBytes else { throw ACPError.oversizedFrame }
    return frame.isEmpty ? [] : [frame]
  }
}
