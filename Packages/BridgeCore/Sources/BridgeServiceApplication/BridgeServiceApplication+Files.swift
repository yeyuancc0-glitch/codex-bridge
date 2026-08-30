import BridgeDomain
import BridgeFiles
import BridgeMCP
import BridgeSecurity
import Foundation

extension BridgeServiceApplication {
  public func serviceSearchProjectFiles(
    projectID: String,
    query: String,
    relativeDirectory: String?,
    caseSensitive: Bool,
    cursor: String?,
    limit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectFileSearchPage {
    try Self.checkDeadline(deadline)
    do {
      let result = try await files.search(
        ProjectFileSearchRequest(
          projectID: ProjectID(rawValue: projectID),
          query: query,
          relativeDirectory: relativeDirectory,
          caseSensitive: caseSensitive,
          limit: limit,
          cursor: cursor
        )
      )
      return MCPProjectFileSearchPage(
        matches: result.matches.map {
          MCPProjectFileSearchMatch(
            relativePath: $0.relativePath,
            lineNumber: $0.lineNumber,
            preview: $0.preview,
            redacted: $0.redacted
          )
        },
        nextCursor: result.nextCursor,
        skippedFileCount: result.skippedFileCount
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw Self.publicFileError(error)
    }
  }

  public func serviceReadProjectFile(
    projectID: String,
    relativePath: String,
    startLine: Int,
    lineCount: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectFileReadPage {
    try Self.checkDeadline(deadline)
    do {
      let result = try await files.read(
        ProjectFileReadRequest(
          projectID: ProjectID(rawValue: projectID),
          relativePath: relativePath,
          lineRange: try FileLineRange(startLine: startLine, lineCount: lineCount)
        )
      )
      return MCPProjectFileReadPage(
        relativePath: result.relativePath,
        startLine: result.startLine,
        endLine: result.endLine,
        content: result.content,
        redactedLineCount: result.redactedLineCount,
        truncated: result.truncated,
        nextStartLine: result.nextStartLine,
        sha256: result.sha256,
        byteCount: result.byteCount
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw Self.publicFileError(error)
    }
  }
}
