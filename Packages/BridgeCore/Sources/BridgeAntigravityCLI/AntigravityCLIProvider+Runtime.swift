import BridgeAgentCore
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

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
    guard path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 16 * 1_024 else {
      throw AgentRuntimeError.invalidRequest("runtimeBaseDirectory")
    }
    let requested = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    do {
      try FileManager.default.createDirectory(
        atPath: requested,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      guard chmod(requested, 0o700) == 0 else { throw AgentRuntimeError.processUnavailable }
      var metadata = stat()
      guard lstat(requested, &metadata) == 0,
        metadata.st_uid == getuid(),
        metadata.st_mode & S_IFMT == S_IFDIR,
        metadata.st_mode & 0o777 == 0o700
      else {
        throw AgentRuntimeError.processUnavailable
      }
      return URL(fileURLWithPath: requested, isDirectory: true)
        .resolvingSymlinksInPath().standardizedFileURL.path
    } catch let error as AgentRuntimeError {
      throw error
    } catch {
      throw AgentRuntimeError.processUnavailable
    }
  }
}
