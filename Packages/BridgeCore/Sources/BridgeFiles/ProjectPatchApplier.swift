import BridgeDomain
import Foundation

enum ProjectPatchApplier {
  static func apply(hunks: [ProjectPatchHunk], to content: String) throws -> String {
    var updated = content
    for hunk in hunks {
      updated = try apply(hunk: hunk, to: updated)
    }
    return updated
  }

  private static func apply(hunk: ProjectPatchHunk, to content: String) throws -> String {
    let before = hunk.removals
    let after = hunk.additions
    guard !before.isEmpty else { throw ProjectMutationError.invalidPatchSyntax }
    let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let matches = indices(of: before, in: lines)
    guard !matches.isEmpty else {
      throw ProjectMutationError.patchContextNotFound
    }
    let candidates =
      matches.count == 1
      ? matches
      : narrow(matches: matches, using: hunk.context, in: lines)
    guard !candidates.isEmpty else {
      throw ProjectMutationError.patchContextNotFound
    }
    guard candidates.count == 1, let matchIndex = candidates.first else {
      throw ProjectMutationError.patchContextNonUnique
    }
    var updated = lines
    updated.replaceSubrange(matchIndex..<(matchIndex + before.count), with: after)
    return updated.joined(separator: "\n")
  }

  private static func indices(of sequence: [String], in lines: [String]) -> [Int] {
    guard !sequence.isEmpty, sequence.count <= lines.count else { return [] }
    var matches: [Int] = []
    for index in 0...(lines.count - sequence.count) {
      if Array(lines[index..<(index + sequence.count)]) == sequence {
        matches.append(index)
      }
    }
    return matches
  }

  private static func narrow(matches: [Int], using context: String, in lines: [String]) -> [Int] {
    let context = context.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !context.isEmpty else { return matches }

    let parts = context.components(separatedBy: "@@")
    let rangeParts = parts[0].split(whereSeparator: { $0 == " " || $0 == "\t" })
    if rangeParts.count >= 2,
      rangeParts[0].hasPrefix("-"),
      rangeParts[1].hasPrefix("+")
    {
      let sourceStart = rangeParts[0].dropFirst().split(separator: ",").first
        .flatMap { Int($0) }
      guard let sourceStart, sourceStart > 0 else { return [] }
      return matches.filter { $0 == sourceStart - 1 }
    }

    let label =
      parts.count > 1
      ? parts.dropFirst().joined(separator: "@@").trimmingCharacters(in: .whitespacesAndNewlines)
      : context
    guard !label.isEmpty else { return matches }
    return matches.filter { index in
      lines[..<index].contains { line in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed == label || trimmed.contains(label)
      }
    }
  }
}
