import BridgeMCP
import MCP
import XCTest

final class MCPServiceExposureTests: XCTestCase {
  private let directToolNames = Set([
    "direct_write_project_file",
    "direct_edit_project_file",
    "direct_apply_project_patch",
    "direct_manage_project_path",
    "direct_exec_project_command",
    "direct_read_command",
    "direct_write_stdin",
    "direct_interrupt_command",
    "direct_git_commit",
  ])

  private let codexToolNames = Set([
    "submit_task",
    "steer_task",
    "interrupt_task",
  ])

  private let skillActionToolName = "run_skill_action"

  func testReadOnlyModeExposesCommandsAndObservationOnly() {
    let catalog = MCPServiceToolCatalog(exposureMode: .readOnly)
    let names = catalog.definitions.map(\.name)
    XCTAssertEqual(names.count, 13)
    XCTAssertTrue(names.contains("list_project_commands"))
    XCTAssertTrue(names.contains("get_project_changes"))
    for name in directToolNames {
      XCTAssertFalse(names.contains(name), "readOnly must not expose \(name)")
    }
    for name in codexToolNames {
      XCTAssertFalse(names.contains(name), "readOnly must not expose \(name)")
    }
  }

  func testFullModeExposesDirectAndCodexActions() {
    let catalog = MCPServiceToolCatalog(exposureMode: .full)
    let names = catalog.definitions.map(\.name)
    XCTAssertEqual(names.count, 26)
    for name in directToolNames {
      XCTAssertTrue(names.contains(name), "full must expose \(name)")
    }
    for name in codexToolNames {
      XCTAssertTrue(names.contains(name), "full must expose \(name)")
    }
    XCTAssertTrue(names.contains(skillActionToolName))
  }

  func testExposureCatalogHasStableUniqueOrder() {
    let expectedReadOnly = [
      "bridge_status",
      "list_projects",
      "get_project",
      "search_project_files",
      "read_project_file",
      "list_threads",
      "read_thread",
      "list_models",
      "list_skills",
      "read_skill",
      "get_task",
      "get_project_changes",
      "list_project_commands",
    ]
    let expectedFullOnly = [
      "submit_task",
      "run_skill_action",
      "steer_task",
      "interrupt_task",
      "direct_write_project_file",
      "direct_edit_project_file",
      "direct_apply_project_patch",
      "direct_manage_project_path",
      "direct_exec_project_command",
      "direct_read_command",
      "direct_write_stdin",
      "direct_interrupt_command",
      "direct_git_commit",
    ]

    let readOnly = MCPServiceToolCatalog(exposureMode: .readOnly).definitions.map(\.name)
    let full = MCPServiceToolCatalog(exposureMode: .full).definitions.map(\.name)
    XCTAssertEqual(readOnly, expectedReadOnly)
    XCTAssertEqual(full, expectedReadOnly + expectedFullOnly)
    XCTAssertEqual(Set(full).count, full.count)
  }

  func testDirectOutputSchemasMatchPublishedResultEnvelopes() throws {
    let catalog = MCPServiceToolCatalog(exposureMode: .full)
    let definitions = Dictionary(uniqueKeysWithValues: catalog.definitions.map { ($0.name, $0) })

    let exec = try outputProperties("direct_exec_project_command", in: definitions)
    XCTAssertEqual(exec["schema_version"]?.objectValue?["type"], "integer")
    XCTAssertEqual(
      exec["exit_code"]?.objectValue?["type"],
      "integer"
    )
    let nestedOutput = try XCTUnwrap(exec["output"]?.objectValue?["properties"]?.objectValue)
    XCTAssertNil(nestedOutput["schema_version"])
    XCTAssertEqual(nestedOutput["exit_code"]?.objectValue?["type"], "integer")

    let read = try outputProperties("direct_read_command", in: definitions)
    XCTAssertNotNil(read["schema_version"])
    XCTAssertEqual(read["exit_code"]?.objectValue?["type"], "integer")

    let stdin = try outputProperties("direct_write_stdin", in: definitions)
    XCTAssertEqual(stdin.keys.sorted(), ["error", "schema_version"])

    let git = try XCTUnwrap(definitions["direct_git_commit"]?.outputSchema?.objectValue)
    let success = try XCTUnwrap(git["oneOf"]?.arrayValue?.first?.objectValue)
    XCTAssertEqual(
      success["properties"]?.objectValue?["schema_version"]?.objectValue?["const"],
      2
    )
  }

  func testDirectToolDescriptionsRequireExplicitOptIn() {
    let catalog = MCPServiceToolCatalog(exposureMode: .full)
    for definition in catalog.definitions where directToolNames.contains(definition.name) {
      let description = definition.description ?? ""
      XCTAssertTrue(
        description.localizedCaseInsensitiveContains("explicit"),
        "\(definition.name) must require explicit user intent"
      )
      XCTAssertTrue(
        description.localizedCaseInsensitiveContains("use only when the user explicitly"),
        "\(definition.name) must state the explicit opt-in precondition"
      )
    }
    let skillAction = catalog.definitions.first { $0.name == skillActionToolName }
    XCTAssertTrue(skillAction?.description?.localizedCaseInsensitiveContains("explicit") == true)
  }

  func testSubmitTaskDescriptionNamesCodexAsDefault() {
    let catalog = MCPServiceToolCatalog(exposureMode: .full)
    guard let submit = catalog.definitions.first(where: { $0.name == "submit_task" }) else {
      return XCTFail("submit_task missing")
    }
    let description = submit.description ?? ""
    XCTAssertTrue(description.localizedCaseInsensitiveContains("default execution path"))
    XCTAssertTrue(description.localizedCaseInsensitiveContains("codex"))
  }

  private func outputProperties(
    _ name: String,
    in definitions: [String: Tool]
  ) throws -> [String: Value] {
    try XCTUnwrap(
      definitions[name]?.outputSchema?.objectValue?["properties"]?.objectValue
    )
  }
}
