import BridgeMCP
import MCP
import XCTest

final class MCPServiceExposureTests: XCTestCase {
  func testProjectChangesUsesASeparateBoundedReadDeadline() {
    let deadlines = MCPServiceToolDeadlines.production

    XCTAssertEqual(deadlines.read, .seconds(15))
    XCTAssertEqual(deadlines.projectChanges, .seconds(20))
    XCTAssertGreaterThan(deadlines.projectChanges, deadlines.read)
  }

  func testServerInstructionsExposeGlobalInstructionsToChatGPTAndQwenBeforeToolUse() throws {
    let custom = String(repeating: "先说明操作再调用。", count: 20)
    XCTAssertGreaterThanOrEqual(custom.utf8.count, 440)
    for clientID in [MCPClientID.chatGPT, .qwenStudio] {
      let instructions = MCPServiceServerFactory.instructions(
        customInstructions: custom,
        clientID: clientID
      )
      XCTAssertTrue(instructions.contains(custom))
      XCTAssertTrue(instructions.contains("before calling any Codex Bridge tool"))
      XCTAssertTrue(instructions.contains("native ACP Plan/read-only"))
      XCTAssertTrue(instructions.contains("network_access does not override it"))
      XCTAssertTrue(instructions.contains("permission_mode_override=true"))
      XCTAssertTrue(instructions.contains("Unmarked permission_mode values are ignored"))
      XCTAssertTrue(instructions.contains("provider_session_id returned by get_task as thread_id"))
      XCTAssertTrue(instructions.contains("optional execution_model"))
      XCTAssertTrue(instructions.contains("registered Harness profile"))
      XCTAssertTrue(instructions.contains("wait_policy"))
      XCTAssertTrue(instructions.contains("120 seconds"))
      XCTAssertTrue(instructions.contains("300 seconds"))
      XCTAssertTrue(instructions.contains("600 seconds"))
      XCTAssertTrue(instructions.contains("non-terminal status"))
      XCTAssertTrue(instructions.contains("authoritative receipt"))
      XCTAssertTrue(instructions.contains("provider_task receipt with task_id"))
      XCTAssertTrue(instructions.contains("receipt-less action"))
      XCTAssertTrue(instructions.contains("non-null commit_hash"))
      XCTAssertFalse(instructions.contains("Project custom instructions"))
      let customRange = try XCTUnwrap(instructions.range(of: custom))
      XCTAssertLessThan(
        instructions.distance(from: instructions.startIndex, to: customRange.lowerBound), 512)
      XCTAssertLessThan(
        instructions.distance(from: instructions.startIndex, to: customRange.upperBound), 512)
      XCTAssertLessThan(
        customRange.lowerBound,
        try XCTUnwrap(instructions.range(of: "This service exposes")).lowerBound)
    }
  }

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
    XCTAssertEqual(names.count, 14)
    XCTAssertTrue(names.contains("list_agents"))
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
    XCTAssertEqual(names.count, 27)
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
      "list_agents",
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
    XCTAssertNotNil(exec["receipt_type"])
    XCTAssertEqual(exec["receipt_type"]?.objectValue?["const"], "direct_command")
    let skill = try outputProperties("run_skill_action", in: definitions)
    XCTAssertEqual(skill["receipt_type"]?.objectValue?["const"], "skill_action")
    let nestedOutput = try XCTUnwrap(exec["output"]?.objectValue?["properties"]?.objectValue)
    XCTAssertNil(nestedOutput["schema_version"])
    XCTAssertEqual(nestedOutput["exit_code"]?.objectValue?["type"], "integer")

    let read = try outputProperties("direct_read_command", in: definitions)
    XCTAssertNotNil(read["schema_version"])
    XCTAssertEqual(read["exit_code"]?.objectValue?["type"], "integer")
    XCTAssertNotNil(read["command_status"])
    XCTAssertNotNil(read["command_timed_out"])
    XCTAssertNotNil(read["read_timeout"])
    XCTAssertNotNil(read["execution_environment"])
    XCTAssertNotNil(read["receipt_type"])

    let readInput = try inputProperties("direct_read_command", in: definitions)
    XCTAssertEqual(readInput["wait_timeout_ms"]?.objectValue?["maximum"], .int(10_000))

    let status = try outputProperties("bridge_status", in: definitions)
    XCTAssertNotNil(status["execution_environment"])

    let agents = try outputProperties("list_agents", in: definitions)
    let agent = try XCTUnwrap(
      agents["agents"]?.objectValue?["items"]?.objectValue?["properties"]?.objectValue
    )
    XCTAssertNotNil(agent["effective_capabilities"])
    XCTAssertNotNil(agent["task_submission_enabled"])
    XCTAssertNotNil(agent["workspace_enforcement"])
    XCTAssertNil(agent["executable_path"])
    XCTAssertNil(agent["executable_sha256"])

    let task = try XCTUnwrap(
      outputProperties("get_task", in: definitions)["task"]?.objectValue?["properties"]?.objectValue
    )
    XCTAssertNotNil(task["permission_mode"])
    XCTAssertNotNil(task["network_access"])
    let waitPolicy = try XCTUnwrap(task["wait_policy"]?.objectValue)
    XCTAssertEqual(waitPolicy["type"], "object")
    let waitProperties = try XCTUnwrap(waitPolicy["properties"]?.objectValue)
    XCTAssertNotNil(waitProperties["wait_profile"])
    XCTAssertEqual(
      waitProperties["recommended_poll_after_seconds"]?.objectValue?["maximum"],
      .int(600)
    )
    XCTAssertNotNil(waitProperties["diagnostic_after_quiet_seconds"])
    XCTAssertNotNil(waitProperties["do_not_infer_failure"])
    let waitRequired = waitPolicy["required"]?.arrayValue ?? []
    XCTAssertTrue(waitRequired.contains(.string("recommended_poll_after_seconds")))
    XCTAssertTrue(waitRequired.contains(.string("next_action")))

    let submitWaitPolicy = try XCTUnwrap(
      definitions["submit_task"]?.outputSchema?.objectValue?["properties"]?.objectValue?[
        "wait_policy"]?.objectValue
    )
    XCTAssertEqual(submitWaitPolicy["type"], "object")

    let submit = try outputProperties("submit_task", in: definitions)
    XCTAssertNotNil(submit["receipt_type"])
    let mutation = try outputProperties("steer_task", in: definitions)
    XCTAssertNotNil(mutation["receipt_type"])

    for name in [
      "direct_write_project_file", "direct_edit_project_file",
      "direct_apply_project_patch", "direct_manage_project_path", "direct_git_commit",
    ] {
      XCTAssertNotNil(try outputProperties(name, in: definitions)["receipt_type"], name)
    }

    let stdin = try outputProperties("direct_write_stdin", in: definitions)
    XCTAssertEqual(
      stdin.keys.sorted(),
      [
        "bytes_written", "error", "receipt_type", "schema_version", "session_id",
        "stdin_closed",
      ]
    )

    let error = try XCTUnwrap(exec["error"]?.objectValue?["properties"]?.objectValue)
    XCTAssertNotNil(error["category"])
    XCTAssertNotNil(error["next_action"])
    XCTAssertNotNil(error["operation_id"])
    XCTAssertNotNil(error["data"])

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
    XCTAssertTrue(
      skillAction?.description?.contains("not a general command execution tool") == true)
    XCTAssertTrue(skillAction?.description?.contains("direct_exec_project_command") == true)

    let directExec = catalog.definitions.first { $0.name == "direct_exec_project_command" }
    XCTAssertTrue(directExec?.description?.contains("list_project_commands first") == true)
    XCTAssertTrue(directExec?.description?.contains("command_not_registered") == true)
  }

  func testDirectPatchDescriptionPublishesExecutableGrammar() throws {
    let catalog = MCPServiceToolCatalog(exposureMode: .full)
    let patch = try XCTUnwrap(
      catalog.definitions.first { $0.name == "direct_apply_project_patch" }
    )
    let description = try XCTUnwrap(patch.description)

    XCTAssertTrue(description.contains("*** Update File: relative/path"))
    XCTAssertTrue(description.contains("-old\n+new"))
    XCTAssertTrue(description.contains("exact context"))
  }

  func testDirectCommandInputSchemaPublishesStdinEOFAndNoPTY() throws {
    let catalog = MCPServiceToolCatalog(exposureMode: .full)
    let definitions = Dictionary(uniqueKeysWithValues: catalog.definitions.map { ($0.name, $0) })
    let stdin = try inputProperties("direct_write_stdin", in: definitions)
    let exec = try inputProperties("direct_exec_project_command", in: definitions)

    XCTAssertEqual(stdin["close_stdin"]?.objectValue?["type"], "boolean")
    XCTAssertEqual(exec["tty"]?.objectValue?["const"], false)
  }

  func testProjectIDsAreDocumentedAsOpaqueListProjectsResults() throws {
    let catalog = MCPServiceToolCatalog(exposureMode: .full)
    for definition in catalog.definitions {
      let properties = definition.inputSchema.objectValue?["properties"]?.objectValue ?? [:]
      guard let projectID = properties["project_id"]?.objectValue else { continue }
      let description = try XCTUnwrap(projectID["description"]?.stringValue)
      XCTAssertTrue(description.contains("Opaque project ID returned by list_projects"))
      XCTAssertTrue(description.contains("Never pass the display name"))
    }
  }

  func testListProjectCommandsPublishesRecommendedUsage() throws {
    let catalog = MCPServiceToolCatalog(exposureMode: .readOnly)
    let definitions = Dictionary(uniqueKeysWithValues: catalog.definitions.map { ($0.name, $0) })
    let output = try outputProperties("list_project_commands", in: definitions)
    let recommended = try XCTUnwrap(output["recommended_usage"]?.objectValue)
    XCTAssertEqual(recommended["type"], "object")
    let usage = try XCTUnwrap(recommended["additionalProperties"]?.objectValue)
    XCTAssertEqual(usage["required"]?.arrayValue, ["argv"])
  }

  func testSubmitTaskDescriptionNamesCodexAsDefault() {
    let catalog = MCPServiceToolCatalog(exposureMode: .full)
    guard let submit = catalog.definitions.first(where: { $0.name == "submit_task" }) else {
      return XCTFail("submit_task missing")
    }
    let description = submit.description ?? ""
    XCTAssertTrue(description.localizedCaseInsensitiveContains("default execution path"))
    XCTAssertTrue(description.localizedCaseInsensitiveContains("codex"))
    XCTAssertTrue(description.localizedCaseInsensitiveContains("workbench"))
    XCTAssertTrue(description.localizedCaseInsensitiveContains("omit all model and effort"))
    let required = submit.inputSchema.objectValue?["required"]?.arrayValue ?? []
    XCTAssertTrue(required.contains(.string("prompt")))
    XCTAssertFalse(required.contains(.string("project_id")))
    let properties = try? inputProperties("submit_task", in: ["submit_task": submit])
    let modelDescription = properties?["execution_model"]?.objectValue?["description"]
    XCTAssertTrue(
      modelDescription?.stringValue?.localizedCaseInsensitiveContains("Codex Bridge default")
        == true
    )
    XCTAssertEqual(
      properties?["model_override"]?.objectValue?["type"]?.arrayValue,
      [
        .string("boolean"), .string("null"),
      ])
    XCTAssertTrue(
      properties?["model_override"]?.objectValue?["description"]?.stringValue?
        .localizedCaseInsensitiveContains("explicitly requests") == true
    )
    XCTAssertTrue(description.contains("native ACP Plan"))
    XCTAssertTrue(description.contains("native ACP Build"))
    XCTAssertTrue(description.contains("permission_mode_override=true"))
    XCTAssertTrue(description.contains("network_access field does not override"))
    XCTAssertTrue(description.contains("provider_session_id"))
    XCTAssertTrue(description.contains("as thread_id"))
    XCTAssertTrue(description.contains("wait_policy"))
    XCTAssertTrue(description.contains("300 seconds"))
    XCTAssertFalse(description.contains("read-only in this version"))
    XCTAssertTrue(
      properties?["permission_mode"]?.objectValue?["description"]?.stringValue?
        .contains("native ACP Plan") == true
    )
    XCTAssertTrue(
      properties?["permission_mode_override"]?.objectValue?["description"]?.stringValue?
        .contains("user's request explicitly asks") == true
    )
    XCTAssertTrue(
      properties?["network_access"]?.objectValue?["description"]?.stringValue?
        .contains("does not override") == true
    )
  }

  func testListAgentsDescriptionAllowsSelectableOpenCodeSubmission() {
    let catalog = MCPServiceToolCatalog(exposureMode: .readOnly)
    guard let listAgents = catalog.definitions.first(where: { $0.name == "list_agents" }) else {
      return XCTFail("list_agents missing")
    }
    let description = listAgents.description ?? ""
    XCTAssertTrue(description.contains("submit_task"))
    XCTAssertFalse(description.contains("Gate 2"))
    XCTAssertFalse(description.contains("does not enable external Provider task submission"))
  }

  private func outputProperties(
    _ name: String,
    in definitions: [String: Tool]
  ) throws -> [String: Value] {
    try XCTUnwrap(
      definitions[name]?.outputSchema?.objectValue?["properties"]?.objectValue
    )
  }

  private func inputProperties(
    _ name: String,
    in definitions: [String: Tool]
  ) throws -> [String: Value] {
    try XCTUnwrap(
      definitions[name]?.inputSchema.objectValue?["properties"]?.objectValue
    )
  }
}
