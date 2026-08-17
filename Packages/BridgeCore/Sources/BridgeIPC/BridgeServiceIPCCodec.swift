import Foundation

public enum BridgeServiceIPCCodecError: Error, Equatable, Sendable {
  case messageTooLarge
  case invalidMessage
  case unsupportedSchemaVersion(Int)
  case requestMismatch
  case remoteError(BridgeServiceIPCError)
  case missingPayload
}

public enum BridgeServiceIPCCodec {
  public static func request<Payload: Encodable>(
    operation: BridgeServiceIPCOperation,
    payload: Payload?,
    requestID: String = UUID().uuidString.lowercased()
  ) throws -> Data {
    try validateIdentifier(requestID)
    let encodedPayload: Data?
    if let payload {
      encodedPayload = try encodePayload(payload)
    } else {
      encodedPayload = nil
    }
    return try encode(
      BridgeServiceIPCRequest(
        requestID: requestID,
        operation: operation,
        payload: encodedPayload
      )
    )
  }

  public static func emptyRequest(
    operation: BridgeServiceIPCOperation,
    requestID: String = UUID().uuidString.lowercased()
  ) throws -> Data {
    try request(operation: operation, payload: Optional<EmptyPayload>.none, requestID: requestID)
  }

  public static func decodeRequest(_ data: Data) throws -> BridgeServiceIPCRequest {
    let request: BridgeServiceIPCRequest = try decode(data)
    guard request.schemaVersion == BridgeServiceIPC.schemaVersion else {
      throw BridgeServiceIPCCodecError.unsupportedSchemaVersion(request.schemaVersion)
    }
    try validateIdentifier(request.requestID)
    if let payload = request.payload, payload.count > BridgeServiceIPC.maximumMessageBytes {
      throw BridgeServiceIPCCodecError.messageTooLarge
    }
    return request
  }

  public static func payload<Payload: Decodable>(
    _ type: Payload.Type,
    from request: BridgeServiceIPCRequest
  ) throws -> Payload {
    guard let payload = request.payload else { throw BridgeServiceIPCCodecError.missingPayload }
    return try decode(payload)
  }

  public static func optionalPayload<Payload: Decodable>(
    _ type: Payload.Type,
    from request: BridgeServiceIPCRequest
  ) throws -> Payload? {
    guard let payload = request.payload else { return nil }
    return try decode(payload)
  }

  public static func success<Payload: Encodable>(
    requestID: String,
    payload: Payload
  ) throws -> Data {
    try encode(
      BridgeServiceIPCResponse(
        requestID: requestID,
        payload: try encodePayload(payload)
      )
    )
  }

  public static func emptySuccess(requestID: String) throws -> Data {
    try success(requestID: requestID, payload: IPCMutationResponse())
  }

  public static func failure(
    requestID: String,
    error: BridgeServiceIPCError
  ) throws -> Data {
    try encode(BridgeServiceIPCResponse(requestID: requestID, error: error))
  }

  public static func decodeResponse<Payload: Decodable>(
    _ type: Payload.Type,
    data: Data,
    requestID: String
  ) throws -> Payload {
    let response: BridgeServiceIPCResponse = try decode(data)
    guard response.schemaVersion == BridgeServiceIPC.schemaVersion else {
      throw BridgeServiceIPCCodecError.unsupportedSchemaVersion(response.schemaVersion)
    }
    guard response.requestID == requestID else {
      throw BridgeServiceIPCCodecError.requestMismatch
    }
    if let error = response.error {
      throw BridgeServiceIPCCodecError.remoteError(error)
    }
    guard let payload = response.payload else {
      throw BridgeServiceIPCCodecError.missingPayload
    }
    return try decode(payload)
  }

  public static func response(_ data: Data) throws -> BridgeServiceIPCResponse {
    let response: BridgeServiceIPCResponse = try decode(data)
    guard response.schemaVersion == BridgeServiceIPC.schemaVersion else {
      throw BridgeServiceIPCCodecError.unsupportedSchemaVersion(response.schemaVersion)
    }
    return response
  }

  private static func encodePayload<Payload: Encodable>(_ payload: Payload) throws -> Data {
    try encode(payload)
  }

  private static func encode<Value: Encodable>(_ value: Value) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(value), data.count <= BridgeServiceIPC.maximumMessageBytes
    else {
      throw BridgeServiceIPCCodecError.messageTooLarge
    }
    return data
  }

  private static func decode<Value: Decodable>(_ data: Data) throws -> Value {
    guard !data.isEmpty, data.count <= BridgeServiceIPC.maximumMessageBytes else {
      throw BridgeServiceIPCCodecError.messageTooLarge
    }
    do {
      return try JSONDecoder().decode(Value.self, from: data)
    } catch let error as BridgeServiceIPCCodecError {
      throw error
    } catch {
      throw BridgeServiceIPCCodecError.invalidMessage
    }
  }

  private static func validateIdentifier(_ value: String) throws {
    guard !value.isEmpty,
      value == value.trimmingCharacters(in: .whitespacesAndNewlines),
      value.utf8.count <= 128,
      !value.contains("\0"),
      value.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw BridgeServiceIPCCodecError.invalidMessage
    }
  }

  private struct EmptyPayload: Codable {}
}
