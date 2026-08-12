import Foundation

struct RedactedValue: Equatable, Sendable {
  let value: String
  let count: Int
}

struct SensitiveDataRedactor: Sendable {
  private static let secretPlaceholder = "[REDACTED_SECRET]"
  private static let pathPlaceholder = "[REDACTED_PATH]"

  private let sensitiveValues: [String]

  init(policy: ReportingRedactionPolicy) {
    sensitiveValues = policy.sensitiveValues
      .filter { !$0.isEmpty }
      .sorted {
        if $0.utf8.count == $1.utf8.count { return $0 < $1 }
        return $0.utf8.count > $1.utf8.count
      }
  }

  func redact(_ input: String) -> RedactedValue {
    var result = replacingSensitiveValues(in: input)
    for rule in Self.rules {
      result = replacingRegex(in: result, pattern: rule.pattern, template: rule.template)
    }
    return result
  }

  func redactPath(_ path: String) -> RedactedValue {
    guard !isSensitivePath(path) else {
      return RedactedValue(value: Self.pathPlaceholder, count: 1)
    }
    return redact(path)
  }

  private func replacingSensitiveValues(in input: String) -> RedactedValue {
    guard !sensitiveValues.isEmpty else { return RedactedValue(value: input, count: 0) }
    var output = ""
    output.reserveCapacity(input.utf8.count)
    var cursor = input.startIndex
    var replacements = 0
    while cursor < input.endIndex {
      guard let match = earliestSensitiveMatch(in: input, from: cursor) else {
        output.append(contentsOf: input[cursor...])
        break
      }
      output.append(contentsOf: input[cursor..<match.lowerBound])
      output.append(Self.secretPlaceholder)
      cursor = match.upperBound
      replacements += 1
    }
    return RedactedValue(value: output, count: replacements)
  }

  private func earliestSensitiveMatch(
    in input: String,
    from cursor: String.Index
  ) -> Range<String.Index>? {
    var selected: Range<String.Index>?
    for secret in sensitiveValues {
      guard let candidate = input.range(of: secret, range: cursor..<input.endIndex) else {
        continue
      }
      guard let current = selected else {
        selected = candidate
        continue
      }
      if candidate.lowerBound < current.lowerBound
        || (candidate.lowerBound == current.lowerBound
          && candidate.upperBound > current.upperBound)
      {
        selected = candidate
      }
    }
    return selected
  }

  private func replacingRegex(
    in input: RedactedValue,
    pattern: String,
    template: String
  ) -> RedactedValue {
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return input }
    let range = NSRange(input.value.startIndex..., in: input.value)
    let matches = expression.numberOfMatches(in: input.value, range: range)
    guard matches > 0 else { return input }
    return RedactedValue(
      value: expression.stringByReplacingMatches(
        in: input.value,
        range: range,
        withTemplate: template
      ),
      count: input.count + matches
    )
  }

  private func isSensitivePath(_ path: String) -> Bool {
    let normalized = path.replacingOccurrences(of: "\\", with: "/")
    guard !normalized.isEmpty else { return false }
    if normalized.hasPrefix("/") || normalized.hasPrefix("~/")
      || normalized.lowercased().hasPrefix("file://")
    {
      return true
    }
    let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
      .map { $0.lowercased() }
    if components.contains("..") { return true }
    return components.contains(where: Self.isSensitiveComponent)
  }

  private static func isSensitiveComponent(_ component: String) -> Bool {
    if component == ".env" || component.hasPrefix(".env.") { return true }
    if [".ssh", "secrets", "keychains", "cookies", "login data", "auth.json"]
      .contains(component)
    {
      return true
    }
    return [".pem", ".key", ".p12", ".mobileprovision"].contains {
      component.hasSuffix($0)
    }
  }

  private static let rules: [(pattern: String, template: String)] = [
    (
      #"-----BEGIN(?: [A-Z0-9]+)* PRIVATE KEY-----[\s\S]*?-----END(?: [A-Z0-9]+)* PRIVATE KEY-----"#,
      secretPlaceholder
    ),
    (#"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+"#, "Bearer \(secretPlaceholder)"),
    (#"\bsk[-_][A-Za-z0-9_-]{12,}\b"#, secretPlaceholder),
    (
      #"(?i)[\"']?(authorization|cookie|access[_-]?token|refresh[_-]?token|password|passwd|secret|api[_-]?key|runtime[_-]?key)[\"']?\s*[:=]\s*(?:\"[^\"]*\"|'[^']*'|[^\s,;]+)"#,
      "$1=\(secretPlaceholder)"
    ),
    (
      #"(?<![A-Za-z0-9:])(?:~|/(?:Users|Volumes|private|var|tmp|etc|opt|Library))(?:/[A-Za-z0-9._@%+~ -]+)+"#,
      pathPlaceholder
    ),
    (
      #"(?i)(^|[\s\"'=:(])(?:[^\s\"']*/)?(?:\.env(?:\.[^\s\"']+)?|[^/\s\"']+\.(?:pem|key|p12|mobileprovision)|auth\.json)(?=$|[\s\"'),;])"#,
      "$1\(pathPlaceholder)"
    ),
  ]
}
