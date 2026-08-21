import Foundation

public enum CodexRPCError: Error, Equatable, LocalizedError, Sendable {
  case alreadyStarted
  case alreadyInitialized
  case notStarted
  case notInitialized
  case processLaunchFailed(String)
  case processExited(Int32)
  case timeout(method: String)
  case invalidUTF8
  case malformedMessage(String)
  case protocolContamination(String)
  case protocolLineTooLarge(maximumBytes: Int)
  case transportReadOverflow(maximumBufferedChunks: Int)
  case eventBufferOverflow(maximumEvents: Int)
  case remote(code: Int64, message: String, data: JSONValue?)
  case transportWriteFailed(String)

  public var errorDescription: String? {
    switch self {
    case .alreadyStarted:
      "Codex app-server is already started."
    case .alreadyInitialized:
      "Codex app-server is already initialized."
    case .notStarted:
      "Codex app-server is not running."
    case .notInitialized:
      "Codex app-server has not completed initialization."
    case .processLaunchFailed(let message):
      "Could not launch Codex app-server: \(message)"
    case .processExited(let status):
      "Codex app-server exited with status \(status)."
    case .timeout(let method):
      "Timed out waiting for Codex app-server method \(method)."
    case .invalidUTF8:
      "Codex app-server emitted a non-UTF-8 protocol line."
    case .malformedMessage(let reason):
      "Codex app-server emitted a malformed protocol message: \(reason)"
    case .protocolContamination(let preview):
      "Codex app-server stdout contained non-protocol data: \(preview)"
    case .protocolLineTooLarge(let maximumBytes):
      "Codex app-server emitted a protocol line larger than \(maximumBytes) bytes."
    case .transportReadOverflow(let maximumBufferedChunks):
      "Codex app-server output exceeded \(maximumBufferedChunks) buffered chunks."
    case .eventBufferOverflow(let maximumEvents):
      "Codex app-server emitted more than \(maximumEvents) unconsumed events."
    case .remote(let code, let message, _):
      "Codex app-server returned error \(code): \(message)"
    case .transportWriteFailed(let message):
      "Could not write to Codex app-server stdin: \(message)"
    }
  }
}
