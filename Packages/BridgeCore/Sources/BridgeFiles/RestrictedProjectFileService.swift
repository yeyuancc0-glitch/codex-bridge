import BridgeDomain
import BridgeProjects
import BridgeSecurity
import Foundation

public struct RestrictedProjectFileService: Sendable {
  private static let maximumReturnedLineBytes = 64 * 1_024
  private let repository: any ProjectRepository
  private let limits: ProjectFileLimits

  public init(
    repository: any ProjectRepository,
    limits: ProjectFileLimits = .default
  ) {
    self.repository = repository
    self.limits = limits
  }

  public func read(_ request: ProjectFileReadRequest) async throws -> ProjectFileReadResult {
    let project = try await requireReadableProject(request.projectID)
    let path = try SecureRelativePath(request.relativePath)
    let policy = ProjectFilePolicy(forbiddenPatterns: project.forbiddenPatterns)
    guard policy.allows(path) else { throw ProjectFileError.forbiddenPath }

    let reader = SecureFileReader(
      maximumBytes: limits.maximumFileBytes,
      maximumLines: .max
    )
    let file: SecureTextFile
    do {
      file = try reader.read(path, through: ProjectPathResolver(root: project.primaryRoot))
    } catch PathSecurityError.pathDoesNotExist {
      throw ProjectFileError.pathMissing
    } catch PathSecurityError.readFailed(let code) where code == ENOENT || code == ENOTDIR {
      throw ProjectFileError.pathMissing
    }
    guard !containsUnsupportedControl(file.text) else {
      throw PathSecurityError.binaryFileBlocked
    }
    return try makeReadResult(fileInfo: file, path: path, range: request.lineRange)
  }

  public func search(_ request: ProjectFileSearchRequest) async throws
    -> ProjectFileSearchResult
  {
    let project = try await requireReadableProject(request.projectID)
    let policy = ProjectFilePolicy(forbiddenPatterns: project.forbiddenPatterns)
    let scope = try makeScope(request.relativeDirectory, policy: policy)
    let limit = try searchLimit(request.limit)
    var enumerator = DescriptorCandidateEnumerator(
      root: project.primaryRoot,
      policy: policy,
      limits: limits
    )
    let candidates = try enumerator.candidates(scope: scope)
    let signature = SearchCursor.signature(
      projectID: request.projectID,
      root: project.primaryRoot,
      query: request.query,
      scope: scope,
      caseSensitive: request.caseSensitive,
      candidatePaths: candidates.paths
    )
    let position = try SearchCursor.decode(request.cursor, signature: signature)
    guard position.candidateIndex <= candidates.paths.count else {
      throw ProjectFileError.invalidCursor
    }

    var scanner = SearchPageScanner(
      root: project.primaryRoot,
      limits: limits,
      query: request.query,
      caseSensitive: request.caseSensitive,
      limit: limit
    )
    let page = try scanner.scan(paths: candidates.paths, from: position)
    return try fitSearchResult(
      page,
      signature: signature,
      usedTrackedPathPriority: candidates.usedTrackedPathPriority
    )
  }

  private func requireReadableProject(_ id: BridgeDomain.ProjectID) async throws
    -> RegisteredProject
  {
    guard let project = try await repository.project(id: id) else {
      throw ProjectFileError.unknownProject
    }
    try project.validateCurrentRoots()
    guard project.accessPolicy.read == .allowed else {
      throw ProjectFileError.readNotAllowed
    }
    return project
  }

  private func makeScope(
    _ value: String?,
    policy: ProjectFilePolicy
  ) throws -> SecureRelativePath? {
    guard let value else { return nil }
    let path = try SecureRelativePath(value)
    guard policy.allows(path) else { throw ProjectFileError.forbiddenPath }
    return path
  }

  private func searchLimit(_ requested: Int?) throws -> Int {
    let limit = requested ?? limits.defaultSearchMatches
    guard limit > 0, limit <= limits.maximumSearchMatches else {
      throw ProjectFileError.invalidSearchRequest
    }
    return limit
  }

  private func makeReadResult(
    fileInfo: SecureTextFile,
    path: SecureRelativePath,
    range: FileLineRange
  ) throws -> ProjectFileReadResult {
    let lines = normalizedLines(fileInfo.text)
    let startIndex = min(range.startLine - 1, lines.count)
    let endIndex = min(startIndex + range.lineCount, lines.count)
    var visible = try lines[startIndex..<endIndex].map(sanitizeReturnedLine)
    let selectedLineCount = visible.count
    let moreLinesExist = endIndex < lines.count || fileInfo.truncated

    while true {
      let result = readResult(
        lines: visible,
        path: path,
        startLine: range.startLine,
        moreLinesExist: moreLinesExist || visible.count < endIndex - startIndex,
        sha256: fileInfo.sha256,
        byteCount: fileInfo.byteCount
      )
      if try encodedSize(result) <= limits.maximumResponseBytes {
        guard selectedLineCount == 0 || !visible.isEmpty else {
          throw ProjectFileError.responseLimitExceeded
        }
        return result
      }
      guard !visible.isEmpty else { throw ProjectFileError.responseLimitExceeded }
      visible.removeLast()
    }
  }

  private func readResult(
    lines: [RedactedTextLine],
    path: SecureRelativePath,
    startLine: Int,
    moreLinesExist: Bool,
    sha256: String,
    byteCount: Int
  ) -> ProjectFileReadResult {
    let endLine = lines.isEmpty ? nil : startLine + lines.count - 1
    return ProjectFileReadResult(
      relativePath: path.value,
      startLine: startLine,
      endLine: endLine,
      content: lines.map(\.text).joined(separator: "\n"),
      redactedLineCount: lines.lazy.filter(\.redacted).count,
      truncated: moreLinesExist,
      nextStartLine: moreLinesExist ? startLine + lines.count : nil,
      sha256: sha256,
      byteCount: byteCount
    )
  }

  private func sanitizeReturnedLine(_ line: String) throws -> RedactedTextLine {
    guard line.utf8.count <= Self.maximumReturnedLineBytes else {
      throw ProjectFileError.lineTooLong(maximumBytes: Self.maximumReturnedLineBytes)
    }
    return ProjectSecretRedactor.redact(line)
  }

  private func fitSearchResult(
    _ page: SearchScanPage,
    signature: String,
    usedTrackedPathPriority: Bool
  ) throws -> ProjectFileSearchResult {
    var visible = page.matches
    while true {
      let continuation = continuationPosition(page: page, visibleCount: visible.count)
      let result = ProjectFileSearchResult(
        matches: visible,
        nextCursor: continuation.map { SearchCursor.encode($0, signature: signature) },
        skippedFileCount: page.skippedFileCount,
        usedTrackedPathPriority: usedTrackedPathPriority
      )
      if try encodedSize(result) <= limits.maximumResponseBytes {
        guard page.matches.isEmpty || !visible.isEmpty else {
          throw ProjectFileError.responseLimitExceeded
        }
        return result
      }
      guard !visible.isEmpty else { throw ProjectFileError.responseLimitExceeded }
      visible.removeLast()
    }
  }

  private func continuationPosition(
    page: SearchScanPage,
    visibleCount: Int
  ) -> SearchPosition? {
    guard visibleCount < page.matches.count else { return page.continuation }
    guard visibleCount > 0 else { return page.start }
    return page.positionsAfterMatches[visibleCount - 1]
  }

  private func encodedSize<T: Encodable>(_ value: T) throws -> Int {
    try JSONEncoder().encode(value).count
  }
}

private struct SearchPosition: Equatable, Sendable {
  let candidateIndex: Int
  let lineIndex: Int
}

private enum SearchCursor {
  static func signature(
    projectID: BridgeDomain.ProjectID,
    root: RegisteredRoot,
    query: String,
    scope: SecureRelativePath?,
    caseSensitive: Bool,
    candidatePaths: [String]
  ) -> String {
    let bindingParts =
      [
        projectID.rawValue,
        root.identity.volumeID,
        root.identity.fileID,
        query,
        scope?.value ?? "",
        caseSensitive ? "1" : "0",
      ] + candidatePaths
    var hash: UInt64 = 14_695_981_039_346_656_037
    for part in bindingParts {
      for byte in part.utf8 {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
      }
      hash ^= 0
      hash &*= 1_099_511_628_211
    }
    return String(hash, radix: 16)
  }

  static func encode(_ position: SearchPosition, signature: String) -> String {
    "v1.\(signature).\(position.candidateIndex).\(position.lineIndex)"
  }

  static func decode(_ value: String?, signature: String) throws -> SearchPosition {
    guard let value else { return SearchPosition(candidateIndex: 0, lineIndex: 0) }
    let components = value.split(separator: ".", omittingEmptySubsequences: false)
    guard
      components.count == 4,
      components[0] == "v1",
      components[1] == Substring(signature),
      let candidateIndex = Int(components[2]),
      let lineIndex = Int(components[3]),
      candidateIndex >= 0,
      lineIndex >= 0
    else {
      throw ProjectFileError.invalidCursor
    }
    return SearchPosition(candidateIndex: candidateIndex, lineIndex: lineIndex)
  }
}

private struct SearchScanPage: Sendable {
  let start: SearchPosition
  let matches: [ProjectFileSearchMatch]
  let positionsAfterMatches: [SearchPosition]
  let continuation: SearchPosition?
  let skippedFileCount: Int
}

private struct SearchPageScanner {
  let root: RegisteredRoot
  let limits: ProjectFileLimits
  let query: String
  let caseSensitive: Bool
  let limit: Int
  private var matches: [ProjectFileSearchMatch] = []
  private var positionsAfterMatches: [SearchPosition] = []
  private var skippedFileCount = 0
  private var bytesRead = 0
  private var scannedLines = 0

  init(
    root: RegisteredRoot,
    limits: ProjectFileLimits,
    query: String,
    caseSensitive: Bool,
    limit: Int
  ) {
    self.root = root
    self.limits = limits
    self.query = query
    self.caseSensitive = caseSensitive
    self.limit = limit
  }

  mutating func scan(paths: [String], from start: SearchPosition) throws -> SearchScanPage {
    guard start.candidateIndex < paths.count else {
      return page(start: start, continuation: nil)
    }
    let reader = SecureFileReader(maximumBytes: limits.maximumFileBytes, maximumLines: .max)
    for candidateIndex in start.candidateIndex..<paths.count {
      let position = SearchPosition(candidateIndex: candidateIndex, lineIndex: 0)
      if bytesRead >= limits.maximumSearchBytes {
        return page(start: start, continuation: position)
      }
      guard let file = try read(paths[candidateIndex], reader: reader) else { continue }
      if bytesRead > limits.maximumSearchBytes - file.bytesRead {
        return page(start: start, continuation: position)
      }
      bytesRead += file.bytesRead
      let firstLine = candidateIndex == start.candidateIndex ? start.lineIndex : 0
      let continuation = try scanFile(
        file,
        path: paths[candidateIndex],
        candidateIndex: candidateIndex,
        firstLine: firstLine
      )
      if let continuation { return page(start: start, continuation: continuation) }
    }
    return page(start: start, continuation: nil)
  }

  private mutating func scanFile(
    _ file: SecureTextFile,
    path: String,
    candidateIndex: Int,
    firstLine: Int
  ) throws -> SearchPosition? {
    guard !containsUnsupportedControl(file.text) else {
      skippedFileCount += 1
      return nil
    }
    let lines = normalizedLines(file.text)
    guard firstLine <= lines.count else { throw ProjectFileError.invalidCursor }
    for lineIndex in firstLine..<lines.count {
      let current = SearchPosition(candidateIndex: candidateIndex, lineIndex: lineIndex)
      if scannedLines >= limits.maximumScannedLines { return current }
      let next = nextPosition(candidateIndex: candidateIndex, lineIndex: lineIndex, lines: lines)
      scannedLines += 1
      guard matchesQuery(lines[lineIndex]) else { continue }
      appendMatch(path: path, line: lines[lineIndex], lineIndex: lineIndex, next: next)
      if matches.count == limit { return next }
    }
    return nil
  }

  private mutating func read(
    _ path: String,
    reader: SecureFileReader
  ) throws -> SecureTextFile? {
    do {
      let relativePath = try SecureRelativePath(path)
      return try reader.read(relativePath, through: ProjectPathResolver(root: root))
    } catch let error as PathSecurityError where isSkippable(error) {
      skippedFileCount += 1
      return nil
    }
  }

  private mutating func appendMatch(
    path: String,
    line: String,
    lineIndex: Int,
    next: SearchPosition
  ) {
    let redacted = ProjectSecretRedactor.redact(line)
    matches.append(
      ProjectFileSearchMatch(
        relativePath: path,
        lineNumber: lineIndex + 1,
        preview: boundedPreview(redacted.text),
        redacted: redacted.redacted
      )
    )
    positionsAfterMatches.append(next)
  }

  private func matchesQuery(_ line: String) -> Bool {
    if caseSensitive { return line.contains(query) }
    return line.range(of: query, options: [.caseInsensitive]) != nil
  }

  private func nextPosition(
    candidateIndex: Int,
    lineIndex: Int,
    lines: [String]
  ) -> SearchPosition {
    if lineIndex + 1 < lines.count {
      return SearchPosition(candidateIndex: candidateIndex, lineIndex: lineIndex + 1)
    }
    return SearchPosition(candidateIndex: candidateIndex + 1, lineIndex: 0)
  }

  private func page(start: SearchPosition, continuation: SearchPosition?) -> SearchScanPage {
    SearchScanPage(
      start: start,
      matches: matches,
      positionsAfterMatches: positionsAfterMatches,
      continuation: continuation,
      skippedFileCount: skippedFileCount
    )
  }

  private func boundedPreview(_ line: String) -> String {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    var preview = ""
    for character in trimmed {
      if preview.utf8.count + String(character).utf8.count > 240 { break }
      preview.append(character)
    }
    return preview
  }

  private func isSkippable(_ error: PathSecurityError) -> Bool {
    switch error {
    case .binaryFileBlocked, .fileTooLarge, .pathDoesNotExist, .sensitiveFileBlocked,
      .unsupportedFileType:
      true
    case .readFailed(let code):
      code == ENOENT || code == ENOTDIR || code == ELOOP
    default:
      false
    }
  }
}

private func normalizedLines(_ text: String) -> [String] {
  var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
    line.last == "\r" ? String(line.dropLast()) : String(line)
  }
  // A trailing newline is a terminator, not an extra empty logical line, so it
  // must not trigger a spurious truncated/next_start_line page.
  if text.hasSuffix("\n"), lines.last == "" {
    lines.removeLast()
  }
  return lines
}

private func containsUnsupportedControl(_ text: String) -> Bool {
  text.unicodeScalars.contains { scalar in
    let value = scalar.value
    return (value < 0x20 && value != 0x09 && value != 0x0A && value != 0x0D) || value == 0x7F
  }
}
