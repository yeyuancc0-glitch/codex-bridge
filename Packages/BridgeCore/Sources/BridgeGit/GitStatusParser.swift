import Foundation

struct GitStatusParser: Sendable {
  let maximumFileCount: Int
  let maximumPathBytes: Int
  let maximumAggregatePathBytes: Int

  func parse(_ data: Data) throws -> GitStatusEvidence {
    let tokens = data.split(separator: 0, omittingEmptySubsequences: true)
    var branch: String?
    var headCommit: String?
    var detachedHead = false
    var entries: [GitFileChange] = []
    var aggregatePathBytes = 0
    var index = 0

    while index < tokens.count {
      let token = tokens[index]
      guard let marker = token.first else {
        throw GitEvidenceError.malformedGitOutput
      }
      switch marker {
      case UInt8(ascii: "#"):
        let header = String(decoding: token, as: UTF8.self)
        parseHeader(
          header,
          branch: &branch,
          headCommit: &headCommit,
          detachedHead: &detachedHead
        )
      case UInt8(ascii: "1"):
        let entry = try ordinaryEntry(token)
        try append(
          entry,
          pathByteCount: try pathBytes(in: token, afterSpaces: 8).count,
          entries: &entries,
          aggregatePathBytes: &aggregatePathBytes
        )
      case UInt8(ascii: "2"):
        guard index + 1 < tokens.count else {
          throw GitEvidenceError.malformedGitOutput
        }
        let originalPathBytes = tokens[index + 1]
        let entry = try renamedEntry(token, originalPathBytes: originalPathBytes)
        try append(
          entry,
          pathByteCount: try pathBytes(in: token, afterSpaces: 9).count
            + originalPathBytes.count,
          entries: &entries,
          aggregatePathBytes: &aggregatePathBytes
        )
        index += 1
      case UInt8(ascii: "u"):
        let entry = try unmergedEntry(token)
        try append(
          entry,
          pathByteCount: try pathBytes(in: token, afterSpaces: 10).count,
          entries: &entries,
          aggregatePathBytes: &aggregatePathBytes
        )
      case UInt8(ascii: "?"):
        let bytes = try prefixedPathBytes(in: token)
        let entry = GitFileChange(kind: .untracked, path: decodePath(bytes))
        try append(
          entry,
          pathByteCount: bytes.count,
          entries: &entries,
          aggregatePathBytes: &aggregatePathBytes
        )
      default:
        throw GitEvidenceError.malformedGitOutput
      }
      index += 1
    }

    return GitStatusEvidence(
      repositoryClassification: .gitWorkingTree,
      branch: branch,
      headCommit: headCommit,
      detachedHead: detachedHead,
      entries: entries,
      porcelainV2: data
    )
  }

  private func ordinaryEntry(_ token: Data.SubSequence) throws -> GitFileChange {
    let path = decodePath(try pathBytes(in: token, afterSpaces: 8))
    let status = try statusPair(in: token)
    return GitFileChange(
      kind: .ordinary,
      path: path,
      indexStatus: status.index,
      workTreeStatus: status.workTree
    )
  }

  private func renamedEntry(
    _ token: Data.SubSequence,
    originalPathBytes: Data.SubSequence
  ) throws -> GitFileChange {
    guard !originalPathBytes.isEmpty else { throw GitEvidenceError.malformedGitOutput }
    let path = decodePath(try pathBytes(in: token, afterSpaces: 9))
    let status = try statusPair(in: token)
    return GitFileChange(
      kind: .renamedOrCopied,
      path: path,
      originalPath: decodePath(originalPathBytes),
      indexStatus: status.index,
      workTreeStatus: status.workTree
    )
  }

  private func unmergedEntry(_ token: Data.SubSequence) throws -> GitFileChange {
    let path = decodePath(try pathBytes(in: token, afterSpaces: 10))
    let status = try statusPair(in: token)
    return GitFileChange(
      kind: .unmerged,
      path: path,
      indexStatus: status.index,
      workTreeStatus: status.workTree
    )
  }

  private func append(
    _ entry: GitFileChange,
    pathByteCount: Int,
    entries: inout [GitFileChange],
    aggregatePathBytes: inout Int
  ) throws {
    guard entries.count < maximumFileCount else {
      throw GitEvidenceError.fileCountLimitExceeded
    }
    guard pathByteCount <= maximumPathBytes * (entry.originalPath == nil ? 1 : 2) else {
      throw GitEvidenceError.pathByteLimitExceeded
    }
    if entry.path.utf8.count > maximumPathBytes
      || (entry.originalPath?.utf8.count ?? 0) > maximumPathBytes
    {
      throw GitEvidenceError.pathByteLimitExceeded
    }
    guard aggregatePathBytes <= maximumAggregatePathBytes - pathByteCount else {
      throw GitEvidenceError.aggregatePathByteLimitExceeded
    }
    aggregatePathBytes += pathByteCount
    entries.append(entry)
  }

  private func parseHeader(
    _ header: String,
    branch: inout String?,
    headCommit: inout String?,
    detachedHead: inout Bool
  ) {
    if header.hasPrefix("# branch.oid ") {
      let value = String(header.dropFirst("# branch.oid ".count))
      headCommit = value == "(initial)" ? nil : value
      return
    }
    guard header.hasPrefix("# branch.head ") else { return }
    let value = String(header.dropFirst("# branch.head ".count))
    detachedHead = value == "(detached)"
    branch = detachedHead ? nil : value
  }

  private func statusPair(
    in token: Data.SubSequence
  ) throws -> (index: String, workTree: String) {
    guard token.count >= 4, token[token.index(token.startIndex, offsetBy: 1)] == UInt8(ascii: " ")
    else {
      throw GitEvidenceError.malformedGitOutput
    }
    let indexStatus = token[token.index(token.startIndex, offsetBy: 2)]
    let workTreeStatus = token[token.index(token.startIndex, offsetBy: 3)]
    return (
      String(UnicodeScalar(indexStatus)),
      String(UnicodeScalar(workTreeStatus))
    )
  }

  private func prefixedPathBytes(
    in token: Data.SubSequence
  ) throws -> Data.SubSequence {
    guard token.count >= 3, token[token.index(after: token.startIndex)] == UInt8(ascii: " ")
    else {
      throw GitEvidenceError.malformedGitOutput
    }
    let start = token.index(token.startIndex, offsetBy: 2)
    guard start < token.endIndex else { throw GitEvidenceError.malformedGitOutput }
    return token[start...]
  }

  private func pathBytes(
    in token: Data.SubSequence,
    afterSpaces targetCount: Int
  ) throws -> Data.SubSequence {
    var spaceCount = 0
    var index = token.startIndex
    while index < token.endIndex {
      if token[index] == UInt8(ascii: " ") {
        spaceCount += 1
        if spaceCount == targetCount {
          let start = token.index(after: index)
          guard start < token.endIndex else {
            throw GitEvidenceError.malformedGitOutput
          }
          return token[start...]
        }
      }
      index = token.index(after: index)
    }
    throw GitEvidenceError.malformedGitOutput
  }

  private func decodePath<S: DataProtocol>(_ bytes: S) -> String {
    String(decoding: bytes, as: UTF8.self)
  }
}
