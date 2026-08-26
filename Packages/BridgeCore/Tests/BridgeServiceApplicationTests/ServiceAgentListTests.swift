import BridgeAgentCore
import BridgeMCP
import BridgeServiceApplication
import BridgeServiceCore
import Darwin
import Foundation
import MCP
import XCTest

final class ServiceAgentListTests: XCTestCase {
  func testListAgentsReturnsOnlyPersistedProbeFactsAndEnablesReadOnlySubmission() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let executableURL = fixture.root.appending(path: "opencode-list-fixture")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executableURL)
    XCTAssertEqual(chmod(executableURL.path, 0o700), 0)
    let provider = try ServiceAgentListProvider()
    let registry = ServiceAgentRegistry(
      store: fixture.store,
      providers: [provider],
      makeInstallationID: { AgentInstallationID(rawValue: "ainst-list-opencode") }
    )
    let registered = try await registry.registerAndProbe(
      ServiceAgentRegistrationRequest(
        providerID: .openCode,
        displayName: "OpenCode",
        executablePath: executableURL.path,
        trustProfile: .managed,
        securityProfileID: AgentProfileID(rawValue: "controlled-readonly"),
        enableOnSuccess: true,
        projectRoot: fixture.project.root.canonicalPath
      )
    )
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript,
      agentRegistry: registry
    )
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))

    let list = try await application.serviceAgents(
      projectID: fixture.project.id.rawValue,
      deadline: deadline
    )

    let agent = try XCTUnwrap(list.agents.first)
    XCTAssertEqual(list.agents.count, 1)
    XCTAssertEqual(agent.providerID, AgentProviderID.openCode.rawValue)
    XCTAssertEqual(agent.installationID, registered.id.rawValue)
    XCTAssertEqual(agent.availability, "available")
    XCTAssertTrue(agent.enabled)
    XCTAssertTrue(agent.taskSubmissionEnabled)
    XCTAssertEqual(agent.version, "1.18.22")
    XCTAssertEqual(agent.protocolRevision, "1")
    XCTAssertEqual(agent.adapterRevision, 1)
    XCTAssertEqual(agent.effectiveCapabilities, [AgentCapability.workspaceRead.rawValue])
    XCTAssertEqual(agent.trustProfile, AgentTrustProfile.managed.rawValue)
    XCTAssertEqual(agent.securityProfileID, "controlled-readonly")
    XCTAssertEqual(agent.workspaceEnforcement, "os_sandbox")
    XCTAssertEqual(agent.approvalEnforcement, "none")
    XCTAssertEqual(agent.networkEnforcement, "provider")
    XCTAssertTrue(agent.modelsSummary.isEmpty)
    XCTAssertNil(agent.unavailableReason)
    XCTAssertNotNil(agent.lastVerifiedAt)

    let dispatcher = MCPServiceToolDispatcher(service: application, exposureMode: .readOnly)
    let result = try await dispatcher.call(
      .init(
        name: MCPServiceToolName.listAgents.rawValue,
        arguments: ["project_id": .string(fixture.project.id.rawValue)]
      )
    )
    let structured = try XCTUnwrap(result.structuredContent?.objectValue)
    let dispatchedAgents = try XCTUnwrap(structured["agents"]?.arrayValue)
    XCTAssertEqual(dispatchedAgents.count, 1)
    XCTAssertEqual(
      dispatchedAgents[0].objectValue?["installation_id"],
      .string(registered.id.rawValue)
    )
    XCTAssertEqual(
      dispatchedAgents[0].objectValue?["task_submission_enabled"],
      .bool(true)
    )

    let encoded = try JSONEncoder().encode(ListAgentsOutput(list: list))
    let output = try XCTUnwrap(String(data: encoded, encoding: .utf8))
    XCTAssertFalse(output.contains(executableURL.path))
    XCTAssertFalse(output.contains(registered.executableIdentity.sha256))
  }

  func testListAgentsRejectsUnknownProjectBeforeReadingInstallations() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript,
      agentRegistry: ServiceAgentRegistry(store: fixture.store, providers: [])
    )

    do {
      _ = try await application.serviceAgents(
        projectID: "prj-unknown",
        deadline: ContinuousClock.now.advanced(by: .seconds(3))
      )
      XCTFail("Expected an unknown project to be rejected")
    } catch {
      XCTAssertEqual(error as? BridgeMCPQueryError, .projectNotFound)
    }
  }
}

private struct ServiceAgentListProvider: AgentProvider, Sendable {
  let descriptor: AgentProviderDescriptor

  init() throws {
    descriptor = try AgentProviderDescriptor(
      providerID: .openCode,
      displayName: "OpenCode",
      adapterRevision: 1
    )
  }

  func probe(_ request: AgentProbeRequest) async -> AgentProbeResult {
    guard
      let installation = try? AgentInstallation(
        id: request.installation.id,
        providerID: request.installation.providerID,
        executablePath: request.installation.executablePath,
        version: "1.18.22",
        protocolRevision: "1"
      )
    else {
      return AgentProbeResult(
        installation: request.installation,
        available: false,
        capabilities: .empty,
        unavailableReason: "The fixture installation is invalid."
      )
    }
    let capabilities: Set<AgentCapability> = [.workspaceRead]
    return AgentProbeResult(
      installation: installation,
      available: true,
      capabilities: AgentCapabilitySnapshot(
        advertised: capabilities,
        observed: capabilities,
        enforced: capabilities
      )
    )
  }

  func start(
    _ request: AgentExecutionRequest,
    installation: AgentInstallation
  ) async throws -> AgentExecutionHandle {
    throw AgentRuntimeError.processUnavailable
  }
}
