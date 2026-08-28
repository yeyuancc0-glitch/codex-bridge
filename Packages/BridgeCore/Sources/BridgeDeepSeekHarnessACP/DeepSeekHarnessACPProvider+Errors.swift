import BridgeAgentCore

extension DeepSeekHarnessACPProvider {
  static func probeReason(_ error: any Error) -> String {
    switch error {
    case DeepSeekHarnessACPError.templateMismatch:
      return
        "DeepSeek Harness configuration changed outside the managed model and reasoning fields."
    case DeepSeekHarnessACPError.nodeVersionIncompatible(let version):
      return
        "DeepSeek Harness requires Node \(DeepSeekHarnessACPConstants.nodeRequirement); found \(version)."
    case AgentRuntimeError.unsupportedProtocol(let value):
      return "DeepSeek Harness ACP identity or protocol is incompatible: \(value)."
    case DeepSeekHarnessACPError.unsupportedProtocol(let value):
      return "DeepSeek Harness ACP uses unsupported protocol version \(value)."
    case DeepSeekHarnessACPError.processExited(let code):
      return
        "DeepSeek Harness ACP exited during probe (code: \(code.map(String.init) ?? "unknown"))."
    case DeepSeekHarnessACPError.artifactInvalid:
      return "DeepSeek Harness installation artifacts are unavailable or changed."
    default:
      return "DeepSeek Harness ACP probe failed."
    }
  }

  static func requiresReview(_ error: any Error) -> Bool {
    switch error {
    case DeepSeekHarnessACPError.artifactInvalid,
      DeepSeekHarnessACPError.templateMismatch,
      DeepSeekHarnessACPError.nodeVersionIncompatible,
      AgentRuntimeError.unsupportedProtocol:
      return true
    default:
      return false
    }
  }

  static func runtimeError(for error: any Error) -> AgentRuntimeError {
    if let error = error as? AgentRuntimeError { return error }
    switch error {
    case DeepSeekHarnessACPError.requestTimedOut,
      DeepSeekHarnessACPError.inactivityTimeout:
      return .timedOut
    case DeepSeekHarnessACPError.processExited(let code):
      return .processExited(code)
    case DeepSeekHarnessACPError.oversizedFrame:
      return .oversizedFrame
    case DeepSeekHarnessACPError.sessionMismatch:
      return .sessionMismatch
    case DeepSeekHarnessACPError.invalidMessage,
      DeepSeekHarnessACPError.malformedResponse,
      DeepSeekHarnessACPError.malformedPermission:
      return .malformedEvent("deepseek-harness-acp")
    case DeepSeekHarnessACPError.remote(let code, _):
      return .malformedEvent("deepseek-harness-acp-remote-\(code)")
    case DeepSeekHarnessACPError.transportClosed:
      return .processUnavailable
    case DeepSeekHarnessACPError.unsupportedProtocol(let version):
      return .unsupportedProtocol("deepseek-harness-acp-v\(version)")
    default:
      return .processUnavailable
    }
  }
}
