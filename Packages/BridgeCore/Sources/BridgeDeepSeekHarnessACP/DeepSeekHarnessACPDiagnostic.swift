import Foundation

enum DeepSeekHarnessACPDiagnostic {
  static let maximumProviderMessageBytes = 2 * 1_024

  static func failureSummary(for error: any Error) -> String {
    switch error {
    case DeepSeekHarnessACPError.remote(let code, let message):
      let detail = sanitizeProviderMessage(message)
      guard !detail.isEmpty else {
        return "DeepSeek Harness ACP returned protocol error \(code)."
      }
      return "DeepSeek Harness ACP returned protocol error \(code): \(detail)"
    case DeepSeekHarnessACPError.processExited(let code):
      if let code {
        return "DeepSeek Harness ACP process exited before completion (exit code \(code))."
      }
      return "DeepSeek Harness ACP process exited before completion (exit status unavailable)."
    case DeepSeekHarnessACPError.transportClosed:
      return "DeepSeek Harness ACP transport closed before completion."
    case DeepSeekHarnessACPError.requestTimedOut:
      return "DeepSeek Harness ACP request timed out."
    case DeepSeekHarnessACPError.oversizedFrame:
      return "DeepSeek Harness ACP exceeded a protocol size limit."
    case DeepSeekHarnessACPError.sessionMismatch:
      return "DeepSeek Harness ACP reported an unexpected session."
    case DeepSeekHarnessACPError.inactivityTimeout:
      return "DeepSeek Harness ACP became inactive before completion."
    default:
      return "DeepSeek Harness ACP execution failed."
    }
  }

  static func sanitizeProviderMessage(_ message: String) -> String {
    var value = normalizeControlCharacters(message)
    value = replace(value, pattern: bearerPattern, template: "[redacted]")
    value = replace(value, pattern: sensitiveAssignmentPattern, template: "$1=[redacted]")
    value = replace(value, pattern: environmentAssignmentPattern, template: "$1=[redacted]")
    value = replace(value, pattern: urlUserInfoPattern, template: "$1[redacted]@")
    value = replace(value, pattern: urlQueryPattern, template: "$1[redacted]")
    value = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return boundedUTF8(value, maximumBytes: maximumProviderMessageBytes)
  }

  private static let bearerPattern = #"(?i)\b(?:Bearer|Basic)\s+[^\s,;}\]]+"#

  private static let sensitiveAssignmentPattern =
    #"(?i)(["']?\b(?:authorization|proxy-authorization|cookie|set-cookie|x-api-key|api[-_]?key|access[-_]?key|secret|token|password|credential|private[-_]?key|key)\b["']?)\s*(?:[:=]\s*|\s+)(?:"[^"]*"|'[^']*'|[^\s,;}\]]+)"#

  private static let environmentAssignmentPattern =
    #"(?i)(\.env(?:\.[A-Za-z0-9_-]+)?)\s*(?:[:=]\s*)(?:"[^"]*"|'[^']*'|[^\s,;}\]]+)"#

  private static let urlUserInfoPattern = #"(?i)\b(https?://)[^/\s:@]+(?::[^/\s@]*)?@"#

  private static let urlQueryPattern =
    #"(?i)([?&](?:authorization|token|api[-_]?key|access[-_]?key|secret|password|key|signature)=)[^&#\s]+"#

  private static func normalizeControlCharacters(_ value: String) -> String {
    value.unicodeScalars.map { scalar in
      switch scalar.value {
      case 0x09, 0x0A, 0x0D:
        " "
      case 0..<0x20, 0x7F:
        " "
      default:
        String(scalar)
      }
    }.joined()
  }

  private static func replace(_ value: String, pattern: String, template: String) -> String {
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    return expression.stringByReplacingMatches(
      in: value,
      options: [],
      range: range,
      withTemplate: template
    )
  }

  private static func boundedUTF8(_ value: String, maximumBytes: Int) -> String {
    guard value.utf8.count > maximumBytes else { return value }
    let suffix = "..."
    var result = ""
    for scalar in value.unicodeScalars {
      let character = String(scalar)
      guard result.utf8.count + character.utf8.count + suffix.utf8.count <= maximumBytes else {
        break
      }
      result.append(contentsOf: character)
    }
    return result + suffix
  }
}
