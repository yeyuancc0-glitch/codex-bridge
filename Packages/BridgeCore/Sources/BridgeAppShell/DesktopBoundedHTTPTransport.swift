import Foundation
import Logging
import MCP

actor DesktopBoundedHTTPTransport: Transport {
  nonisolated let logger = Logger(label: "org.codexbridge.manual-http-validation")

  private static let maximumResponseBytes = 256 * 1_024
  private let endpoint: URL
  private let authorization: String
  private let session: URLSession
  private let redirectDelegate = RejectingRedirectDelegate()
  private let messages: AsyncThrowingStream<Data, Error>
  private let continuation: AsyncThrowingStream<Data, Error>.Continuation
  private var isConnected = false
  private var sessionID: String?
  private var protocolVersion = Version.latest

  init(endpoint: URL, authorization: String) {
    self.endpoint = endpoint
    self.authorization = authorization
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 5
    configuration.timeoutIntervalForResource = 5
    configuration.httpMaximumConnectionsPerHost = 1
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    session = URLSession(configuration: configuration)
    let pair = AsyncThrowingStream.makeStream(
      of: Data.self,
      throwing: Error.self,
      bufferingPolicy: .bufferingNewest(8)
    )
    messages = pair.stream
    continuation = pair.continuation
  }

  func connect() throws {
    guard !isConnected else { return }
    isConnected = true
  }

  func disconnect() {
    guard isConnected else { return }
    isConnected = false
    session.invalidateAndCancel()
    continuation.finish()
  }

  func send(_ data: Data) async throws {
    guard isConnected else { throw DesktopTransportError.notStarted }
    guard !data.isEmpty, data.count <= 128 * 1_024 else {
      throw DesktopTransportError.connectionFailed
    }
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.httpBody = data
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(authorization, forHTTPHeaderField: "Authorization")
    request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
    if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "MCP-Session-Id") }

    let (bytes, response) = try await session.bytes(for: request, delegate: redirectDelegate)
    guard let response = response as? HTTPURLResponse,
      (200..<300).contains(response.statusCode)
    else {
      throw DesktopTransportError.connectionFailed
    }
    try captureSessionID(response.value(forHTTPHeaderField: "MCP-Session-Id"))
    if response.statusCode == 202 || response.statusCode == 204 { return }
    let expectedLength = response.expectedContentLength
    guard expectedLength <= Self.maximumResponseBytes else {
      throw DesktopTransportError.connectionFailed
    }
    var body = Data()
    body.reserveCapacity(min(max(Int(expectedLength), 0), 16 * 1_024))
    for try await byte in bytes {
      guard body.count < Self.maximumResponseBytes else {
        throw DesktopTransportError.connectionFailed
      }
      body.append(byte)
    }
    guard !body.isEmpty else { throw DesktopTransportError.connectionFailed }
    let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
    if contentType.contains("application/json") {
      try deliver(body)
      return
    }
    guard contentType.contains("text/event-stream") else {
      throw DesktopTransportError.connectionFailed
    }
    try deliverSSE(body)
  }

  func receive() -> AsyncThrowingStream<Data, Error> {
    messages
  }

  private func captureSessionID(_ value: String?) throws {
    guard let value else { return }
    guard !value.isEmpty, value.utf8.count <= 1_024,
      value.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw DesktopTransportError.connectionFailed
    }
    sessionID = value
  }

  private func deliver(_ data: Data) throws {
    updateProtocolVersion(from: data)
    switch continuation.yield(data) {
    case .enqueued:
      return
    case .dropped, .terminated:
      throw DesktopTransportError.connectionFailed
    @unknown default:
      throw DesktopTransportError.connectionFailed
    }
  }

  private func deliverSSE(_ body: Data) throws {
    guard let text = String(data: body, encoding: .utf8) else {
      throw DesktopTransportError.connectionFailed
    }
    var delivered = false
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
    for event in normalized.components(separatedBy: "\n\n") {
      let fields = event.split(separator: "\n", omittingEmptySubsequences: false)
      let payload = fields.compactMap { line -> Substring? in
        guard line.hasPrefix("data:") else { return nil }
        let value = line.dropFirst(5)
        return value.first == " " ? value.dropFirst() : value
      }.joined(separator: "\n")
      guard !payload.isEmpty else { continue }
      let data = Data(payload.utf8)
      guard data.count <= Self.maximumResponseBytes else {
        throw DesktopTransportError.connectionFailed
      }
      try deliver(data)
      delivered = true
    }
    guard delivered else { throw DesktopTransportError.connectionFailed }
  }

  private func updateProtocolVersion(from data: Data) {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let result = object["result"] as? [String: Any],
      let version = result["protocolVersion"] as? String,
      !version.isEmpty,
      version.utf8.count <= 64,
      version.utf8.allSatisfy({ (0x20...0x7e).contains($0) })
    else {
      return
    }
    protocolVersion = version
  }
}

private final class RejectingRedirectDelegate: NSObject, URLSessionTaskDelegate,
  @unchecked Sendable
{
  func urlSession(
    _: URLSession,
    task _: URLSessionTask,
    willPerformHTTPRedirection _: HTTPURLResponse,
    newRequest _: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}
