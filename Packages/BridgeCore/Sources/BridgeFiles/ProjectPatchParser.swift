import BridgeSecurity
import Foundation

public enum ProjectPatchParserError: Error, Equatable, Sendable {
  case missingBeginMarker
  case missingEndMarker
  case malformedFileHeader
  case absolutePath
  case duplicatePath
  case emptyPatch
}

public enum ProjectPatchParser {
  public static func parse(_ text: String) throws -> [ProjectPatchFileOperation] {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard let beginIndex = lines.firstIndex(where: { $0 == "*** Begin Patch" }) else {
      throw ProjectPatchParserError.missingBeginMarker
    }
    guard let endIndex = lines.lastIndex(where: { $0 == "*** End Patch" }),
      endIndex > beginIndex
    else {
      throw ProjectPatchParserError.missingEndMarker
    }

    var operations: [ProjectPatchFileOperation] = []
    var paths = Set<String>()
    var index = beginIndex + 1
    while index < endIndex {
      let header = lines[index]
      guard header.hasPrefix("*** ") else {
        index += 1
        continue
      }
      guard
        let operation = try parseFile(
          header: header, lines: lines, from: index + 1, until: endIndex)
      else {
        index += 1
        continue
      }
      guard paths.insert(operation.operation.relativePath).inserted else {
        throw ProjectPatchParserError.duplicatePath
      }
      operations.append(operation.operation)
      index = operation.endLine + 1
    }
    guard !operations.isEmpty else { throw ProjectPatchParserError.emptyPatch }
    return operations
  }

  private static func parseFile(
    header: String,
    lines: [String],
    from start: Int,
    until end: Int
  ) throws -> ParsedOperation? {
    guard header.hasPrefix("*** Update File: ") || header.hasPrefix("*** Add File: ") else {
      return nil
    }
    let isAdd = header.hasPrefix("*** Add File: ")
    let path = String(header.dropFirst(isAdd ? "*** Add File: ".count : "*** Update File: ".count))
    guard !path.isEmpty, !path.hasPrefix("/") else {
      throw ProjectPatchParserError.absolutePath
    }

    var hunks: [ProjectPatchHunk] = []
    var current: (context: String, removals: [String], additions: [String])?
    var lineIndex = start
    while lineIndex < end {
      let line = lines[lineIndex]
      if line == "*** End Patch" || line.hasPrefix("*** Update File: ")
        || line.hasPrefix("*** Add File: ")
      {
        break
      }
      if line.hasPrefix("@@") {
        if let current {
          hunks.append(
            ProjectPatchHunk(
              context: current.context,
              removals: current.removals,
              additions: current.additions
            )
          )
        }
        let context = String(line.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        current = (context, [], [])
      } else if line.hasPrefix("-") {
        if current == nil { current = ("", [], []) }
        current?.removals.append(String(line.dropFirst()))
      } else if line.hasPrefix("+") {
        if current == nil { current = ("", [], []) }
        current?.additions.append(String(line.dropFirst()))
      } else if line.hasPrefix(" ") {
        if current == nil { current = ("", [], []) }
        current?.removals.append(String(line.dropFirst()))
        current?.additions.append(String(line.dropFirst()))
      } else if line.isEmpty {
        if current == nil { current = ("", [], []) }
        current?.removals.append("")
        current?.additions.append("")
      }
      lineIndex += 1
    }
    if let current {
      hunks.append(
        ProjectPatchHunk(
          context: current.context,
          removals: current.removals,
          additions: current.additions
        )
      )
    }
    guard !hunks.isEmpty else { throw ProjectPatchParserError.emptyPatch }
    if isAdd {
      guard hunks.allSatisfy({ $0.removals.isEmpty }) else {
        throw ProjectPatchParserError.malformedFileHeader
      }
    }
    return ParsedOperation(
      operation: ProjectPatchFileOperation(
        action: isAdd ? "add" : "update",
        relativePath: path,
        hunks: hunks
      ),
      endLine: lineIndex - 1
    )
  }
}

private struct ParsedOperation {
  let operation: ProjectPatchFileOperation
  let endLine: Int
}
