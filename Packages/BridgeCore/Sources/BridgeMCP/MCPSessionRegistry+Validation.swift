import Foundation
import MCP

extension MCPSessionRegistry {
  func validateAuthorityAndOrigin(
    _ request: HTTPRequest,
    clientID: MCPClientID
  ) -> HTTPResponse? {
    originValidator(for: clientID).validate(
      request,
      context: HTTPValidationContext(
        httpMethod: request.method.uppercased(),
        isInitializationRequest: isInitialize(request)
      )
    )
  }

  func originValidator(for clientID: MCPClientID) -> OriginValidator {
    var origins = [
      "http://127.0.0.1:\(boundPort)",
      "http://localhost:\(boundPort)",
      "http://[::1]:\(boundPort)",
    ]
    if clientID == .chatGPT {
      origins += [
        "https://chatgpt.com",
        "https://chat.openai.com",
        "https://platform.openai.com",
      ]
    }
    return OriginValidator(
      allowedHosts: [
        "127.0.0.1:\(boundPort)",
        "localhost:\(boundPort)",
        "[::1]:\(boundPort)",
      ],
      allowedOrigins: origins
    )
  }

  func isAdmissionCurrent(
    _ token: MCPClientAdmissionGate.Token?,
    for clientID: MCPClientID
  ) -> Bool {
    guard let clientAdmission else { return true }
    guard let token else { return false }
    return clientAdmission.isCurrent(token, for: clientID)
  }

  func isClientAdmitted(_ clientID: MCPClientID) -> Bool {
    guard let clientAdmission else { return true }
    return clientAdmission.isEnabled(clientID)
  }

  func makeUniqueSessionID() -> String {
    while true {
      let candidate = UUID().uuidString.lowercased()
      if sessions[candidate] == nil {
        return candidate
      }
    }
  }

  func isInitialize(_ request: HTTPRequest) -> Bool {
    guard request.method.uppercased() == "POST", let body = request.body else { return false }
    if let decoded = try? JSONDecoder().decode(Request<Initialize>.self, from: body),
      decoded.method == Initialize.name
    {
      return true
    }
    if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
      object["method"] as? String == Initialize.name
    {
      return true
    }
    return false
  }

  func isToolCall(_ request: HTTPRequest) -> Bool {
    guard request.method.uppercased() == "POST", let body = request.body,
      let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    else {
      return false
    }
    return object["method"] as? String == CallTool.name
  }
}
