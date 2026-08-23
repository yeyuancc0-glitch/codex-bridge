import Foundation

public enum BridgeWireMessageKind: String, CaseIterable, Sendable {
  case request
  case response
  case event
}

public struct BridgeWireMessage: Equatable, Sendable {
  public enum MessageError: Error, Equatable, Sendable {
    case invalidMessage
    case messageTooLarge
    case unsupportedType(String)
  }

  public let kind: BridgeWireMessageKind
  public let message: Data

  public init(kind: BridgeWireMessageKind, message: Data) {
    self.kind = kind
    self.message = message
  }

  public func encoded() throws -> Data {
    guard let object = try? JSONSerialization.jsonObject(with: message),
      object is [String: Any]
    else {
      throw MessageError.invalidMessage
    }
    let envelope: [String: Any] = [
      "message": object,
      "type": kind.rawValue,
    ]
    guard JSONSerialization.isValidJSONObject(envelope),
      let data = try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]),
      data.count <= BridgeWireLimits.maximumMessageBytes
    else {
      throw MessageError.messageTooLarge
    }
    return data
  }

  public static func decode(_ data: Data) throws -> BridgeWireMessage {
    guard !data.isEmpty, data.count <= BridgeWireLimits.maximumMessageBytes else {
      throw MessageError.messageTooLarge
    }
    guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      envelope.count == 2,
      let rawType = envelope["type"] as? String,
      let message = envelope["message"],
      JSONSerialization.isValidJSONObject(message)
    else {
      throw MessageError.invalidMessage
    }
    guard let kind = BridgeWireMessageKind(rawValue: rawType) else {
      throw MessageError.unsupportedType(rawType)
    }
    guard
      let encodedMessage = try? JSONSerialization.data(
        withJSONObject: message,
        options: [.sortedKeys]
      )
    else {
      throw MessageError.invalidMessage
    }
    return BridgeWireMessage(kind: kind, message: encodedMessage)
  }
}
