#if os(Windows)
  import Foundation

  extension OutboundContentSecurity {
    static func windowsUnsafeAbsolutePathStart(
      in line: String,
      safeRanges: [Range<String.Index>]
    ) -> String.Index? {
      var index = line.startIndex
      while index < line.endIndex {
        if !safeRanges.contains(where: { $0.contains(index) }),
          isWindowsPathBoundary(in: line, at: index),
          isWindowsDrivePath(in: line, at: index)
            || isWindowsUNCPath(in: line, at: index)
            || isWindowsRootedPath(in: line, at: index)
        {
          return index
        }
        index = line.index(after: index)
      }
      return nil
    }

    static func windowsStartsWithAbsolutePath(_ value: Substring) -> Bool {
      let string = String(value)
      return windowsUnsafeAbsolutePathStart(in: string, safeRanges: []) == string.startIndex
    }

    private static func isWindowsPathBoundary(in line: String, at index: String.Index) -> Bool {
      guard index > line.startIndex else { return true }
      let previous = line[line.index(before: index)]
      return !previous.isLetter && !previous.isNumber && previous != "_"
    }

    private static func isWindowsDrivePath(in line: String, at index: String.Index) -> Bool {
      guard line[index].isASCII, line[index].isLetter else { return false }
      let colon = line.index(after: index)
      guard colon < line.endIndex, line[colon] == ":" else { return false }
      let separator = line.index(after: colon)
      return separator < line.endIndex && isWindowsSeparator(line[separator])
    }

    private static func isWindowsUNCPath(in line: String, at index: String.Index) -> Bool {
      guard isWindowsSeparator(line[index]) else { return false }
      let second = line.index(after: index)
      guard second < line.endIndex, isWindowsSeparator(line[second]) else { return false }

      var cursor = line.index(after: second)
      guard cursor < line.endIndex, !isWindowsSeparator(line[cursor]), !line[cursor].isWhitespace
      else { return false }
      while cursor < line.endIndex, !isWindowsSeparator(line[cursor]) {
        cursor = line.index(after: cursor)
      }
      guard cursor < line.endIndex else { return false }
      while cursor < line.endIndex, isWindowsSeparator(line[cursor]) {
        cursor = line.index(after: cursor)
      }
      return cursor < line.endIndex && !line[cursor].isWhitespace
    }

    private static func isWindowsRootedPath(in line: String, at index: String.Index) -> Bool {
      guard line[index] == "\\",
        index == line.startIndex
          || !isWindowsSeparator(line[line.index(before: index)])
      else { return false }
      let next = line.index(after: index)
      guard next < line.endIndex, !isWindowsSeparator(line[next]), !line[next].isWhitespace
      else { return false }
      return true
    }

    private static func isWindowsSeparator(_ character: Character) -> Bool {
      character == "/" || character == "\\"
    }
  }
#endif
