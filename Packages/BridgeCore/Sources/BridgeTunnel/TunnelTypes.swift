import BridgeSecurity
import Foundation

/// Marker for helper verification failures that require intervention by the local user.
public protocol TunnelHelperValidationError: Error, Sendable {}

public struct TunnelID: Hashable, RawRepresentable, Sendable {
  public let rawValue: String

  public init(rawValue: String) {
    precondition(Self.isValid(rawValue), "Invalid tunnel ID")
    self.rawValue = rawValue
  }

  public init(validating rawValue: String) throws {
    guard Self.isValid(rawValue) else {
      throw TunnelConfigurationError.invalidTunnelID
    }
    self.rawValue = rawValue
  }

  private static func isValid(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    guard bytes.count == 39, bytes.starts(with: Array("tunnel_".utf8)) else { return false }
    return bytes.dropFirst(7).allSatisfy {
      (UInt8(ascii: "a")...UInt8(ascii: "z")).contains($0)
        || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
    }
  }
}

public enum TunnelLifecycle: String, Codable, Equatable, Sendable {
  case stopped
  case starting
  case authenticating
  case connecting
  case ready
  case degraded
  case failed
}

public struct TunnelConfiguration: Sendable {
  public let helperExecutable: URL
  public let tunnelID: TunnelID
  public let runtimeKeyReference: SecretReference
  public let localMCPURL: URL
  public let runtimeDirectory: URL
  public let readinessTimeout: Duration
  public let healthInterval: Duration
  public let processTimeout: Duration
  public let metricsFreshness: Duration
  public let expectedHelperSHA256: String
  package let helperMCPURL: URL
  package let localMCPHeaderSecret: String

  public init(
    helperExecutable: URL,
    tunnelID: TunnelID,
    runtimeKeyReference: SecretReference,
    localMCPURL: URL,
    runtimeDirectory: URL,
    readinessTimeout: Duration = .seconds(30),
    healthInterval: Duration = .seconds(5),
    processTimeout: Duration = .seconds(20),
    metricsFreshness: Duration = .seconds(70),
    expectedHelperSHA256: String
  ) throws {
    guard Self.isValidPlatformFileURL(helperExecutable) else {
      throw TunnelConfigurationError.invalidHelperExecutable
    }
    guard Self.isValidPlatformFileURL(runtimeDirectory) else {
      throw TunnelConfigurationError.invalidRuntimeDirectory
    }
    guard Self.isValidLocalMCPURL(localMCPURL) else {
      throw TunnelConfigurationError.invalidLocalMCPURL
    }
    guard readinessTimeout > .zero, healthInterval > .zero, processTimeout > .zero,
      metricsFreshness > .zero
    else {
      throw TunnelConfigurationError.invalidTimeout
    }
    guard Self.isValidSHA256(expectedHelperSHA256) else {
      throw TunnelConfigurationError.invalidHelperDigest
    }
    self.helperExecutable = helperExecutable.standardizedFileURL
    self.tunnelID = tunnelID
    self.runtimeKeyReference = runtimeKeyReference
    self.localMCPURL = localMCPURL
    let components = URLComponents(url: localMCPURL, resolvingAgainstBaseURL: false)!
    localMCPHeaderSecret = String(components.percentEncodedPath.dropFirst("/mcp/".count))
    var helperComponents = components
    helperComponents.percentEncodedPath = "/mcp"
    helperMCPURL = helperComponents.url!
    self.runtimeDirectory = runtimeDirectory.standardizedFileURL
    self.readinessTimeout = readinessTimeout
    self.healthInterval = healthInterval
    self.processTimeout = processTimeout
    self.metricsFreshness = metricsFreshness
    self.expectedHelperSHA256 = expectedHelperSHA256
  }

  public init(
    helperExecutable: URL,
    tunnelID: TunnelID,
    runtimeKeyReference: SecretReference,
    localMCPURL: URL,
    localMCPHeaderSecret: String,
    runtimeDirectory: URL,
    readinessTimeout: Duration = .seconds(30),
    healthInterval: Duration = .seconds(5),
    processTimeout: Duration = .seconds(20),
    metricsFreshness: Duration = .seconds(70),
    expectedHelperSHA256: String
  ) throws {
    guard Self.isValidPlatformFileURL(helperExecutable) else {
      throw TunnelConfigurationError.invalidHelperExecutable
    }
    guard Self.isValidPlatformFileURL(runtimeDirectory) else {
      throw TunnelConfigurationError.invalidRuntimeDirectory
    }
    guard Self.isValidHeaderMCPURL(localMCPURL) else {
      throw TunnelConfigurationError.invalidLocalMCPURL
    }
    guard Self.isValidSecret(localMCPHeaderSecret) else {
      throw TunnelConfigurationError.invalidLocalMCPHeaderSecret
    }
    guard readinessTimeout > .zero, healthInterval > .zero, processTimeout > .zero,
      metricsFreshness > .zero
    else {
      throw TunnelConfigurationError.invalidTimeout
    }
    guard Self.isValidSHA256(expectedHelperSHA256) else {
      throw TunnelConfigurationError.invalidHelperDigest
    }
    self.helperExecutable = helperExecutable.standardizedFileURL
    self.tunnelID = tunnelID
    self.runtimeKeyReference = runtimeKeyReference
    self.localMCPURL = localMCPURL
    self.localMCPHeaderSecret = localMCPHeaderSecret
    self.runtimeDirectory = runtimeDirectory.standardizedFileURL
    self.readinessTimeout = readinessTimeout
    self.healthInterval = healthInterval
    self.processTimeout = processTimeout
    self.metricsFreshness = metricsFreshness
    self.expectedHelperSHA256 = expectedHelperSHA256
    helperMCPURL = localMCPURL
  }

  private static func isValidLocalMCPURL(_ url: URL) -> Bool {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return false
    }
    guard components.scheme == "http", components.host == "127.0.0.1" else { return false }
    guard let port = components.port, (1...65_535).contains(port) else { return false }
    guard components.user == nil, components.password == nil else {
      return false
    }
    guard components.query == nil, components.fragment == nil else { return false }
    let path = Array(components.percentEncodedPath.utf8)
    let prefix = Array("/mcp/".utf8)
    guard path.count == prefix.count + 43, path.starts(with: prefix) else { return false }
    return path.dropFirst(prefix.count).allSatisfy {
      (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains($0)
        || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains($0)
        || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
        || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "-")
    }
  }

  private static func isValidPlatformFileURL(_ url: URL) -> Bool {
    guard url.isFileURL else { return false }
    #if canImport(WinSDK)
      return WindowsTunnelPathRules.isLocalAbsolutePath(
        WindowsTunnelPathRules.normalize(url.path)
      )
    #else
      return url.path.hasPrefix("/")
    #endif
  }

  private static func isValidHeaderMCPURL(_ url: URL) -> Bool {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return false
    }
    return components.scheme == "http"
      && components.host == "127.0.0.1"
      && components.port.map { (1...65_535).contains($0) } == true
      && components.user == nil
      && components.password == nil
      && components.percentEncodedPath == "/mcp"
      && components.query == nil
      && components.fragment == nil
  }

  private static func isValidSecret(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    guard bytes.count == 43 else { return false }
    return bytes.allSatisfy {
      (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains($0)
        || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains($0)
        || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
        || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "-")
    }
  }

  private static func isValidSHA256(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    guard bytes.count == 64 else { return false }
    return bytes.allSatisfy {
      (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
        || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
    }
  }
}

public enum TunnelConfigurationError: Error, Equatable, Sendable {
  case invalidTunnelID
  case invalidHelperExecutable
  case invalidLocalMCPURL
  case invalidLocalMCPHeaderSecret
  case invalidRuntimeDirectory
  case invalidTimeout
  case invalidHelperDigest
}

public struct TunnelDoctorReport: Equatable, Sendable {
  public let output: String

  public init(output: String) {
    self.output = output
  }
}

public struct TunnelDiagnostics: Equatable, Sendable {
  public let standardOutput: String
  public let standardError: String
  public let wasTruncated: Bool
  public let actionRequired: Bool

  public init(
    standardOutput: String,
    standardError: String,
    wasTruncated: Bool,
    actionRequired: Bool
  ) {
    self.standardOutput = standardOutput
    self.standardError = standardError
    self.wasTruncated = wasTruncated
    self.actionRequired = actionRequired
  }
}

public enum TunnelManagerError: Error, Equatable, Sendable {
  case alreadyRunning
  case lifecycleBusy
  case helperUnavailable
  case doctorFailed(exitCode: Int32, diagnostics: String)
  case invalidRuntimeKey
  case launchFailed
  case readinessTimedOut
  case helperExited(exitCode: Int32)
  case processTimedOut
  case cleanupFailed
  case stopped
}
