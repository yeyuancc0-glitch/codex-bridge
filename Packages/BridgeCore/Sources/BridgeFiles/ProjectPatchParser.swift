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
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let bounds = try contentBounds(in: lines)
    let operations =
      hasCustomHeader(in: lines, bounds: bounds)
      ? try parseCustom(lines, bounds: bounds)
      : try parseUnified(lines, bounds: bounds)
    try validateUniquePaths(operations)
    guard !operations.isEmpty else { throw ProjectPatchParserError.emptyPatch }
    return operations
  }

  private static func parseCustom(
    _ lines: [String],
    bounds: Range<Int>
  ) throws -> [ProjectPatchFileOperation] {
    var operations: [ProjectPatchFileOperation] = []
    var index = bounds.lowerBound
    while index < bounds.upperBound {
      let header = controlLine(lines[index])
      guard header.hasPrefix("*** ") else {
        index += 1
        continue
      }
      guard
        let operation = try parseCustomFile(
          header: header,
          lines: lines,
          from: index + 1,
          until: bounds.upperBound
        )
      else {
        index += 1
        continue
      }
      operations.append(operation.operation)
      index = operation.endLine + 1
    }
    return operations
  }

  private static func parseUnified(
    _ lines: [String],
    bounds: Range<Int>
  ) throws -> [ProjectPatchFileOperation] {
    var operations: [ProjectPatchFileOperation] = []
    var index = bounds.lowerBound
    while index < bounds.upperBound {
      guard isUnifiedHeaderPair(lines, at: index, upperBound: bounds.upperBound) else {
        index += 1
        continue
      }
      let operation = try parseUnifiedFile(
        lines,
        headerIndex: index,
        upperBound: bounds.upperBound
      )
      operations.append(operation.operation)
      index = operation.endLine + 1
    }
    return operations
  }

  private static func parseUnifiedFile(
    _ lines: [String],
    headerIndex: Int,
    upperBound: Int
  ) throws -> ParsedOperation {
    let oldPath = try unifiedPath(from: lines[headerIndex], prefix: "--- ")
    let newPath = try unifiedPath(from: lines[headerIndex + 1], prefix: "+++ ")
    let descriptor = try unifiedDescriptor(oldPath: oldPath, newPath: newPath)
    var hunks: [ProjectPatchHunk] = []
    var current: ParsedHunk?
    var index = headerIndex + 2

    while index < upperBound {
      if isUnifiedHeaderPair(lines, at: index, upperBound: upperBound) { break }
      let line = lines[index]
      if line.hasPrefix("diff --git ") { break }
      if line.hasPrefix("@@") {
        append(&current, to: &hunks)
        current = ParsedHunk(context: unifiedHunkContext(line))
      } else if line == #"\ No newline at end of file"# {
        index += 1
        continue
      } else if current != nil {
        try appendUnifiedContent(line, to: &current)
      }
      index += 1
    }
    append(&current, to: &hunks)
    try validateHunks(hunks, isAdd: descriptor.action == "add")
    return ParsedOperation(
      operation: ProjectPatchFileOperation(
        action: descriptor.action,
        relativePath: descriptor.path,
        hunks: hunks
      ),
      endLine: index - 1
    )
  }

  private static func parseCustomFile(
    header: String,
    lines: [String],
    from start: Int,
    until end: Int
  ) throws -> ParsedOperation? {
    guard header.hasPrefix("*** Update File: ") || header.hasPrefix("*** Add File: ") else {
      return nil
    }
    let isAdd = header.hasPrefix("*** Add File: ")
    let prefix = isAdd ? "*** Add File: " : "*** Update File: "
    let path = String(header.dropFirst(prefix.count))
    try validateRelativePath(path)

    var hunks: [ProjectPatchHunk] = []
    var current: ParsedHunk?
    var index = start
    while index < end {
      let line = lines[index]
      let control = controlLine(line)
      if isCustomBoundary(control) { break }
      if line.hasPrefix("@@") {
        append(&current, to: &hunks)
        current = ParsedHunk(
          context: String(line.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        )
      } else {
        appendCustomContent(line, to: &current)
      }
      index += 1
    }
    append(&current, to: &hunks)
    try validateHunks(hunks, isAdd: isAdd)
    return ParsedOperation(
      operation: ProjectPatchFileOperation(
        action: isAdd ? "add" : "update",
        relativePath: path,
        hunks: hunks
      ),
      endLine: index - 1
    )
  }

  private static func appendCustomContent(_ line: String, to current: inout ParsedHunk?) {
    if line.hasPrefix("-") {
      hunk(&current).removals.append(String(line.dropFirst()))
    } else if line.hasPrefix("+") {
      hunk(&current).additions.append(String(line.dropFirst()))
    } else if line.hasPrefix(" ") {
      let content = String(line.dropFirst())
      hunk(&current).removals.append(content)
      hunk(&current).additions.append(content)
    } else if line.isEmpty {
      hunk(&current).removals.append("")
      hunk(&current).additions.append("")
    }
  }

  private static func appendUnifiedContent(
    _ line: String,
    to current: inout ParsedHunk?
  ) throws {
    guard let marker = line.first else { throw ProjectPatchParserError.malformedFileHeader }
    let content = String(line.dropFirst())
    switch marker {
    case "-":
      current?.removals.append(content)
    case "+":
      current?.additions.append(content)
    case " ":
      current?.removals.append(content)
      current?.additions.append(content)
    default:
      throw ProjectPatchParserError.malformedFileHeader
    }
  }

  private static func append(_ current: inout ParsedHunk?, to hunks: inout [ProjectPatchHunk]) {
    guard let parsed = current else { return }
    hunks.append(
      ProjectPatchHunk(
        context: parsed.context,
        removals: parsed.removals,
        additions: parsed.additions
      )
    )
    current = nil
  }

  private static func hunk(_ current: inout ParsedHunk?) -> ParsedHunk {
    if let current { return current }
    let created = ParsedHunk(context: "")
    current = created
    return created
  }

  private static func validateHunks(_ hunks: [ProjectPatchHunk], isAdd: Bool) throws {
    guard !hunks.isEmpty else { throw ProjectPatchParserError.emptyPatch }
    if isAdd, hunks.contains(where: { !$0.removals.isEmpty }) {
      throw ProjectPatchParserError.malformedFileHeader
    }
  }

  private static func unifiedDescriptor(oldPath: String, newPath: String) throws
    -> (action: String, path: String)
  {
    if oldPath == "/dev/null" {
      guard newPath != "/dev/null" else { throw ProjectPatchParserError.malformedFileHeader }
      try validateRelativePath(newPath)
      return ("add", newPath)
    }
    guard newPath != "/dev/null" else { throw ProjectPatchParserError.malformedFileHeader }
    try validateRelativePath(oldPath)
    try validateRelativePath(newPath)
    guard oldPath == newPath else { throw ProjectPatchParserError.malformedFileHeader }
    return ("update", newPath)
  }

  private static func unifiedPath(from line: String, prefix: String) throws -> String {
    guard line.hasPrefix(prefix) else { throw ProjectPatchParserError.malformedFileHeader }
    let raw = line.dropFirst(prefix.count).split(separator: "\t", maxSplits: 1).first.map(
      String.init)
    guard let raw, !raw.isEmpty else { throw ProjectPatchParserError.malformedFileHeader }
    if raw == "/dev/null" { return raw }
    if raw.hasPrefix("a/") || raw.hasPrefix("b/") { return String(raw.dropFirst(2)) }
    return raw
  }

  private static func unifiedHunkContext(_ line: String) -> String {
    String(line.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func isUnifiedHeaderPair(
    _ lines: [String],
    at index: Int,
    upperBound: Int
  ) -> Bool {
    index + 1 < upperBound && lines[index].hasPrefix("--- ")
      && lines[index + 1].hasPrefix("+++ ")
  }

  private static func hasCustomHeader(in lines: [String], bounds: Range<Int>) -> Bool {
    lines[bounds].contains { line in
      let line = controlLine(line)
      return line.hasPrefix("*** Update File: ") || line.hasPrefix("*** Add File: ")
    }
  }

  private static func contentBounds(in lines: [String]) throws -> Range<Int> {
    let beginIndex = lines.firstIndex { controlLine($0) == "*** Begin Patch" }
    let endIndex = lines.lastIndex { controlLine($0) == "*** End Patch" }
    switch (beginIndex, endIndex) {
    case (.none, .none):
      var lower = lines.startIndex
      var upper = lines.endIndex
      while lower < upper, controlLine(lines[lower]).isEmpty { lower += 1 }
      while upper > lower, controlLine(lines[upper - 1]).isEmpty { upper -= 1 }
      return lower..<upper
    case (.some(let begin), .some(let end)) where end > begin:
      return (begin + 1)..<end
    case (.none, .some):
      throw ProjectPatchParserError.missingBeginMarker
    case (.some, .none), (.some, .some):
      throw ProjectPatchParserError.missingEndMarker
    }
  }

  private static func validateUniquePaths(_ operations: [ProjectPatchFileOperation]) throws {
    var paths = Set<String>()
    for operation in operations where !paths.insert(operation.relativePath).inserted {
      throw ProjectPatchParserError.duplicatePath
    }
  }

  private static func validateRelativePath(_ path: String) throws {
    guard !path.isEmpty, !path.hasPrefix("/") else {
      throw ProjectPatchParserError.absolutePath
    }
  }

  private static func isCustomBoundary(_ line: String) -> Bool {
    line == "*** End Patch" || line.hasPrefix("*** Update File: ")
      || line.hasPrefix("*** Add File: ")
  }

  private static func controlLine(_ line: String) -> String {
    line.trimmingCharacters(in: .whitespaces)
  }
}

private struct ParsedOperation {
  let operation: ProjectPatchFileOperation
  let endLine: Int
}

private final class ParsedHunk {
  let context: String
  var removals: [String] = []
  var additions: [String] = []

  init(context: String) {
    self.context = context
  }
}
