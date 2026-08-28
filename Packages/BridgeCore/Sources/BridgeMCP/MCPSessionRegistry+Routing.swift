import Foundation
import MCP

extension MCPSessionRegistry {
  func extractSessionID(from request: HTTPRequest) -> String? {
    if let header = request.header(HTTPHeaderName.sessionID), !header.isEmpty {
      return header
    }
    if let header = request.header("session-id"), !header.isEmpty {
      return header
    }
    if let header = request.header("sessionId"), !header.isEmpty {
      return header
    }
    if let path = request.path,
      let urlComponents = URLComponents(string: path),
      let queryItems = urlComponents.queryItems
    {
      if let queryID = queryItems.first(where: {
        $0.name.caseInsensitiveCompare("sessionId") == .orderedSame
          || $0.name.caseInsensitiveCompare("session_id") == .orderedSame
      })?.value, !queryID.isEmpty {
        return queryID
      }
    }
    return nil
  }

  func isDiscover(_ request: HTTPRequest) -> Bool {
    guard request.method.uppercased() == "POST", let body = request.body,
      let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    else {
      return false
    }
    return object["method"] as? String == "server/discover"
  }

  func isModernRequest(_ request: HTTPRequest) -> Bool {
    guard request.method.uppercased() == "POST" else { return false }
    if request.header("Mcp-Protocol-Version") != nil || request.header("Mcp-Method") != nil {
      return true
    }
    guard let body = request.body,
      let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
      let parameters = object["params"] as? [String: Any],
      let metadata = parameters["_meta"] as? [String: Any]
    else {
      return false
    }
    return metadata["io.modelcontextprotocol/protocolVersion"] != nil
  }

  func handleModernRequest(
    _ request: HTTPRequest,
    clientID: MCPClientID
  ) async -> HTTPResponse {
    if let rejection = validateModernRoutingHeaders(request) { return rejection }
    guard let statelessServerFactory else {
      return .error(statusCode: 400, .invalidRequest("Modern MCP requests are unavailable"))
    }
    let transport = StatelessHTTPServerTransport(
      validationPipeline: StandardValidationPipeline(validators: [
        originValidator(for: clientID),
        AcceptHeaderValidator(mode: .sseRequired),
        ContentTypeValidator(),
      ])
    )
    let admissionToken = clientAdmission?.token(for: clientID)
    var server: Server?
    do {
      let createdServer = try await statelessServerFactory(clientID)
      server = createdServer
      try await createdServer.start(transport: transport)
      guard isAdmissionCurrent(admissionToken, for: clientID) else {
        await createdServer.stop()
        return .error(statusCode: 503, .internalError("MCP client unavailable"))
      }
      let serverID = UUID()
      let requestTask = Task { await transport.handleRequest(request) }
      activeStatelessServers[serverID] = ActiveStatelessServer(
        clientID: clientID,
        server: createdServer,
        requestTask: requestTask
      )
      let response = await withTaskCancellationHandler {
        addingModernServerInfo(to: await requestTask.value)
      } onCancel: {
        requestTask.cancel()
        Task { await createdServer.stop() }
      }
      if removeStatelessServer(serverID) != nil {
        await createdServer.stop()
      }
      return response
    } catch {
      if let server {
        await server.stop()
      } else {
        await transport.disconnect()
      }
      return .error(statusCode: 500, .internalError("Modern MCP request failed"))
    }
  }

  func validateModernRequest(
    _ request: HTTPRequest,
    clientID: MCPClientID
  ) -> HTTPResponse? {
    let pipeline = StandardValidationPipeline(validators: [
      originValidator(for: clientID),
      AcceptHeaderValidator(mode: .sseRequired),
      ContentTypeValidator(),
    ])
    if let rejection = pipeline.validate(
      request,
      context: HTTPValidationContext(
        httpMethod: request.method.uppercased(),
        isInitializationRequest: false
      )
    ) {
      return rejection
    }
    return validateModernRoutingHeaders(request)
  }

  func validateModernRoutingHeaders(_ request: HTTPRequest) -> HTTPResponse? {
    guard let body = request.body,
      let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
      let method = object["method"] as? String
    else {
      return .error(statusCode: 400, .invalidRequest("Bad Request: Invalid modern MCP request"))
    }
    guard let protocolVersion = request.header("Mcp-Protocol-Version") else {
      return modernHeaderMismatch("Missing MCP protocol version header")
    }
    guard protocolVersion == Self.modernProtocolVersion else {
      return .error(
        statusCode: 400,
        .serverError(
          code: -32_022,
          message: "Unsupported MCP protocol version: \(protocolVersion)"
        )
      )
    }
    guard let routedMethod = request.header("Mcp-Method"), routedMethod == method else {
      return modernHeaderMismatch("MCP method header is missing or does not match the body")
    }
    guard let parameters = object["params"] as? [String: Any],
      let metadata = parameters["_meta"] as? [String: Any],
      let bodyVersion = metadata["io.modelcontextprotocol/protocolVersion"] as? String,
      metadata["io.modelcontextprotocol/clientCapabilities"] is [String: Any]
    else {
      return .error(
        statusCode: 400,
        .invalidRequest("Bad Request: Missing modern MCP request metadata")
      )
    }
    guard bodyVersion == protocolVersion else {
      return modernHeaderMismatch("MCP protocol version header does not match the body")
    }

    guard let routedNameField = modernRoutedNameField(for: method) else {
      return nil
    }
    guard let expectedName = parameters[routedNameField] as? String,
      !expectedName.isEmpty,
      let routedName = request.header("Mcp-Name"),
      decodeModernHeaderValue(routedName) == expectedName
    else {
      return modernHeaderMismatch("MCP name header is missing or does not match the body")
    }
    return nil
  }

  func modernRoutedNameField(for method: String) -> String? {
    switch method {
    case "tools/call", "prompts/get":
      return "name"
    case "resources/read":
      return "uri"
    default:
      return nil
    }
  }

  func decodeModernHeaderValue(_ value: String) -> String? {
    let prefix = "=?base64?"
    let suffix = "?="
    guard value.hasPrefix(prefix), value.hasSuffix(suffix) else { return value }
    let encoded = String(value.dropFirst(prefix.count).dropLast(suffix.count))
    guard let data = Data(base64Encoded: encoded) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  func modernHeaderMismatch(_ message: String) -> HTTPResponse {
    .error(statusCode: 400, .serverError(code: -32_020, message: message))
  }

  func addingModernServerInfo(to response: HTTPResponse) -> HTTPResponse {
    guard case .data(let data, let headers) = response,
      var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      var result = object["result"] as? [String: Any]
    else {
      return response
    }
    var metadata = result["_meta"] as? [String: Any] ?? [:]
    metadata["io.modelcontextprotocol/serverInfo"] = [
      "name": "Codex Bridge",
      "version": "1.0.0",
    ]
    result["_meta"] = metadata
    object["result"] = result
    guard let encoded = try? JSONSerialization.data(withJSONObject: object) else { return response }
    return .data(encoded, headers: headers)
  }

  func handleDiscover(
    for request: HTTPRequest,
    clientID: MCPClientID
  ) async -> HTTPResponse {
    guard let body = request.body,
      let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    else {
      return .error(statusCode: 400, .invalidRequest("Bad Request: Invalid discovery request"))
    }
    let id = object["id"] ?? NSNull()
    let instructions =
      await discoveryInstructionsProvider?(clientID)
      ?? "Codex Bridge exposes locally registered projects and Codex tasks. All actions are "
      + "executed on the user's machine after local approval."
    let result: [String: Any] = [
      "resultType": "complete",
      "supportedVersions": [Self.modernProtocolVersion, Version.latest],
      "capabilities": ["tools": [:]],
      "_meta": [
        "io.modelcontextprotocol/serverInfo": [
          "name": "Codex Bridge",
          "version": "1.0.0",
        ]
      ],
      "instructions": instructions,
    ]
    let response: [String: Any] = [
      "jsonrpc": "2.0",
      "id": id,
      "result": result,
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: response) else {
      return .error(statusCode: 500, .internalError("Discovery encoding failed"))
    }
    return .data(data, headers: [HTTPHeaderName.contentType: "application/json"])
  }
}
