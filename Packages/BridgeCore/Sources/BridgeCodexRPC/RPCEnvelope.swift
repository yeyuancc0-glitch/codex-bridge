import Foundation

public struct RPCNotification: Equatable, Sendable {
  public let method: String
  public let params: JSONValue?
  public let metadata: [String: JSONValue]

  public init(
    method: String,
    params: JSONValue?,
    metadata: [String: JSONValue] = [:]
  ) {
    self.method = method
    self.params = params
    self.metadata = metadata
  }
}

public struct RPCServerRequest: Equatable, Sendable {
  public let id: RequestID
  public let method: String
  public let params: JSONValue?
  public let metadata: [String: JSONValue]

  public init(
    id: RequestID,
    method: String,
    params: JSONValue?,
    metadata: [String: JSONValue] = [:]
  ) {
    self.id = id
    self.method = method
    self.params = params
    self.metadata = metadata
  }
}

public enum AppServerEvent: Equatable, Sendable {
  case notification(RPCNotification)
  case serverRequest(RPCServerRequest)
}

struct RPCErrorPayload: Equatable, Sendable {
  let code: Int64
  let message: String
  let data: JSONValue?
}

enum InboundRPCMessage: Equatable, Sendable {
  case response(id: RequestID, result: JSONValue)
  case error(id: RequestID, error: RPCErrorPayload)
  case notification(RPCNotification)
  case serverRequest(RPCServerRequest)
}

enum RPCEnvelope {
  static func decode(_ value: JSONValue) throws -> InboundRPCMessage {
    guard let object = value.objectValue else {
      throw CodexRPCError.malformedMessage("top-level JSON value is not an object")
    }

    if let methodValue = object["method"] {
      return try decodeMethodMessage(object, methodValue: methodValue)
    }
    return try decodeResponse(object)
  }

  static func request(
    id: RequestID,
    method: String,
    params: JSONValue?
  ) -> JSONValue {
    var object: [String: JSONValue] = [
      "id": id.jsonValue,
      "method": .string(method),
    ]
    if let params { object["params"] = params }
    return .object(object)
  }

  static func notification(method: String, params: JSONValue? = nil) -> JSONValue {
    var object: [String: JSONValue] = ["method": .string(method)]
    if let params { object["params"] = params }
    return .object(object)
  }

  static func success(id: RequestID, result: JSONValue) -> JSONValue {
    .object(["id": id.jsonValue, "result": result])
  }

  static func error(
    id: RequestID,
    code: Int64,
    message: String,
    data: JSONValue? = nil
  ) -> JSONValue {
    var payload: [String: JSONValue] = [
      "code": .integer(code),
      "message": .string(message),
    ]
    if let data { payload["data"] = data }
    return .object(["id": id.jsonValue, "error": .object(payload)])
  }

  private static func decodeMethodMessage(
    _ object: [String: JSONValue],
    methodValue: JSONValue
  ) throws -> InboundRPCMessage {
    guard let method = methodValue.stringValue else {
      throw CodexRPCError.malformedMessage("method is not a string")
    }

    let metadata = object.filter { key, _ in
      key != "id" && key != "method" && key != "params"
    }
    guard let idValue = object["id"] else {
      return .notification(
        RPCNotification(method: method, params: object["params"], metadata: metadata)
      )
    }
    return .serverRequest(
      RPCServerRequest(
        id: try RequestID(jsonValue: idValue),
        method: method,
        params: object["params"],
        metadata: metadata
      )
    )
  }

  private static func decodeResponse(
    _ object: [String: JSONValue]
  ) throws -> InboundRPCMessage {
    guard let idValue = object["id"] else {
      throw CodexRPCError.malformedMessage("message has neither method nor id")
    }
    let id = try RequestID(jsonValue: idValue)
    let result = object["result"]
    let error = object["error"]

    if let result, error == nil {
      return .response(id: id, result: result)
    }
    if let error, result == nil {
      return .error(id: id, error: try decodeError(error))
    }
    throw CodexRPCError.malformedMessage(
      "response must contain exactly one of result or error"
    )
  }

  private static func decodeError(_ value: JSONValue) throws -> RPCErrorPayload {
    guard let object = value.objectValue,
      let code = object["code"]?.integerValue,
      let message = object["message"]?.stringValue
    else {
      throw CodexRPCError.malformedMessage("error response has an invalid payload")
    }
    return RPCErrorPayload(code: code, message: message, data: object["data"])
  }
}
