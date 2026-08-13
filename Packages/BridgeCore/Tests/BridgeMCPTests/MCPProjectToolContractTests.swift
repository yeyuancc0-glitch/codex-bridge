import MCP
import XCTest

@testable import BridgeMCP

final class MCPProjectToolContractTests: XCTestCase {
  func testProjectToolsAreOptInAndPreserveOriginalCatalog() {
    XCTAssertEqual(MCPToolCatalog().definitions.count, 5)
    XCTAssertEqual(MCPToolCatalog(includeTaskTools: true).definitions.count, 12)
    XCTAssertEqual(MCPToolCatalog(includeProjectTools: true).definitions.count, 9)
    let complete = MCPToolCatalog(
      includeTaskTools: true,
      includeProjectTools: true
    ).definitions.map(\.name)
    XCTAssertEqual(complete.count, 16)
    XCTAssertTrue(Set(MCPProjectToolName.allCases.map(\.rawValue)).isSubset(of: Set(complete)))
    XCTAssertFalse(complete.contains("respond_to_codex_approval"))
  }

  func testProjectFileArgumentsAreStrictAndResultsAreStructured() async throws {
    let operations = ProjectOperationsFixture()
    let dispatcher = MCPToolDispatcher(
      queries: ProjectQueriesFixture(),
      projectOperations: operations
    )

    let search = try await dispatcher.call(
      CallTool.Parameters(
        name: MCPProjectToolName.searchProjectFiles.rawValue,
        arguments: [
          "project_id": "prj_test",
          "query": "needle",
          "limit": 1,
          "case_sensitive": false,
        ]
      ),
      sessionID: "project"
    )
    XCTAssertFalse(search.isError == true)
    let structured = try XCTUnwrap(search.structuredContent?.objectValue)
    XCTAssertEqual(structured["schema_version"], 1)
    XCTAssertEqual(structured["skipped_file_count"], 2)

    do {
      _ = try await dispatcher.call(
        CallTool.Parameters(
          name: MCPProjectToolName.readProjectFile.rawValue,
          arguments: [
            "project_id": "prj_test",
            "relative_path": "/Users/example/secret",
          ]
        ),
        sessionID: "project"
      )
      XCTFail("Expected an absolute path to be rejected")
    } catch {
      guard case MCPError.invalidParams = error else {
        return XCTFail("Expected invalid params, got \(error)")
      }
    }

    let sensitiveName = try await dispatcher.call(
      CallTool.Parameters(
        name: MCPProjectToolName.readProjectFile.rawValue,
        arguments: [
          "project_id": "prj_test",
          "relative_path": "password=actual-secret-value.swift",
        ]
      ),
      sessionID: "project"
    )
    XCTAssertFalse(sensitiveName.isError == true)
    XCTAssertEqual(
      sensitiveName.structuredContent?.objectValue?["relative_path"],
      "[redacted-sensitive-path]"
    )
    XCTAssertFalse(String(describing: sensitiveName).contains("actual-secret-value"))
  }

  func testProjectOutputsWithAbsolutePathsOrSecretsFailClosed() async throws {
    let dispatcher = MCPToolDispatcher(
      queries: ProjectQueriesFixture(),
      projectOperations: UnsafeProjectOperationsFixture()
    )

    do {
      _ = try await dispatcher.call(
        CallTool.Parameters(
          name: MCPProjectToolName.readProjectFile.rawValue,
          arguments: [
            "project_id": "prj_test",
            "relative_path": "Sources/App.swift",
          ]
        ),
        sessionID: "unsafe"
      )
      XCTFail("Expected unsafe adapter output to fail closed")
    } catch {
      guard case MCPError.internalError = error else {
        return XCTFail("Expected a sanitized internal error, got \(error)")
      }
    }
  }

  func testProjectOutputPaginationAndEveryStringFailClosed() async throws {
    for output in [
      UnsafeProjectOutput.cursor, .longRelativePath, .readPage, .contentLineCount,
      .projectMetadata,
    ] {
      let dispatcher = MCPToolDispatcher(
        queries: ProjectQueriesFixture(),
        projectOperations: UnsafeProjectOperationsFixture(output: output)
      )
      do {
        switch output {
        case .cursor:
          _ = try await dispatcher.call(
            CallTool.Parameters(
              name: MCPProjectToolName.searchProjectFiles.rawValue,
              arguments: ["project_id": "prj_test", "query": "needle"]
            ),
            sessionID: "unsafe-cursor"
          )
        case .longRelativePath:
          _ = try await dispatcher.call(
            CallTool.Parameters(
              name: MCPProjectToolName.searchProjectFiles.rawValue,
              arguments: ["project_id": "prj_test", "query": "needle"]
            ),
            sessionID: "unsafe-path"
          )
        case .readPage:
          _ = try await dispatcher.call(
            CallTool.Parameters(
              name: MCPProjectToolName.readProjectFile.rawValue,
              arguments: [
                "project_id": "prj_test", "relative_path": "Sources/App.swift",
                "start_line": 4,
              ]
            ),
            sessionID: "unsafe-page"
          )
        case .contentLineCount:
          _ = try await dispatcher.call(
            CallTool.Parameters(
              name: MCPProjectToolName.readProjectFile.rawValue,
              arguments: [
                "project_id": "prj_test", "relative_path": "Sources/App.swift",
                "line_count": 1,
              ]
            ),
            sessionID: "unsafe-lines"
          )
        case .projectMetadata:
          _ = try await dispatcher.call(
            CallTool.Parameters(
              name: MCPProjectToolName.getProject.rawValue,
              arguments: ["project_id": "prj_test"]
            ),
            sessionID: "unsafe-project"
          )
        case .content:
          XCTFail("Content is covered by the dedicated output test")
        }
        XCTFail("Expected unsafe adapter output to fail closed")
      } catch {
        guard case MCPError.internalError = error else {
          return XCTFail("Expected a sanitized internal error, got \(error)")
        }
      }
    }
  }
}

private struct ProjectOperationsFixture: BridgeMCPProjectOperations {
  func getProject(
    projectID: String,
    deadline _: ContinuousClock.Instant
  ) -> MCPProjectDetail {
    MCPProjectDetail(
      projectID: projectID,
      name: "Bridge",
      capabilities: MCPProjectCapabilities(read: "allowed", write: "denied", network: "denied"),
      verificationCommands: ["swift test"]
    )
  }

  func searchProjectFiles(
    projectID _: String,
    query _: String,
    relativeDirectory _: String?,
    caseSensitive _: Bool,
    cursor _: String?,
    limit _: Int,
    deadline _: ContinuousClock.Instant
  ) -> MCPProjectFileSearchPage {
    MCPProjectFileSearchPage(
      matches: [
        MCPProjectFileSearchMatch(
          relativePath: "Sources/App.swift",
          lineNumber: 3,
          preview: "needle",
          redacted: false
        )
      ],
      skippedFileCount: 2
    )
  }

  func readProjectFile(
    projectID _: String,
    relativePath: String,
    startLine: Int,
    lineCount _: Int,
    deadline _: ContinuousClock.Instant
  ) -> MCPProjectFileReadPage {
    MCPProjectFileReadPage(
      relativePath: relativePath,
      startLine: startLine,
      endLine: startLine,
      content: "let value = 1",
      redactedLineCount: 0,
      truncated: false,
      nextStartLine: nil
    )
  }

  func openInCodex(
    projectID: String,
    threadID: String,
    deadline _: ContinuousClock.Instant
  ) -> MCPOpenInCodexReceipt {
    MCPOpenInCodexReceipt(projectID: projectID, threadID: threadID, opened: true)
  }
}

private enum UnsafeProjectOutput: Equatable {
  case content
  case contentLineCount
  case cursor
  case longRelativePath
  case readPage
  case projectMetadata
}

private struct UnsafeProjectOperationsFixture: BridgeMCPProjectOperations {
  let output: UnsafeProjectOutput

  init(output: UnsafeProjectOutput = .content) {
    self.output = output
  }

  func getProject(
    projectID: String,
    deadline _: ContinuousClock.Instant
  ) -> MCPProjectDetail {
    MCPProjectDetail(
      projectID: projectID,
      name: "Bridge",
      capabilities: MCPProjectCapabilities(read: "allowed", write: "denied", network: "denied"),
      gitState: output == .projectMetadata ? "file:///Users/example/repository" : nil
    )
  }

  func searchProjectFiles(
    projectID _: String,
    query _: String,
    relativeDirectory _: String?,
    caseSensitive _: Bool,
    cursor _: String?,
    limit _: Int,
    deadline _: ContinuousClock.Instant
  ) -> MCPProjectFileSearchPage {
    MCPProjectFileSearchPage(
      matches:
        output == .longRelativePath
        ? [
          MCPProjectFileSearchMatch(
            relativePath: String(repeating: "a", count: 1_025),
            lineNumber: 1,
            preview: "needle",
            redacted: false
          )
        ] : [],
      nextCursor: output == .cursor ? "](/Volumes/private/cursor)" : nil
    )
  }

  func readProjectFile(
    projectID _: String,
    relativePath: String,
    startLine: Int,
    lineCount _: Int,
    deadline _: ContinuousClock.Instant
  ) -> MCPProjectFileReadPage {
    MCPProjectFileReadPage(
      relativePath: relativePath,
      startLine: output == .readPage ? startLine + 1 : startLine,
      endLine: output == .readPage ? startLine + 1 : startLine,
      content:
        output == .contentLineCount
        ? "first\nsecond" : "Read file:///Users/example/secret and ](/Volumes/private/file)",
      redactedLineCount: 0,
      truncated: false,
      nextStartLine: nil
    )
  }

  func openInCodex(
    projectID: String,
    threadID: String,
    deadline _: ContinuousClock.Instant
  ) -> MCPOpenInCodexReceipt {
    MCPOpenInCodexReceipt(projectID: projectID, threadID: threadID, opened: true)
  }
}

private struct ProjectQueriesFixture: BridgeMCPQueries {
  func statusSnapshot(deadline _: ContinuousClock.Instant) -> BridgeStatusSnapshot {
    BridgeStatusSnapshot(
      appVersion: "test",
      mcpState: "ready",
      tunnelState: "stopped",
      executionState: "idle",
      supervisorState: "idle",
      pendingApprovalCount: 0
    )
  }

  func listMCPVisibleProjects(
    cursor _: String?,
    limit _: Int,
    deadline _: ContinuousClock.Instant
  ) -> MCPProjectPage { MCPProjectPage(projects: []) }

  func listThreads(
    projectID _: String,
    cursor _: String?,
    limit _: Int,
    search _: String?,
    deadline _: ContinuousClock.Instant
  ) -> MCPThreadPage { MCPThreadPage(threads: []) }

  func readThread(
    projectID _: String,
    threadID _: String,
    detail _: MCPThreadDetail,
    cursor _: String?,
    limit _: Int,
    deadline _: ContinuousClock.Instant
  ) throws -> MCPThreadReadPage { throw BridgeMCPQueryError.threadNotFound }

  func listModels(deadline _: ContinuousClock.Instant) -> MCPModelList {
    MCPModelList(models: [])
  }
}
