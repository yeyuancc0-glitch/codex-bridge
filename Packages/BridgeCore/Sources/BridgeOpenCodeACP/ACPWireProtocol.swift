import BridgeACP
import BridgeAgentCore
import Foundation

public typealias ACPJSONValue = BridgeACP.ACPJSONValue
public typealias ACPRequestID = BridgeACP.ACPRequestID
public typealias ACPWireError = BridgeACP.ACPWireError
public typealias ACPWireMessage = BridgeACP.ACPWireMessage

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
  private var storage: BridgeACP.ACPLineDecoder

  public init(maximumFrameBytes: Int = 1_048_576) {
    let maximum = max(1, maximumFrameBytes)
    self.maximumFrameBytes = maximum
    storage = BridgeACP.ACPLineDecoder(maximumFrameBytes: maximum)
  }

  public mutating func append(_ data: Data) throws -> [Data] {
    do {
      return try storage.append(data)
    } catch {
      throw Self.compatibilityError(for: error)
    }
  }

  public mutating func finish() throws -> [Data] {
    do {
      return try storage.finish()
    } catch {
      throw Self.compatibilityError(for: error)
    }
  }

  private static func compatibilityError(for error: any Error) -> OpenCodeACPError {
    if let error = error as? OpenCodeACPError { return error }
    if let error = error as? BridgeACP.ACPError {
      switch error {
      case .oversizedFrame: return .oversizedFrame
      case .invalidMessage: return .invalidMessage
      case .malformedResponse: return .malformedResponse
      case .remote(let code, let message): return .remote(code: code, message: message)
      case .requestTimedOut: return .requestTimedOut
      case .transportClosed: return .transportClosed
      case .processExited(let code): return .processExited(code)
      }
    }
    return .invalidMessage
  }
}
