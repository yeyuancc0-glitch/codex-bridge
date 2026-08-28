import BridgeAgentCore
import Foundation

extension OpenCodeACPProvider {
  static func runtimeError(for error: any Error) -> AgentRuntimeError {
    if let error = error as? AgentRuntimeError { return error }
    guard let error = error as? OpenCodeACPError else {
      return .processUnavailable
    }
    switch error {
    case .notInitialized, .operationInProgress:
      return .processUnavailable
    case .unsupportedProtocol(let version):
      return .unsupportedProtocol("opencode-acp-v\(version)")
    case .requestTimedOut:
      return .timedOut
    case .processExited(let code):
      return .processExited(code)
    case .oversizedFrame:
      return .oversizedFrame
    case .sessionMismatch:
      return .sessionMismatch
    case .invalidMessage, .malformedResponse:
      return .malformedEvent("opencode-acp")
    case .remote(let code, let message):
      if code == -32602, message.localizedCaseInsensitiveContains("model") {
        return .modelUnavailable(String(message.prefix(256)))
      }
      return .malformedEvent("opencode-acp-remote-\(code)")
    case .transportClosed:
      return .processUnavailable
    }
  }
}
