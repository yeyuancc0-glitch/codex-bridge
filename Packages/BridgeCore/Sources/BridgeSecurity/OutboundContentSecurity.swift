import Foundation

public struct OutboundRedaction: Equatable, Sendable {
  public let text: String
  public let redactedLineCount: Int
  public let truncated: Bool

  public var changed: Bool {
    redactedLineCount > 0 || truncated
  }
}

public enum OutboundContentSecurity {
  private static let forbiddenPatterns = [
    #"(?i)-----BEGIN(?: [A-Z0-9]+)* PRIVATE KEY-----"#,
    #"(?i)\bBearer\s+[^\s,;]+"#,
    #"(?i)\b(?:sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9_]{16,}|github_pat_[A-Za-z0-9_]{16,})\b"#,
    #"(?i)["']?(?:authorization|cookie|client[_-]?secret|api[_-]?key|runtime[_-]?key|access[_-]?token|refresh[_-]?token|password|passwd|secret(?:[_-]?key)?)["']?\s*[:=]\s*(?:"[^"\r\n]+"|'[^'\r\n]+'|[^\s,;]+)"#,
    #"(?i)"?x-codex-bridge-token"?\s*[:=]\s*"[^"\r\n]*""#,
    #"(?i)\bx-codex-bridge-token\b(?:\s*[:=]\s*[^\s,;]+)?"#,
    #"(?i)\bx-codex-(?:token|auth|mcp-auth|runtime-key)\b(?:\s*[:=]\s*[^\s,;]+)?"#,
    #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#,
  ]

  private static let safeHTTPPattern = try! NSRegularExpression(
    pattern:
      #"(?i)(^|[\s\(\[\{<"'=,;])https?://(?:localhost|[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?)(?::[0-9]{1,5})?(?:[/\?#][^\s\)\]\}>"']*)?"#
  )
  private static let regularExpressionLiteralPattern = try! NSRegularExpression(
    pattern:
      #"(?x)(?:^|[\s=\(\[,!:?;{}])/(?:\\.|[^/\\\r\n])+/[dgimsuvy]+|(?:^|[\s=\(\[,!:?;{}])/(?:\\.|[^/\\\r\n])+/(?=\.(?:test|exec|match|replace)\s*\()"#
  )

  public static func isSafe(_ value: String) -> Bool {
    guard !containsUnsafePath(value) else { return false }
    return !forbiddenPatterns.contains { pattern in
      value.range(of: pattern, options: .regularExpression) != nil
    }
  }

  /// Checks only the secret patterns (keys, tokens, credentials) without the
  /// local-path heuristic. Used for structured payloads like patch text whose
  /// markers (`*** Add File: x`) legitimately contain `file:`-like text.
  public static func isSafeSecrets(_ value: String) -> Bool {
    !forbiddenPatterns.contains { pattern in
      value.range(of: pattern, options: .regularExpression) != nil
    }
  }

  public static func isSafeRelativePath(
    _ value: String,
    maximumUTF8Bytes: Int = 1_024
  ) -> Bool {
    guard maximumUTF8Bytes > 0, value.utf8.count <= maximumUTF8Bytes,
      !value.contains("\\"),
      value.rangeOfCharacter(from: .controlCharacters) == nil
    else { return false }
    return (try? SecureRelativePath(value)) != nil
  }

  public static func isSafeOutboundRelativePath(
    _ value: String,
    maximumUTF8Bytes: Int = 1_024
  ) -> Bool {
    isSafeRelativePath(value, maximumUTF8Bytes: maximumUTF8Bytes) && isSafe(value)
  }

  public static func redacted(_ value: String, maximumUTF8Bytes: Int) -> String {
    redaction(of: value, maximumUTF8Bytes: maximumUTF8Bytes).text
  }

  public static func redaction(
    of value: String,
    maximumUTF8Bytes: Int,
    preservingSourceSyntax: Bool = false
  ) -> OutboundRedaction {
    precondition(maximumUTF8Bytes > 0)
    var insidePrivateKey = false
    var redactedLineCount = 0
    let redacted = value.split(separator: "\n", omittingEmptySubsequences: false).map { part in
      let line = String(part)
      let privateKeyLine = redactPrivateKeyLine(line, insideBlock: &insidePrivateKey)
      let secretsRedacted = forbiddenPatterns.reduce(privateKeyLine) { result, pattern in
        result.replacingOccurrences(
          of: pattern,
          with: "[REDACTED]",
          options: .regularExpression
        )
      }
      let pathRedacted = redactUnsafePath(
        in: secretsRedacted,
        preservingSourceSyntax: preservingSourceSyntax
      )
      if pathRedacted != line {
        redactedLineCount += 1
      }
      return pathRedacted
    }.joined(separator: "\n")
    guard redacted.utf8.count > maximumUTF8Bytes else {
      return OutboundRedaction(
        text: redacted,
        redactedLineCount: redactedLineCount,
        truncated: false
      )
    }
    let suffix = "…"
    let includesSuffix = maximumUTF8Bytes > suffix.utf8.count
    let prefixLimit = includesSuffix ? maximumUTF8Bytes - suffix.utf8.count : maximumUTF8Bytes
    var prefix = ""
    for character in redacted {
      guard prefix.utf8.count + character.utf8.count <= prefixLimit else { break }
      prefix.append(character)
    }
    return OutboundRedaction(
      text: includesSuffix ? prefix + suffix : prefix,
      redactedLineCount: redactedLineCount,
      truncated: true
    )
  }

  private static func containsUnsafePath(_ value: String) -> Bool {
    value.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
      unsafePathStart(in: String(line), preservingSourceSyntax: false) != nil
    }
  }

  private static func redactUnsafePath(
    in line: String,
    preservingSourceSyntax: Bool
  ) -> String {
    guard
      let start = unsafePathStart(
        in: line,
        preservingSourceSyntax: preservingSourceSyntax
      )
    else { return line }
    return String(line[..<start]) + "[REDACTED]"
  }

  private static func unsafePathStart(
    in line: String,
    preservingSourceSyntax: Bool
  ) -> String.Index? {
    var earliest = line.range(of: #"(?i)\bfile\s*:"#, options: .regularExpression)?.lowerBound
    if let home = line.range(of: "~/")?.lowerBound {
      earliest = earlier(earliest, home)
    }
    let safeRanges = safeRanges(in: line, preservingSourceSyntax: preservingSourceSyntax)
    var safeRangeIndex = 0
    var index = line.startIndex
    while index < line.endIndex {
      defer { index = line.index(after: index) }
      while safeRangeIndex < safeRanges.count,
        index >= safeRanges[safeRangeIndex].upperBound
      {
        safeRangeIndex += 1
      }
      let isInsideSafeHTTPRange =
        safeRangeIndex < safeRanges.count && safeRanges[safeRangeIndex].contains(index)
      guard line[index] == "/", !isInsideSafeHTTPRange else { continue }
      let next = line.index(after: index)
      if next < line.endIndex, line[next] == "/" {
        earliest = earlier(earliest, index)
        continue
      }
      if next < line.endIndex, line[next].isWhitespace {
        continue
      }
      guard index == line.startIndex || !isRelativePathPrefix(line[line.index(before: index)])
      else { continue }
      earliest = earlier(earliest, index)
    }
    return earliest
  }

  private static func safeRanges(
    in line: String,
    preservingSourceSyntax: Bool
  ) -> [Range<String.Index>] {
    let fullRange = NSRange(line.startIndex..<line.endIndex, in: line)
    var ranges = safeHTTPPattern.matches(in: line, range: fullRange).compactMap { match in
      Range(match.range, in: line)
    }
    if preservingSourceSyntax {
      let strings = stringLiteralRanges(in: line)
      ranges.append(contentsOf: sourceDelimiterRanges(in: line, outside: strings))
      ranges.append(
        contentsOf: rangesOutsideStrings(
          regularExpressionLiteralPattern.matches(in: line, range: fullRange),
          in: line,
          strings: strings
        )
      )
    }
    return
      ranges
      .sorted { $0.lowerBound < $1.lowerBound }
  }

  private static func stringLiteralRanges(in line: String) -> [Range<String.Index>] {
    var ranges: [Range<String.Index>] = []
    var start: String.Index?
    var quote: Character?
    var escaped = false
    var index = line.startIndex
    while index < line.endIndex {
      let character = line[index]
      if let activeQuote = quote {
        if escaped {
          escaped = false
        } else if character == "\\" {
          escaped = true
        } else if character == activeQuote {
          let end = line.index(after: index)
          ranges.append((start ?? index)..<end)
          start = nil
          quote = nil
        }
      } else if character == "\"" || character == "'" {
        start = index
        quote = character
      }
      index = line.index(after: index)
    }
    if let start {
      ranges.append(start..<line.endIndex)
    }
    return ranges
  }

  private static func sourceDelimiterRanges(
    in line: String,
    outside strings: [Range<String.Index>]
  ) -> [Range<String.Index>] {
    var ranges: [Range<String.Index>] = []
    var stringIndex = 0
    var index = line.startIndex
    while index < line.endIndex {
      defer { index = line.index(after: index) }
      while stringIndex < strings.count, index >= strings[stringIndex].upperBound {
        stringIndex += 1
      }
      let insideString = stringIndex < strings.count && strings[stringIndex].contains(index)
      guard line[index] == "/", !insideString else { continue }
      if index > line.startIndex, line[line.index(before: index)] == "*" {
        ranges.append(index..<line.index(after: index))
        continue
      }
      let next = line.index(after: index)
      guard next < line.endIndex else { continue }
      if line[next] == "/", isRecognizedLineComment(in: line, after: next) {
        ranges.append(index..<line.index(after: next))
      } else if line[next] == "*", isSpacedDelimiter(in: line, after: next) {
        ranges.append(index..<line.index(after: index))
      }
    }
    return ranges
  }

  private static func rangesOutsideStrings(
    _ matches: [NSTextCheckingResult],
    in line: String,
    strings: [Range<String.Index>]
  ) -> [Range<String.Index>] {
    var ranges: [Range<String.Index>] = []
    var stringIndex = 0
    for match in matches {
      guard let range = Range(match.range, in: line),
        let slash = line[range].firstIndex(of: "/")
      else { continue }
      while stringIndex < strings.count, slash >= strings[stringIndex].upperBound {
        stringIndex += 1
      }
      let insideString = stringIndex < strings.count && strings[stringIndex].contains(slash)
      if !insideString {
        ranges.append(range)
      }
    }
    return ranges
  }

  private static func isRecognizedLineComment(
    in line: String,
    after secondSlash: String.Index
  ) -> Bool {
    let content = line.index(after: secondSlash)
    guard content < line.endIndex else { return true }
    if line[content].isWhitespace { return true }
    if line[content] == "/" {
      let afterDocMarker = line.index(after: content)
      return afterDocMarker == line.endIndex || line[afterDocMarker].isWhitespace
    }
    let suffix = line[content...].uppercased()
    return suffix.hasPrefix("TODO:") || suffix.hasPrefix("FIXME:") || suffix.hasPrefix("MARK:")
  }

  private static func isSpacedDelimiter(
    in line: String,
    after markerEnd: String.Index
  ) -> Bool {
    let content = line.index(after: markerEnd)
    return content == line.endIndex || line[content].isWhitespace
  }

  private static func redactPrivateKeyLine(
    _ line: String,
    insideBlock: inout Bool
  ) -> String {
    let uppercased = line.uppercased()
    let begins =
      uppercased.range(
        of: #"-----BEGIN(?: [A-Z0-9]+)* PRIVATE KEY-----"#,
        options: .regularExpression
      ) != nil
    let ends =
      uppercased.range(
        of: #"-----END(?: [A-Z0-9]+)* PRIVATE KEY-----"#,
        options: .regularExpression
      ) != nil
    guard begins || insideBlock else { return line }
    insideBlock = !ends
    return "[REDACTED]"
  }

  private static func earlier(
    _ current: String.Index?,
    _ candidate: String.Index
  ) -> String.Index {
    guard let current else { return candidate }
    return min(current, candidate)
  }

  private static func isRelativePathPrefix(_ character: Character) -> Bool {
    // A slash preceded by an alphanumeric character (any script, including
    // CJK) is part of prose like "原创帖/回复" rather than an absolute path;
    // only slash preceded by whitespace/line start or punctuation may begin a
    // local path such as "/Users/me".
    if character.isLetter || character.isNumber {
      return true
    }
    return "._~/-".contains(character)
  }
}
