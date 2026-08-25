import BridgeMCP
import CryptoKit
import Foundation
import MCP
import XCTest

@testable import BridgeServiceApplication

final class DirectSecretScanRegressionTests: XCTestCase {
  func testDirectEditCanRemoveExistingCredentialFixtureWithoutReturningIt() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript
    )
    try await application.serviceSetDirectApprovalMode(
      .auto,
      deadline: ContinuousClock.now.advanced(by: .seconds(3))
    )
    let dispatcher = MCPServiceToolDispatcher(service: application, exposureMode: .full)
    let target = fixture.root.appending(path: "CredentialFixture.swift")
    let unsafeLine = #"const api_key = "definitely-secret";"#
    let original = unsafeLine + "\nlet safeValue = 1\n"
    try Data(original.utf8).write(to: target)

    let result = try await dispatcher.call(
      .init(
        name: MCPServiceToolName.directEditProjectFile.rawValue,
        arguments: [
          "project_id": .string(fixture.project.id.rawValue),
          "relative_path": .string(target.lastPathComponent),
          "expected_sha256": .string(sha256(Data(original.utf8))),
          "old_text": .string(unsafeLine),
          "new_text": .string("let fixtureKeyName = [\"api\", \"key\"].joined()"),
        ]
      )
    )

    XCTAssertEqual(result.isError, false)
    XCTAssertFalse(String(describing: result.structuredContent).contains("definitely-secret"))
    XCTAssertTrue(String(describing: result.structuredContent).contains("REDACTED"))
    XCTAssertFalse(try String(contentsOf: target).contains("definitely-secret"))
  }

  func testDirectPatchScansIntroductionsButNotCredentialRemovals() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript
    )
    try await application.serviceSetDirectApprovalMode(
      .auto,
      deadline: ContinuousClock.now.advanced(by: .seconds(3))
    )
    let dispatcher = MCPServiceToolDispatcher(service: application, exposureMode: .full)
    let target = fixture.root.appending(path: "PatchFixture.swift")
    let unsafeLine = #"const api_key = "definitely-secret";"#
    try Data((unsafeLine + "\n").utf8).write(to: target)

    let removal = try await dispatcher.call(
      .init(
        name: MCPServiceToolName.directApplyProjectPatch.rawValue,
        arguments: [
          "project_id": .string(fixture.project.id.rawValue),
          "patch": .string(
            "*** Update File: \(target.lastPathComponent)\n@@\n-\(unsafeLine)\n+let safeValue = 1"
          ),
        ]
      )
    )
    XCTAssertEqual(removal.isError, false)
    XCTAssertFalse(String(describing: removal.structuredContent).contains("definitely-secret"))
    XCTAssertEqual(try String(contentsOf: target), "let safeValue = 1\n")

    do {
      _ = try await dispatcher.call(
        .init(
          name: MCPServiceToolName.directApplyProjectPatch.rawValue,
          arguments: [
            "project_id": .string(fixture.project.id.rawValue),
            "patch": .string(
              "*** Update File: \(target.lastPathComponent)\n@@\n-let safeValue = 1\n+const api_key = \"new-secret-value\";"
            ),
          ]
        )
      )
      XCTFail("Expected a credential introduced by the patch to be rejected")
    } catch let error as MCPError {
      guard case .invalidParams = error else {
        return XCTFail("Unexpected MCP error: \(error)")
      }
    }
  }

  private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
