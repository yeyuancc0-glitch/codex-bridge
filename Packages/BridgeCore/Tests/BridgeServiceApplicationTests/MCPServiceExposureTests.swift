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
  ])

  private let codexToolNames = Set([
    "submit_task",
    "steer_task",
    "interrupt_task",
  ])

  func testReadOnlyModeExposesCommandsAndObservationOnly() {
    let catalog = MCPServiceToolCatalog(exposureMode: .readOnly)
    let names = catalog.definitions.map(\.name)
    XCTAssertEqual(names.count, 11)
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
    XCTAssertEqual(names.count, 23)
    for name in directToolNames {
      XCTAssertTrue(names.contains(name), "full must expose \(name)")
    }
    for name in codexToolNames {
      XCTAssertTrue(names.contains(name), "full must expose \(name)")
    }
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
}
