import Foundation

enum TunnelDoctorCompatibility {
  static func acceptsNoAuthDoctorCompatibility(
    exitCode: Int32,
    standardOutput: String
  ) -> Bool {
    guard exitCode == 2 else { return false }
    guard
      let data = firstJSONObjectData(in: standardOutput),
      let report = try? JSONDecoder().decode(TunnelDoctorCompatibilityReport.self, from: data),
      report.result == "fail",
      report.failedChecks == ["oauth_metadata"]
    else {
      return false
    }

    var checksByID: [String: TunnelDoctorCompatibilityCheck] = [:]
    for check in report.checks {
      guard checksByID.updateValue(check, forKey: check.id) == nil else { return false }
      if check.id == "oauth_metadata" {
        guard check.status == "FAIL", check.containsHTTP404 else { return false }
      } else if check.status != "PASS", check.status != "SKIP" {
        return false
      }
    }

    guard checksByID["oauth_metadata"] != nil else { return false }
    for required in [
      "tunnel_id", "control_plane_api_key", "mcp_server_reachable", "health_listener",
    ] {
      guard checksByID[required]?.status == "PASS" else { return false }
    }
    return true
  }

  private static func firstJSONObjectData(in text: String) -> Data? {
    guard let start = text.firstIndex(of: "{") else { return nil }
    var depth = 0
    var isInsideString = false
    var isEscaped = false
    var index = start

    while index < text.endIndex {
      let character = text[index]
      if isInsideString {
        if isEscaped {
          isEscaped = false
        } else if character == "\\" {
          isEscaped = true
        } else if character == "\"" {
          isInsideString = false
        }
      } else {
        switch character {
        case "\"":
          isInsideString = true
        case "{":
          depth += 1
        case "}":
          depth -= 1
          guard depth >= 0 else { return nil }
          if depth == 0 {
            let end = text.index(after: index)
            return Data(text[start..<end].utf8)
          }
        default:
          break
        }
      }
      index = text.index(after: index)
    }
    return nil
  }
}

private struct TunnelDoctorCompatibilityReport: Decodable {
  let result: String
  let failedChecks: [String]
  let checks: [TunnelDoctorCompatibilityCheck]

  private enum CodingKeys: String, CodingKey {
    case result
    case failedChecks = "failed_checks"
    case checks
  }
}

private struct TunnelDoctorCompatibilityCheck: Decodable {
  let id: String
  let status: String
  let summary: String?
  let evidence: [String]?

  var containsHTTP404: Bool {
    let values = [summary].compactMap { $0 } + (evidence ?? [])
    return values.contains { $0.localizedCaseInsensitiveContains("HTTP 404") }
  }
}
