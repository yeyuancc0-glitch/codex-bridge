import BridgeDomain
import Foundation

enum BoundedDiffMaker {
  static let maximumLines = 500
  static let maximumBytes = 60 * 1_024
  private static let truncationMarker = "…"

  static func make(old: String, new: String) -> BoundedDiff {
    let oldLines = old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let newLines = new.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let commonPrefix = zip(oldLines, newLines).prefix { $0 == $1 }.count
    let commonSuffix = zip(oldLines.reversed(), newLines.reversed()).prefix { $0 == $1 }.count
    let removed = oldLines[commonPrefix..<max(commonPrefix, oldLines.count - commonSuffix)]
    let added = newLines[commonPrefix..<max(commonPrefix, newLines.count - commonSuffix)]
    var remainingBytes = maximumBytes
    let (boundedRemoved, removedTruncated) = boundedLines(
      removed,
      remainingBytes: &remainingBytes
    )
    let (boundedAdded, addedTruncated) = boundedLines(
      added,
      remainingBytes: &remainingBytes
    )
    let truncated = removedTruncated || addedTruncated
    return BoundedDiff(
      removedLines: boundedRemoved,
      addedLines: boundedAdded,
      truncated: truncated,
      byteCount: boundedRemoved.reduce(0) { $0 + $1.utf8.count }
        + boundedAdded.reduce(0) { $0 + $1.utf8.count }
    )
  }

  private static func boundedLines(
    _ lines: ArraySlice<String>,
    remainingBytes: inout Int
  ) -> (lines: [String], truncated: Bool) {
    var bounded: [String] = []
    var truncated = lines.count > maximumLines

    for line in lines.prefix(maximumLines) {
      guard remainingBytes > 0 else {
        truncated = true
        break
      }
      let lineBytes = line.utf8.count
      if lineBytes <= remainingBytes {
        bounded.append(line)
        remainingBytes -= lineBytes
        continue
      }

      let markerBytes = truncationMarker.utf8.count
      guard remainingBytes >= markerBytes else {
        truncated = true
        break
      }
      let prefix = prefix(of: line, maximumBytes: remainingBytes - markerBytes)
      let shortened = prefix + truncationMarker
      bounded.append(shortened)
      remainingBytes -= shortened.utf8.count
      truncated = true
      break
    }

    return (bounded, truncated)
  }

  private static func prefix(of line: String, maximumBytes: Int) -> String {
    guard maximumBytes > 0 else { return "" }
    var prefix = String.UnicodeScalarView()
    var byteCount = 0
    for scalar in line.unicodeScalars {
      let scalarBytes = String(scalar).utf8.count
      guard byteCount + scalarBytes <= maximumBytes else { break }
      prefix.append(scalar)
      byteCount += scalarBytes
    }
    return String(prefix)
  }
}
