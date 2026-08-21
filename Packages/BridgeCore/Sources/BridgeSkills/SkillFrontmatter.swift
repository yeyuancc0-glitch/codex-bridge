import Foundation

/// A focused YAML subset parser for `SKILL.md` frontmatter.
///
/// It supports the constructs that actually appear in real-world Skill metadata:
/// plain / single / double-quoted scalars, `>` and `|` block scalars, inline
/// arrays, block sequences (`- item`), block mappings and nested mappings, and
/// comments. It deliberately rejects aliases/anchors, tags and multi-document
/// streams rather than silently misreading them.
enum SkillFrontmatter {
  /// Parsed YAML node values used only inside the scanner.
  enum Node {
    case scalar(String)
    case sequence([Node])
    case mapping([(String, Node)])
  }

  struct Error: Swift.Error, Equatable {
    let line: Int
    let message: String
  }

  /// Parse the YAML block between the leading and trailing `---` delimiters.
  /// Returns `nil` when there is no valid frontmatter fence.
  static func parse(_ text: String) throws -> Node? {
    let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else {
      return nil
    }
    guard
      let endIndex = lines.dropFirst().firstIndex(where: {
        $0.trimmingCharacters(in: .whitespaces) == "---"
      })
    else {
      throw Error(line: 1, message: "unterminated frontmatter")
    }
    let body = Array(lines[1..<endIndex]).map(String.init)
    guard !body.isEmpty else { return Node.mapping([]) }
    return try parseBlock(body, baseIndent: 0, lineOffset: 1)
  }

  /// Parse a sequence of lines at a given indentation into a mapping or sequence.
  private static func parseBlock(
    _ lines: [String], baseIndent: Int, lineOffset: Int
  ) throws -> Node {
    let content = lines.filter { isContent($0) }
    guard let firstContent = content.first else { return Node.mapping([]) }
    let indent = indentation(of: firstContent)
    guard indent >= baseIndent else {
      throw Error(line: lineOffset + lines.firstIndex(of: firstContent)!, message: "bad indent")
    }
    if isSequenceItem(firstContent.trimmingCharacters(in: .whitespaces)) {
      return try parseSequence(lines, indent: indent, lineOffset: lineOffset)
    }
    return try parseMapping(lines, indent: indent, lineOffset: lineOffset)
  }

  private static func parseMapping(
    _ lines: [String], indent: Int, lineOffset: Int
  ) throws -> Node {
    var result: [(String, Node)] = []
    var index = 0
    while index < lines.count {
      let line = lines[index]
      if !isContent(line) {
        index += 1
        continue
      }
      let currentIndent = indentation(of: line)
      if currentIndent < indent { break }
      if currentIndent > indent {
        throw Error(line: lineOffset + index, message: "unexpected indent")
      }
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard let keyEnd = keyEndIndex(of: trimmed) else {
        throw Error(line: lineOffset + index, message: "expected key: value")
      }
      let key = unquote(String(trimmed[..<keyEnd]))
      let rest = String(trimmed[trimmed.index(after: keyEnd)...])
      index += 1

      let trimmedRest = rest.trimmingCharacters(in: .whitespaces)
      if trimmedRest.isEmpty {
        // Value is the following more-indented block, or a sequence whose items
        // sit at the same column as this key (a common block-mapping idiom).
        let (valueLines, nextIndex) = collectValueLines(
          lines, from: index, keyIndent: indent)
        index = nextIndex
        if valueLines.isEmpty {
          result.append((key, .scalar("")))
        } else {
          result.append(
            (
              key,
              try parseBlock(
                valueLines, baseIndent: indent,
                lineOffset: lineOffset + nextIndex - valueLines.count)
            ))
        }
      } else if isBlockScalarMarker(trimmedRest) {
        let literal = trimmedRest.hasPrefix("|")
        var blockLines: [String] = []
        while index < lines.count {
          let candidate = lines[index]
          if isContent(candidate), indentation(of: candidate) <= indent { break }
          blockLines.append(candidate)
          index += 1
        }
        result.append((key, .scalar(blockScalarValue(blockLines, literal: literal))))
      } else {
        result.append((key, try parseValue(token: trimmedRest, line: lineOffset + index - 1)))
      }
    }
    return .mapping(result)
  }

  private static func parseSequence(
    _ lines: [String], indent: Int, lineOffset: Int
  ) throws -> Node {
    var result: [Node] = []
    var index = 0
    while index < lines.count {
      let line = lines[index]
      if !isContent(line) {
        index += 1
        continue
      }
      let currentIndent = indentation(of: line)
      if currentIndent < indent { break }
      if currentIndent > indent {
        throw Error(line: lineOffset + index, message: "unexpected indent")
      }
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard isSequenceItem(trimmed) else { break }
      let itemText = trimmed.drop(while: { $0 == "-" }).trimmingCharacters(in: .whitespaces)
      index += 1
      if itemText.isEmpty {
        var blockLines: [String] = []
        while index < lines.count && !isContent(lines[index]) { index += 1 }
        while index < lines.count && indentation(of: lines[index]) > indent {
          blockLines.append(lines[index])
          index += 1
        }
        result.append(
          try parseBlock(
            blockLines, baseIndent: indent, lineOffset: lineOffset + index - blockLines.count))
      } else if keyEndIndex(of: itemText) != nil {
        // Sequence item is a mapping: the first token is `key: value`, and any
        // following more-indented lines belong to the same mapping.
        let keyIndent = currentIndent + 2
        var mappingLines = [String(repeating: " ", count: keyIndent) + itemText]
        while index < lines.count && indentation(of: lines[index]) > indent {
          mappingLines.append(lines[index])
          index += 1
        }
        result.append(
          try parseMapping(
            mappingLines, indent: keyIndent, lineOffset: lineOffset + index - mappingLines.count))
      } else {
        result.append(try parseValue(token: itemText, line: lineOffset + index - 1))
      }
    }
    return .sequence(result)
  }

  private static func parseValue(token: String, line: Int) throws -> Node {
    if token.hasPrefix("[") {
      guard token.hasSuffix("]") else {
        throw Error(line: line, message: "unterminated inline sequence")
      }
      let inner = token.dropFirst().dropLast()
      let parts = splitInline(inner)
      return .sequence(parts.map { .scalar(unquote($0.trimmingCharacters(in: .whitespaces))) })
    }
    if token.hasPrefix("{") {
      throw Error(line: line, message: "inline mappings are not supported")
    }
    return .scalar(unquote(token))
  }

  private static func splitInline(_ text: Substring) -> [Substring] {
    var result: [Substring] = []
    var current = text.startIndex
    var quote: Character?
    var depth = 0
    for (offset, character) in text.enumerated() {
      let index = text.index(text.startIndex, offsetBy: offset)
      if let q = quote {
        if character == q { quote = nil }
      } else if character == "\"" || character == "'" {
        quote = character
      } else if character == "[" || character == "{" {
        depth += 1
      } else if character == "]" || character == "}" {
        depth -= 1
      } else if character == "," && depth == 0 {
        result.append(text[current..<index])
        current = text.index(after: index)
      }
    }
    result.append(text[current...])
    return result
  }

  private static func keyEndIndex(of trimmed: String) -> String.Index? {
    var quote: Character?
    for (offset, character) in trimmed.enumerated() {
      let index = trimmed.index(trimmed.startIndex, offsetBy: offset)
      if let q = quote {
        if character == q { quote = nil }
      } else if character == "\"" || character == "'" {
        quote = character
      } else if character == ":" {
        let after = trimmed.index(after: index)
        if after < trimmed.endIndex {
          let next = trimmed[after]
          if next == " " || next == "\t" { return index }
        } else {
          return index
        }
      }
    }
    return nil
  }

  private static func unquote(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    if trimmed.count >= 2,
      let first = trimmed.first, let last = trimmed.last,
      (first == "\"" && last == "\"") || (first == "'" && last == "'")
    {
      return String(trimmed.dropFirst().dropLast())
    }
    return trimmed
  }

  private static func isContent(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return false }
    return !trimmed.hasPrefix("#")
  }

  /// Collect the lines belonging to a mapping key's block value, starting at
  /// `start`. Includes more-indented lines, plus sequence items sitting at the
  /// same column as the key (and their deeper continuation lines). Returns the
  /// collected lines and the index just past them.
  private static func collectValueLines(
    _ lines: [String], from start: Int, keyIndent: Int
  ) -> ([String], Int) {
    var index = start
    while index < lines.count && !isContent(lines[index]) { index += 1 }
    var collected: [String] = []
    var collecting = true
    while collecting, index < lines.count {
      let line = lines[index]
      let lineIndent = indentation(of: line)
      if lineIndent > keyIndent {
        collected.append(line)
        index += 1
      } else if lineIndent == keyIndent
        && isSequenceItem(line.trimmingCharacters(in: .whitespaces))
      {
        collected.append(line)
        index += 1
        // Also take the deeper-indented continuation lines of this item.
        while index < lines.count && indentation(of: lines[index]) > keyIndent {
          collected.append(lines[index])
          index += 1
        }
      } else {
        collecting = false
      }
    }
    return (collected, index)
  }

  private static func isBlockScalarMarker(_ token: String) -> Bool {
    ["|", ">", "|-", ">-", "|+", ">+"].contains(token)
  }

  private static func blockScalarValue(_ lines: [String], literal: Bool) -> String {
    let contentIndent = lines.filter(isContent).map(indentation).min() ?? 0
    let content = lines.map { line in
      guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
      return String(line.dropFirst(min(contentIndent, line.count)))
        .trimmingCharacters(in: .whitespaces)
    }
    if literal {
      return content.joined(separator: "\n")
    }
    var folded = ""
    for line in content {
      if line.isEmpty {
        if !folded.isEmpty, !folded.hasSuffix("\n") { folded.append("\n") }
      } else {
        if !folded.isEmpty, !folded.hasSuffix("\n") { folded.append(" ") }
        folded.append(line)
      }
    }
    return folded.trimmingCharacters(in: .newlines)
  }

  private static func isSequenceItem(_ trimmed: String) -> Bool {
    trimmed.hasPrefix("-")
      && (trimmed.count == 1 || trimmed.dropFirst().first?.isWhitespace == true)
  }

  private static func indentation(of line: String) -> Int {
    line.prefix(while: { $0 == " " || $0 == "\t" }).count
  }
}

extension SkillFrontmatter.Node {
  func scalar(_ key: String) -> String? {
    guard case .mapping(let pairs) = self else { return nil }
    for (k, v) in pairs where k == key {
      if case .scalar(let s) = v { return s }
      return nil
    }
    return nil
  }

  func stringArray(_ key: String) -> [String] {
    guard case .mapping(let pairs) = self else { return [] }
    for (k, v) in pairs where k == key {
      return Self.flattenStrings(v)
    }
    return []
  }

  private static func flattenStrings(_ node: SkillFrontmatter.Node) -> [String] {
    switch node {
    case .scalar(let s):
      return [s]
    case .sequence(let items):
      return items.flatMap(flattenStrings)
    case .mapping(let pairs):
      if pairs.count == 1, case .scalar(let s) = pairs[0].1 {
        return ["\(pairs[0].0): \(s)"]
      }
      var result: [String] = []
      for (k, v) in pairs {
        if case .scalar(let s) = v {
          result.append("\(k): \(s)")
        } else {
          result.append(k + ":")
          result.append(contentsOf: flattenStrings(v))
        }
      }
      return result
    }
  }

  func actionEntries(_ key: String) -> [(String, SkillFrontmatter.Node)] {
    guard case .mapping(let pairs) = self else { return [] }
    for (k, v) in pairs where k == key {
      if case .sequence(let items) = v {
        return items.enumerated().map { (String($0.offset), $0.element) }
      }
    }
    return []
  }

  func childMapping(_ key: String) -> SkillFrontmatter.Node? {
    guard case .mapping(let pairs) = self else { return nil }
    for (k, v) in pairs where k == key {
      if case .mapping = v { return v }
    }
    return nil
  }
}
