import BridgeAgentCore
import Foundation

extension AntigravityCLIProvider {
  func makeRunDirectory() throws -> String {
    let base = try Self.preparePrivateDirectory(configuration.runtimeBaseDirectory)
    let path = URL(fileURLWithPath: base, isDirectory: true)
      .appendingPathComponent("run-\(UUID().uuidString.lowercased())", isDirectory: true).path
    return try Self.preparePrivateDirectory(path)
  }

  static func runtimeError(_ error: any Error) -> AgentRuntimeError {
    if let error = error as? AgentRuntimeError { return error }
    guard let error = error as? AntigravityCLIError else { return .processUnavailable }
    return switch error {
    case .invalidMessage:
      .malformedEvent("antigravity-stream-json")
    case .oversizedFrame:
      .oversizedFrame
    case .transportClosed:
      .processUnavailable
    case .processExited(let code):
      .processExited(code)
    case .requestTimedOut:
      .timedOut
    case .sessionMismatch:
      .sessionMismatch
    case .modelMismatch(let model):
      .modelUnavailable(model)
    case .unsupportedVersion(let version):
      .unsupportedProtocol("antigravity-\(version)")
    case .permissionDenied:
      .approvalUnavailable("antigravity-headless")
    }
  }

  static func preparePrivateDirectory(_ path: String) throws -> String {
    try AntigravityCLILaunchRuntime.preparePrivateDirectory(
      path,
      field: "runtimeBaseDirectory"
    )
  }
}
