import Foundation

public enum AppServerProbeError: Error, LocalizedError, Sendable, Equatable {
    case alreadyStarted
    case notStarted
    case invalidUTF8
    case malformedMessage(String)
    case protocolContamination(String)
    case remote(code: Int?, message: String)
    case processExited(Int32)
    case timeout(method: String)

    public var errorDescription: String? {
        switch self {
        case .alreadyStarted:
            "Codex app-server process is already started."
        case .notStarted:
            "Codex app-server process is not running."
        case .invalidUTF8:
            "Codex app-server emitted a non-UTF-8 protocol line."
        case let .malformedMessage(reason):
            "Codex app-server emitted malformed JSON: \(reason)"
        case let .protocolContamination(line):
            "Codex app-server stdout contained non-JSON data: \(line)"
        case let .remote(code, message):
            "Codex app-server returned error \(code.map(String.init) ?? "unknown"): \(message)"
        case let .processExited(status):
            "Codex app-server exited with status \(status)."
        case let .timeout(method):
            "Timed out waiting for Codex app-server method \(method)."
        }
    }
}

