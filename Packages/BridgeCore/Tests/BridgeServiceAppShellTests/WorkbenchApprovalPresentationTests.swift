import XCTest

@testable import BridgeServiceAppShell

final class WorkbenchApprovalPresentationTests: XCTestCase {
  func testFirstPendingApprovalRequestsReveal() {
    XCTAssertTrue(
      WorkbenchApprovalPresentation.shouldReveal(
        previous: [],
        current: ["codex:approval-1"]
      )
    )
  }

  func testAdditionalPendingApprovalRequestsReveal() {
    XCTAssertTrue(
      WorkbenchApprovalPresentation.shouldReveal(
        previous: ["codex:approval-1"],
        current: ["codex:approval-1", "direct:approval-1"]
      )
    )
  }

  func testUnchangedOrResolvedApprovalsDoNotRequestReveal() {
    XCTAssertFalse(
      WorkbenchApprovalPresentation.shouldReveal(
        previous: ["codex:approval-1"],
        current: ["codex:approval-1"]
      )
    )
    XCTAssertFalse(
      WorkbenchApprovalPresentation.shouldReveal(
        previous: ["codex:approval-1"],
        current: []
      )
    )
  }

  func testTranscriptToolPresentationUsesCodexStyleActivityLabels() {
    XCTAssertEqual(
      CodexTranscriptPresentation.tool(name: "read_files", status: "completed"),
      CodexTranscriptToolPresentation(title: "已读取文件", systemImage: "book")
    )
    XCTAssertEqual(
      CodexTranscriptPresentation.tool(name: "file_change", status: "inProgress"),
      CodexTranscriptToolPresentation(title: "正在编辑文件", systemImage: "pencil")
    )
    XCTAssertEqual(
      CodexTranscriptPresentation.tool(name: "command_execution", status: "failed"),
      CodexTranscriptToolPresentation(title: "已运行命令", systemImage: "terminal")
    )
  }

  func testTaskModelPresentationUsesActualTaskValues() {
    XCTAssertEqual(
      WorkbenchTaskModelPresentation.label(
        modelID: "gpt-5.6-luna",
        effort: "max",
        displayName: "Luna"
      ),
      "Luna · Max"
    )
    XCTAssertEqual(
      WorkbenchTaskModelPresentation.label(
        modelID: "gpt-5.6-sol",
        effort: "high",
        displayName: nil
      ),
      "gpt-5.6-sol · High"
    )
    XCTAssertEqual(
      WorkbenchTaskModelPresentation.label(
        modelID: "deepseek-chat",
        effort: nil,
        displayName: "DeepSeek Chat"
      ),
      "DeepSeek Chat"
    )
    XCTAssertEqual(
      WorkbenchTaskModelPresentation.label(
        modelID: "gemini-3.7-flash-high",
        effort: "provider-default",
        displayName: nil
      ),
      "gemini-3.7-flash-high"
    )
    XCTAssertEqual(
      WorkbenchTaskModelPresentation.label(
        modelID: "provider-default",
        effort: "provider-default",
        displayName: nil
      ),
      "Provider 默认（未报告具体模型）"
    )
    XCTAssertNil(
      WorkbenchTaskModelPresentation.label(
        modelID: nil,
        effort: "high",
        displayName: nil
      )
    )
  }

  func testOpenCodePermissionPresentationUsesNativePlanAndBuild() {
    XCTAssertEqual(
      WorkbenchAgentPermissionPresentation.title("workspace-write"),
      "Build（工作区可写）"
    )
    XCTAssertEqual(
      WorkbenchAgentPermissionPresentation.title("read-only"),
      "Plan（只读）"
    )
    XCTAssertEqual(
      WorkbenchAgentPermissionPresentation.title(nil),
      "权限未记录"
    )
  }

  func testProviderToolPresentationUsesProviderSpecificSemantics() {
    XCTAssertEqual(
      CodexTranscriptPresentation.tool(
        providerID: "codex",
        name: "search_files",
        status: "inProgress"
      ).title,
      "正在搜索文件"
    )
    XCTAssertEqual(
      CodexTranscriptPresentation.tool(
        providerID: "opencode",
        name: "web_search",
        status: "completed"
      ).title,
      "已搜索网页"
    )
    XCTAssertEqual(
      CodexTranscriptPresentation.tool(
        providerID: "deepseek-harness",
        name: "web_fetch",
        status: "completed"
      ).title,
      "已读取网页"
    )
    XCTAssertEqual(
      CodexTranscriptPresentation.tool(
        providerID: "deepseek-harness",
        name: "job_output",
        status: "inProgress"
      ).title,
      "正在读取后台任务输出"
    )
    XCTAssertEqual(
      CodexTranscriptPresentation.tool(
        providerID: "antigravity",
        name: "search_web",
        status: "inProgress"
      ).title,
      "正在搜索网页"
    )

    let naturalLanguageCases = [
      ("codex", "Search project files", AgentToolCategory.fileSearch),
      ("opencode", "Read project file", .fileRead),
      ("deepseek-harness", "Edit repository file", .fileWrite),
      ("antigravity", "Run terminal command", .command),
    ]
    for (providerID, name, expected) in naturalLanguageCases {
      XCTAssertEqual(
        CodexTranscriptPresentation.category(providerID: providerID, name: name),
        expected
      )
    }
  }

  func testProviderToolPresentationSeparatesSubagentAndThink() {
    XCTAssertEqual(
      CodexTranscriptPresentation.category(
        providerID: "opencode",
        name: "think"
      ),
      .reasoning
    )
    XCTAssertEqual(
      CodexTranscriptPresentation.category(
        providerID: "opencode",
        name: "task"
      ),
      .subagent
    )
    XCTAssertEqual(
      CodexTranscriptPresentation.category(
        providerID: "deepseek-harness",
        name: "subagent_fork"
      ),
      .subagent
    )
    XCTAssertEqual(
      CodexTranscriptPresentation.category(
        providerID: "antigravity",
        name: "delegate_subagent"
      ),
      .subagent
    )
  }

  func testUnknownToolPresentationKeepsSafeProviderName() {
    XCTAssertEqual(
      CodexTranscriptPresentation.tool(
        providerID: "opencode",
        name: "custom-operation",
        status: "inProgress"
      ).title,
      "正在使用 OpenCode 工具：custom-operation"
    )
    XCTAssertEqual(
      CodexTranscriptPresentation.tool(
        providerID: "deepseek-harness",
        name: "custom operation",
        status: "cancelled"
      ).title,
      "已使用 DeepSeek Harness 工具：custom operation"
    )
    XCTAssertEqual(CodexTranscriptPresentation.statusLabel("declined"), "已拒绝")
    XCTAssertEqual(CodexTranscriptPresentation.statusLabel("cancelled"), "已取消")
  }

  func testMarkdownTextParsesCommonFormattingWithoutSyntaxCharacters() throws {
    let parsed = try XCTUnwrap(
      AgentMarkdownText.attributedString(
        from: "## 标题\n\n- **项目** `文件`\n\n1. [链接](https://example.test)"
      )
    )
    let renderedCharacters = String(parsed.characters)
    XCTAssertTrue(renderedCharacters.contains("标题"))
    XCTAssertTrue(renderedCharacters.contains("项目"))
    XCTAssertTrue(renderedCharacters.contains("文件"))
    XCTAssertFalse(renderedCharacters.contains("#"))
    XCTAssertFalse(renderedCharacters.contains("*"))
    XCTAssertFalse(renderedCharacters.contains("`"))
  }

  func testMarkdownTextRepairsIncompleteStreamingMarkers() throws {
    for value in ["**正在处理", "*正在分析", "`AGENTS.md"] {
      let parsed = try XCTUnwrap(AgentMarkdownText.attributedString(from: value))
      let renderedCharacters = String(parsed.characters)
      XCTAssertFalse(renderedCharacters.contains("*"), value)
      XCTAssertFalse(renderedCharacters.contains("`"), value)
    }
  }

  func testMarkdownTextPreservesLiteralSymbolsInsideCode() throws {
    let parsed = try XCTUnwrap(
      AgentMarkdownText.attributedString(from: "`*.swift` 和 `#selector`")
    )
    XCTAssertEqual(String(parsed.characters), "*.swift 和 #selector")
  }
}
