import Foundation
import MCP

public typealias MCPHTTPRequestHandler =
  @Sendable (MCP.HTTPRequest) async -> MCP.HTTPResponse

public typealias MCPHTTPEmissionObserver =
  @Sendable (MCPHTTPEmission) async -> Void

public enum MCPHTTPConfigurationError: Error, Equatable, Sendable {
  case invalidPathSecret
  case invalidHeaderSecret
  case invalidLimit
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

public struct MCPHTTPConfiguration: Equatable, Sendable {
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
    try self.init(
      pathSecret: nil,
      headerSecret: headerSecret,
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

  package var routeBytes: [UInt8] {
    if headerSecret == nil {
      return Array("/mcp/\(pathSecret)".utf8)
    }
    return Array("/mcp".utf8)
  }

  private static func isValidSecret(_ value: String) -> Bool {
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
