import Foundation

extension AgentMarkdownText {
  nonisolated static func safePlainTextFallback(from content: String) -> String {
    let characters = Array(content)
    var result = ""
    var index = 0
    var lineStart = true
    var codeMode: PlainCodeMode?

    while index < characters.count {
      if codeMode == nil, lineStart,
        let afterPrefix = structuralPrefixEnd(in: characters, from: index)
      {
        index = afterPrefix
        lineStart = false
        continue
      }

      let character = characters[index]
      if character == "\\", codeMode == nil,
        index + 1 < characters.count,
        "*_~`#[]()\\|".contains(characters[index + 1])
      {
        result.append(characters[index + 1])
        index += 2
        lineStart = false
        continue
      }
      if character == "`" {
        let run = fallbackMarkerRunLength("`", at: index, in: characters)
        switch codeMode {
        case nil:
          codeMode = run >= 3 ? .fenced : .inline
          index += run
          lineStart = false
        case .inline:
          codeMode = nil
          index += min(run, 1)
          lineStart = false
        case .fenced:
          if run >= 3 {
            codeMode = nil
            index += run
          } else {
            result += String(repeating: "`", count: run)
            index += run
          }
          lineStart = false
        }
        continue
      }

      if codeMode == nil, character == "!", index + 1 < characters.count,
        characters[index + 1] == "["
      {
        index += 1
        continue
      }
      if codeMode == nil, character == "[",
        let link = linkRange(in: characters, from: index)
      {
        result += String(characters[(index + 1)..<link.labelEnd])
        index = link.destinationEnd + 1
        lineStart = false
        continue
      }
      if codeMode == nil, character == "*" || character == "_" || character == "~" {
        let run = fallbackMarkerRunLength(character, at: index, in: characters)
        if run >= 2 || hasClosingMarker(character, after: index + run, in: characters) {
          index += run
          lineStart = false
          continue
        }
      }

      result.append(character)
      lineStart = character == "\n" || (lineStart && character.isWhitespace)
      index += 1
    }
    return result
  }

  private enum PlainCodeMode {
    case inline
    case fenced
  }

  nonisolated private static func structuralPrefixEnd(
    in characters: [Character],
    from index: Int
  ) -> Int? {
    var cursor = index
    while cursor < characters.count, cursor - index < 3, characters[cursor] == " " {
      cursor += 1
    }
    guard cursor < characters.count else { return nil }
    let marker = characters[cursor]
    if marker == "#" {
      let run = fallbackMarkerRunLength("#", at: cursor, in: characters)
      guard run <= 6,
        cursor + run == characters.count || characters[cursor + run].isWhitespace
      else { return nil }
      cursor += run
    } else if marker == "-" || marker == "+" || marker == "*" {
      guard cursor + 1 < characters.count, characters[cursor + 1].isWhitespace else {
        return nil
      }
      cursor += 1
    } else if marker.isNumber {
      var digitsEnd = cursor
      while digitsEnd < characters.count, characters[digitsEnd].isNumber { digitsEnd += 1 }
      guard digitsEnd < characters.count,
        characters[digitsEnd] == "." || characters[digitsEnd] == ")",
        digitsEnd + 1 < characters.count,
        characters[digitsEnd + 1].isWhitespace
      else { return nil }
      cursor = digitsEnd + 1
    } else {
      return nil
    }
    while cursor < characters.count, characters[cursor].isWhitespace,
      characters[cursor] != "\n"
    {
      cursor += 1
    }
    return cursor
  }

  nonisolated private static func linkRange(
    in characters: [Character],
    from index: Int
  ) -> (labelEnd: Int, destinationEnd: Int)? {
    guard let labelEnd = characters[(index + 1)...].firstIndex(of: "]"),
      labelEnd + 1 < characters.count,
      characters[labelEnd + 1] == "("
    else { return nil }
    guard let destinationEnd = characters[(labelEnd + 2)...].firstIndex(of: ")") else {
      return nil
    }
    return (labelEnd, destinationEnd)
  }

  nonisolated private static func hasClosingMarker(
    _ marker: Character,
    after index: Int,
    in characters: [Character]
  ) -> Bool {
    guard index < characters.count else { return false }
    var cursor = index
    while cursor < characters.count {
      if characters[cursor] == marker,
        cursor == 0 || characters[cursor - 1] != "\\"
      {
        return true
      }
      cursor += 1
    }
    return false
  }

  nonisolated private static func fallbackMarkerRunLength(
    _ marker: Character,
    at index: Int,
    in characters: [Character]
  ) -> Int {
    var end = index
    while end < characters.count, characters[end] == marker { end += 1 }
    return end - index
  }
}
