import BridgeProjects
import CryptoKit
import Foundation

public struct VerificationCommandIdentifier: RawRepresentable, Codable, Equatable, Hashable,
  Sendable
{
  public let rawValue: String

  public init?(rawValue: String) {
    guard rawValue.hasPrefix("vcmd_"), rawValue.count == 69 else { return nil }
    let digest = rawValue.dropFirst(5)
    let lowercaseHex = Set("0123456789abcdef")
    guard digest.allSatisfy(lowercaseHex.contains) else { return nil }
    self.rawValue = rawValue
  }

  public init(command: VerificationCommand) {
    var hasher = SHA256()
    Self.update(&hasher, with: command.executable)
    for argument in command.arguments {
      Self.update(&hasher, with: argument)
    }
    rawValue = "vcmd_" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let value = try container.decode(String.self)
    guard let identifier = Self(rawValue: value) else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Invalid verification command identifier."
      )
    }
    self = identifier
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  private static func update(_ hasher: inout SHA256, with value: String) {
    let bytes = Data(value.utf8)
    var length = UInt64(bytes.count).bigEndian
    withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
    hasher.update(data: bytes)
  }
}

public enum VerificationCommandSelection: Equatable, Sendable {
  case index(Int)
  case identifier(VerificationCommandIdentifier)
}

public enum VerificationExecutionAuthorization: Equatable, Sendable {
  case notApproved
  /// Compatibility-only authorization for an immediate, direct local call.
  /// Production task pipelines must use `VerificationAuthorizationStore` and its handle.
  case localUserApproved
}

public enum VerificationRunStatus: String, Codable, Equatable, Sendable {
  case passed
  case failed
  case timedOut
  case cancelled
  case outputLimitExceeded
  case policyDenied
  case localApprovalRequired
  case rootUnavailable
  case launchFailed
}

public struct VerificationOutputSummary: Codable, Equatable, Sendable {
  public let capturedByteCount: Int
  public let lineCount: Int
  public let sha256: String
  public let truncated: Bool

  package init(data: Data, truncated: Bool) {
    capturedByteCount = data.count
    let newlines = data.reduce(into: 0) { count, byte in
      if byte == 0x0A { count += 1 }
    }
    lineCount = data.isEmpty || data.last == 0x0A ? newlines : newlines + 1
    sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    self.truncated = truncated
  }
}

public struct VerificationRunResult: Codable, Equatable, Sendable {
  public let commandID: VerificationCommandIdentifier
  public let commandIndex: Int
  public let executableName: String
  public let required: Bool
  public let status: VerificationRunStatus
  public let exitCode: Int32?
  public let durationMilliseconds: UInt64
  public let standardOutput: VerificationOutputSummary
  public let standardError: VerificationOutputSummary

  package init(
    commandID: VerificationCommandIdentifier,
    commandIndex: Int,
    executableName: String,
    required: Bool,
    status: VerificationRunStatus,
    exitCode: Int32?,
    durationMilliseconds: UInt64,
    standardOutput: VerificationOutputSummary,
    standardError: VerificationOutputSummary
  ) {
    self.commandID = commandID
    self.commandIndex = commandIndex
    self.executableName = executableName
    self.required = required
    self.status = status
    self.exitCode = exitCode
    self.durationMilliseconds = durationMilliseconds
    self.standardOutput = standardOutput
    self.standardError = standardError
  }
}

public enum VerificationRunnerError: Error, LocalizedError, Equatable, Sendable {
  case commandIndexOutOfRange
  case unknownCommandIdentifier
  case workingDirectoryNotRegistered

  public var errorDescription: String? {
    switch self {
    case .commandIndexOutOfRange:
      "The verification command index is not registered for this project."
    case .unknownCommandIdentifier:
      "The verification command identifier is not registered for this project."
    case .workingDirectoryNotRegistered:
      "The verification working directory is not an exact registered project root."
    }
  }
}
