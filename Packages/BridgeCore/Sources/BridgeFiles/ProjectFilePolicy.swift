import BridgeProjects
import BridgeSecurity
import Foundation

struct ProjectFilePolicy: Sendable {
  private let sensitivePathPolicy = SensitivePathPolicy()
  private let forbiddenPatterns: [ForbiddenPathPattern]

  init(forbiddenPatterns: [ForbiddenPathPattern]) {
    self.forbiddenPatterns = forbiddenPatterns
  }

  func allows(_ path: SecureRelativePath) -> Bool {
    sensitivePathPolicy.allows(path)
      && !forbiddenPatterns.contains { GlobPathMatcher.matches(path.value, pattern: $0.value) }
  }
}

private enum GlobPathMatcher {
  static func matches(_ path: String, pattern: String) -> Bool {
    let pathComponents = path.split(separator: "/").map(String.init)
    let patternComponents = pattern.split(separator: "/").map(String.init)
    var previous = [Bool](repeating: false, count: pathComponents.count + 1)
    previous[0] = true

    for patternComponent in patternComponents {
      var current = [Bool](repeating: false, count: pathComponents.count + 1)
      if patternComponent == "**" {
        current[0] = previous[0]
        for index in pathComponents.indices {
          current[index + 1] = previous[index + 1] || current[index]
        }
      } else {
        for index in pathComponents.indices where previous[index] {
          current[index + 1] = componentMatches(
            pathComponents[index],
            pattern: patternComponent
          )
        }
      }
      previous = current
    }
    return previous[pathComponents.count]
  }

  private static func componentMatches(_ value: String, pattern: String) -> Bool {
    let valueCharacters = Array(value)
    let patternCharacters = Array(pattern)
    var previous = [Bool](repeating: false, count: valueCharacters.count + 1)
    previous[0] = true

    for patternCharacter in patternCharacters {
      var current = [Bool](repeating: false, count: valueCharacters.count + 1)
      if patternCharacter == "*" {
        current[0] = previous[0]
        for index in valueCharacters.indices {
          current[index + 1] = previous[index + 1] || current[index]
        }
      } else {
        for index in valueCharacters.indices where previous[index] {
          current[index + 1] = valueCharacters[index] == patternCharacter
        }
      }
      previous = current
    }
    return previous[valueCharacters.count]
  }
}

struct RedactedTextLine: Equatable, Sendable {
  let text: String
  let redacted: Bool
}

enum ProjectSecretRedactor {
  static let replacement = "[REDACTED: suspected secret]"

  static func redact(_ line: String) -> RedactedTextLine {
    guard isSuspectedSecret(line) else {
      return RedactedTextLine(text: line, redacted: false)
    }
    return RedactedTextLine(text: replacement, redacted: true)
  }

  private static func isSuspectedSecret(_ line: String) -> Bool {
    let lowercased = line.lowercased()
    if lowercased.contains("-----begin ") && lowercased.contains("private key-----") {
      return true
    }
    if containsCredentialAssignment(lowercased) {
      return true
    }
    return containsTokenPrefix(lowercased)
  }

  private static func containsCredentialAssignment(_ line: String) -> Bool {
    let names = [
      "api_key", "apikey", "access_token", "refresh_token", "client_secret",
      "password", "passwd", "secret_key", "runtime_key",
    ]
    return names.contains { name in
      hasNonemptyValue(after: "\(name)=", in: line)
        || hasNonemptyValue(after: "\(name):", in: line)
    }
  }

  private static func containsTokenPrefix(_ line: String) -> Bool {
    let prefixes = ["bearer ", "sk-", "ghp_", "gho_", "github_pat_", "xoxb-", "xoxp-"]
    return prefixes.contains { prefix in
      guard let range = line.range(of: prefix) else { return false }
      return line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).count >= 12
    }
  }

  private static func hasNonemptyValue(after marker: String, in line: String) -> Bool {
    guard let range = line.range(of: marker) else { return false }
    let value = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    return value.count >= 8
  }
}
