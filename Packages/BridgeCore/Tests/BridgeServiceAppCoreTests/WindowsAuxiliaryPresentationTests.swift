import BridgeMCP
import BridgeServiceAppCore
import Foundation
import XCTest

final class WindowsAuxiliaryPresentationTests: XCTestCase {
  func testCommandPresentationKeepsStableDraftIDAndSafetyDetails() {
    let draft = BridgeWorkspaceCommandDraft(
      name: "test",
      executable: "git",
      arguments: "status\ndiff",
      workingDirectory: "Sources",
      requiresNetwork: false,
      risk: "elevated"
    )

    let item = DirectWorkspacePresentation.command(draft)

    XCTAssertEqual(item.id, draft.id)
    XCTAssertTrue(item.rowText.contains("test"))
    XCTAssertTrue(item.detailText.contains("参数前缀：status\ndiff"))
    XCTAssertTrue(item.detailText.contains("风险：高风险"))
  }

  func testSkillPresentationIsReadOnlyAndIncludesActions() {
    let skill = try! JSONDecoder().decode(
      MCPServiceSkill.self,
      from: Data(
        "{\"name\":\"review\",\"description\":\"Review files\",\"scope\":\"project\",\"triggers\":[\"review\"],\"actions\":[],\"has_references\":true}"
          .utf8
      )
    )

    let item = DirectWorkspacePresentation.skill(skill)

    XCTAssertEqual(item.id, "review")
    XCTAssertTrue(item.detailText.contains("范围：project"))
    XCTAssertTrue(item.detailText.contains("References：有"))
  }

  func testTaskLogsFlattenNewestFirstWithProjectContext() {
    let task = MCPServiceTaskSnapshot(
      taskID: "task-1",
      projectID: "project-1",
      status: "completed",
      providerID: "codex",
      recentEvents: [
        MCPServiceTaskEvent(sequence: 2, kind: "file_edit", summary: "edited", occurredAt: "t2"),
        MCPServiceTaskEvent(sequence: 1, kind: "command", summary: "git status", occurredAt: "t1"),
      ],
      supervisorStatus: "disabled",
      localApprovalRequired: false,
      updatedAt: "t2"
    )

    let items = TaskLogPresentation.flatten(
      tasks: [task],
      projectNames: ["project-1": "Bridge"]
    )

    XCTAssertEqual(items.map(\.sequence), [2, 1])
    XCTAssertTrue(items[0].rowText.contains("Bridge"))
    XCTAssertTrue(items[1].detailText.contains("类型：命令"))
  }

  func testSettingsLabelsKeepUnknownValuesVisible() {
    XCTAssertEqual(DirectWorkspacePresentation.modeLabel("safe"), "安全模式")
    XCTAssertEqual(DirectWorkspacePresentation.effortLabel(""), "Provider 默认")
    XCTAssertEqual(DirectWorkspacePresentation.effortLabel("high"), "高")
    XCTAssertEqual(DirectWorkspacePresentation.effortLabel("max"), "最高")
    XCTAssertEqual(DirectWorkspacePresentation.effortLabel("ultra"), "Ultra")
    XCTAssertEqual(DirectWorkspacePresentation.accessModeLabel("future"), "未知：future")
  }

  func testEffortValuesFollowCatalogAndRetainUnknownSelection() {
    XCTAssertEqual(
      DirectWorkspacePresentation.effortValues(
        catalog: ["high", "minimal", "ultra", "high"],
        selected: ["future"],
        includesProviderDefault: true
      ),
      ["", "minimal", "high", "ultra", "future"]
    )
  }
}
