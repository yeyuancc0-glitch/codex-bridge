import Foundation
import MCP

public typealias MCPHTTPRequestHandler =
  @Sendable (MCP.HTTPRequest) async -> MCP.HTTPResponse

public typealias MCPAuthenticatedHTTPRequestHandler =
  @Sendable (AuthenticatedMCPRequest) async -> MCP.HTTPResponse

public typealias MCPHTTPEmissionObserver =
  @Sendable (MCPHTTPEmission) async -> Void

public enum MCPHTTPConfigurationError: Error, Equatable, Sendable {
  case invalidPathSecret
  case invalidHeaderSecret
  case invalidClientCredentials
  case invalidLimit
}

public struct MCPClientID: RawRepresentable, Hashable, Codable, Sendable {
  public let rawValue: String

  public init(rawValue: String) {
    precondition(
      !rawValue.isEmpty && rawValue.utf8.count <= 128
        && rawValue.utf8.allSatisfy { $0 >= 0x21 && $0 <= 0x7E }
    )
    self.rawValue = rawValue
  }
}

public enum BuiltInMCPClient {
  public static let chatGPT = MCPClientID(rawValue: "openai.chatgpt")
  public static let qwenStudio = MCPClientID(rawValue: "qwen.studio")
}

extension MCPClientID {
  public static let chatGPT = BuiltInMCPClient.chatGPT
  public static let qwenStudio = BuiltInMCPClient.qwenStudio
}

public struct MCPInvocationContext: Equatable, Sendable {
  public let clientID: MCPClientID
  public let sessionID: String?

  public init(clientID: MCPClientID, sessionID: String? = nil) {
    self.clientID = clientID
    self.sessionID = sessionID
  }
}

public struct AuthenticatedMCPRequest: Sendable {
  public let request: MCP.HTTPRequest
  public let clientID: MCPClientID

  public init(request: MCP.HTTPRequest, clientID: MCPClientID) {
    self.request = request
    self.clientID = clientID
  }
}

public struct MCPClientCredential: Equatable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public let clientID: MCPClientID
  package let secret: String

  public init(clientID: MCPClientID, value: String) throws {
    guard MCPHTTPConfiguration.isValidSecret(value) else {
      throw MCPHTTPConfigurationError.invalidHeaderSecret
    }
    self.clientID = clientID
    self.secret = value
  }

  public var description: String {
    "MCPClientCredential(clientID: \(clientID.rawValue), value: <redacted>)"
  }

  public var debugDescription: String { description }
}

public final class MCPClientCredentialAuthenticator: @unchecked Sendable {
  private let lock = NSLock()
  private var credentials: [MCPClientCredential]
  private var lastAuthenticatedAt: [MCPClientID: Date] = [:]

  public init(credentials: [MCPClientCredential]) throws {
    self.credentials = []
    try replaceCredentials(credentials)
  }

  public func replaceCredentials(_ credentials: [MCPClientCredential]) throws {
    guard Self.isValid(credentials) else {
      throw MCPHTTPConfigurationError.invalidClientCredentials
    }
    lock.lock()
    self.credentials = credentials
    lastAuthenticatedAt = lastAuthenticatedAt.filter { clientID, _ in
      credentials.contains { $0.clientID == clientID }
    }
    lock.unlock()
  }

  public func lastAuthenticationDate(for clientID: MCPClientID) -> Date? {
    lock.lock()
    defer { lock.unlock() }
    return lastAuthenticatedAt[clientID]
  }

  package func authenticate(_ values: [String]) -> MCPClientID? {
    guard values.count == 1 else { return nil }
    let candidate = Array(values[0].utf8)
    lock.lock()
    defer { lock.unlock() }
    var matchedClientID: MCPClientID?
    for credential in credentials {
      if Self.constantTimeEqual(candidate, Array(credential.secret.utf8)) {
        matchedClientID = credential.clientID
      }
    }
    if let matchedClientID {
      lastAuthenticatedAt[matchedClientID] = Date()
    }
    return matchedClientID
  }

  private static func isValid(_ credentials: [MCPClientCredential]) -> Bool {
    guard (1...8).contains(credentials.count) else { return false }
    return Set(credentials.map(\.clientID)).count == credentials.count
      && Set(credentials.map(\.secret)).count == credentials.count
  }

  private static func constantTimeEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
    var difference = lhs.count ^ rhs.count
    for index in 0..<max(lhs.count, rhs.count) {
      let left = index < lhs.count ? lhs[index] : 0
      let right = index < rhs.count ? rhs[index] : 0
      difference |= Int(left ^ right)
    }
    return difference == 0
  }
}

public struct MCPHTTPBoundEndpoint: Equatable, Sendable {
  public let host: String
  public let port: Int

  public init(host: String, port: Int) {
    self.host = host
    self.port = port
  }
}

public struct MCPHTTPEmission: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case responseBody
    case streamEvent
    case sessionTerminated
  }

  public let sessionID: String?
  public let byteCount: Int
  public let kind: Kind

  public init(sessionID: String?, byteCount: Int, kind: Kind) {
    self.sessionID = sessionID
    self.byteCount = byteCount
    self.kind = kind
  }
}

public struct MCPHTTPMetrics: Equatable, Sendable {
  public let activeConnections: Int
  public let activeRequests: Int

  public init(activeConnections: Int, activeRequests: Int) {
    self.activeConnections = activeConnections
    self.activeRequests = activeRequests
  }
}

public struct MCPHTTPConfiguration: Sendable {
  public static let loopbackHost = "127.0.0.1"
  public static let tunnelAuthenticationHeader = "X-Codex-Bridge-Token"

  public let pathSecret: String
  public let headerSecret: String?
  public let port: Int
  public let maximumRequestTargetBytes: Int
  public let maximumHeaderBytes: Int
  public let maximumRequestBodyBytes: Int
  public let maximumResponseChunkBytes: Int
  public let headerDeadline: Duration
  public let bodyDeadline: Duration
  public let responseDeadline: Duration
  public let maximumConnections: Int
  public let maximumActiveRequests: Int
  package let clientAuthenticator: MCPClientCredentialAuthenticator?

  public init(
    pathSecret: String,
    port: Int = 0,
    maximumRequestTargetBytes: Int = 2 * 1_024,
    maximumHeaderBytes: Int = 32 * 1_024,
    maximumRequestBodyBytes: Int = 1_024 * 1_024,
    maximumResponseChunkBytes: Int = 256 * 1_024,
    headerDeadline: Duration = .seconds(5),
    bodyDeadline: Duration = .seconds(5),
    responseDeadline: Duration = .seconds(25),
    maximumConnections: Int = 32,
    maximumActiveRequests: Int = 16
  ) throws {
    guard Self.isValidSecret(pathSecret) else {
      throw MCPHTTPConfigurationError.invalidPathSecret
    }
    try self.init(
      pathSecret: pathSecret,
      headerSecret: nil,
      clientAuthenticator: nil,
      port: port,
      maximumRequestTargetBytes: maximumRequestTargetBytes,
      maximumHeaderBytes: maximumHeaderBytes,
      maximumRequestBodyBytes: maximumRequestBodyBytes,
      maximumResponseChunkBytes: maximumResponseChunkBytes,
      headerDeadline: headerDeadline,
      bodyDeadline: bodyDeadline,
      responseDeadline: responseDeadline,
      maximumConnections: maximumConnections,
      maximumActiveRequests: maximumActiveRequests
    )
  }

  public init(
    headerSecret: String,
    port: Int = 0,
    maximumRequestTargetBytes: Int = 2 * 1_024,
    maximumHeaderBytes: Int = 32 * 1_024,
    maximumRequestBodyBytes: Int = 1_024 * 1_024,
    maximumResponseChunkBytes: Int = 256 * 1_024,
    headerDeadline: Duration = .seconds(5),
    bodyDeadline: Duration = .seconds(5),
    responseDeadline: Duration = .seconds(25),
    maximumConnections: Int = 32,
    maximumActiveRequests: Int = 16
  ) throws {
    guard Self.isValidSecret(headerSecret) else {
      throw MCPHTTPConfigurationError.invalidHeaderSecret
    }
    let credential = try MCPClientCredential(clientID: .chatGPT, value: headerSecret)
    let authenticator = try MCPClientCredentialAuthenticator(credentials: [credential])
    try self.init(
      pathSecret: nil,
      headerSecret: headerSecret,
      clientAuthenticator: authenticator,
      port: port,
      maximumRequestTargetBytes: maximumRequestTargetBytes,
      maximumHeaderBytes: maximumHeaderBytes,
      maximumRequestBodyBytes: maximumRequestBodyBytes,
      maximumResponseChunkBytes: maximumResponseChunkBytes,
      headerDeadline: headerDeadline,
      bodyDeadline: bodyDeadline,
      responseDeadline: responseDeadline,
      maximumConnections: maximumConnections,
      maximumActiveRequests: maximumActiveRequests
    )
  }

  public init(
    clientAuthenticator: MCPClientCredentialAuthenticator,
    port: Int = 0,
    maximumRequestTargetBytes: Int = 2 * 1_024,
    maximumHeaderBytes: Int = 32 * 1_024,
    maximumRequestBodyBytes: Int = 1_024 * 1_024,
    maximumResponseChunkBytes: Int = 256 * 1_024,
    headerDeadline: Duration = .seconds(5),
    bodyDeadline: Duration = .seconds(5),
    responseDeadline: Duration = .seconds(25),
    maximumConnections: Int = 32,
    maximumActiveRequests: Int = 16
  ) throws {
    try self.init(
      pathSecret: nil,
      headerSecret: nil,
      clientAuthenticator: clientAuthenticator,
      port: port,
      maximumRequestTargetBytes: maximumRequestTargetBytes,
      maximumHeaderBytes: maximumHeaderBytes,
      maximumRequestBodyBytes: maximumRequestBodyBytes,
      maximumResponseChunkBytes: maximumResponseChunkBytes,
      headerDeadline: headerDeadline,
      bodyDeadline: bodyDeadline,
      responseDeadline: responseDeadline,
      maximumConnections: maximumConnections,
      maximumActiveRequests: maximumActiveRequests
    )
  }

  private init(
    pathSecret: String?,
    headerSecret: String?,
    clientAuthenticator: MCPClientCredentialAuthenticator?,
    port: Int,
    maximumRequestTargetBytes: Int,
    maximumHeaderBytes: Int,
    maximumRequestBodyBytes: Int,
    maximumResponseChunkBytes: Int,
    headerDeadline: Duration,
    bodyDeadline: Duration,
    responseDeadline: Duration,
    maximumConnections: Int,
    maximumActiveRequests: Int
  ) throws {
    guard
      (0...65_535).contains(port),
      maximumRequestTargetBytes > 0,
      maximumHeaderBytes > 0,
      maximumRequestBodyBytes > 0,
      maximumResponseChunkBytes > 0,
      headerDeadline > .zero,
      bodyDeadline > .zero,
      responseDeadline > .zero,
      maximumConnections > 0,
      maximumActiveRequests > 0
    else {
      throw MCPHTTPConfigurationError.invalidLimit
    }

    self.pathSecret = pathSecret ?? ""
    self.headerSecret = headerSecret
    self.clientAuthenticator = clientAuthenticator
    self.port = port
    self.maximumRequestTargetBytes = maximumRequestTargetBytes
    self.maximumHeaderBytes = maximumHeaderBytes
    self.maximumRequestBodyBytes = maximumRequestBodyBytes
    self.maximumResponseChunkBytes = maximumResponseChunkBytes
    self.headerDeadline = headerDeadline
    self.bodyDeadline = bodyDeadline
    self.responseDeadline = responseDeadline
    self.maximumConnections = maximumConnections
    self.maximumActiveRequests = maximumActiveRequests
  }

  package var usesHeaderAuthentication: Bool {
    clientAuthenticator != nil
  }

  package var routeBytes: [UInt8] {
    if !usesHeaderAuthentication {
      return Array("/mcp/\(pathSecret)".utf8)
    }
    return Array("/mcp".utf8)
  }

  package static func isValidSecret(_ value: String) -> Bool {
    guard value.utf8.count == 43 else { return false }
    return value.utf8.allSatisfy { byte in
      (65...90).contains(byte)
        || (97...122).contains(byte)
        || (48...57).contains(byte)
        || byte == 45
        || byte == 95
    }
  }
}

extension MCPHTTPConfiguration: Equatable {
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.pathSecret == rhs.pathSecret
      && lhs.headerSecret == rhs.headerSecret
      && authenticationMatches(lhs, rhs)
      && lhs.port == rhs.port
      && lhs.maximumRequestTargetBytes == rhs.maximumRequestTargetBytes
      && lhs.maximumHeaderBytes == rhs.maximumHeaderBytes
      && lhs.maximumRequestBodyBytes == rhs.maximumRequestBodyBytes
      && lhs.maximumResponseChunkBytes == rhs.maximumResponseChunkBytes
      && lhs.headerDeadline == rhs.headerDeadline
      && lhs.bodyDeadline == rhs.bodyDeadline
      && lhs.responseDeadline == rhs.responseDeadline
      && lhs.maximumConnections == rhs.maximumConnections
      && lhs.maximumActiveRequests == rhs.maximumActiveRequests
  }

  private static func authenticationMatches(_ lhs: Self, _ rhs: Self) -> Bool {
    if lhs.headerSecret != nil || rhs.headerSecret != nil {
      return lhs.headerSecret == rhs.headerSecret
    }
    switch (lhs.clientAuthenticator, rhs.clientAuthenticator) {
    case (nil, nil):
      return true
    case (let left?, let right?):
      return left === right
    default:
      return false
    }
  }
}
