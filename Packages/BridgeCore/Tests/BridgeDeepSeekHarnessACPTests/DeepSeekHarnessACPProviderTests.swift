import BridgeAgentCore
import BridgeDomain
import Foundation
import XCTest

@testable import BridgeDeepSeekHarnessACP

final class DeepSeekHarnessACPProviderTests: XCTestCase {
  func testInitializationIdentityIsOptionalButStrictWhenPresent() throws {
    let provider = try DeepSeekHarnessACPProvider()
    XCTAssertNoThrow(
      try provider.validate(
        DeepSeekHarnessACPInitialization(
          protocolVersion: 1,
          agentName: nil,
          agentTitle: nil,
          agentVersion: nil
        )
      )
    )
    XCTAssertThrowsError(
      try provider.validate(
        DeepSeekHarnessACPInitialization(
          protocolVersion: 1,
          agentName: "other-agent",
          agentTitle: nil,
          agentVersion: "0.0.1"
        )
      )
    ) { error in
      XCTAssertEqual(
        error as? AgentRuntimeError,
        .unsupportedProtocol("unexpected_deepseek_harness_identity")
      )
    }
  }

  func testEffectiveCapabilitiesExcludePermissionAndUnsupportedSelection() {
    let snapshot = DeepSeekHarnessACPProvider.capabilitySnapshot
    XCTAssertEqual(
      snapshot.effective,
      [.sessionCreate, .interrupt, .textDelta, .workspaceRead]
    )
    XCTAssertTrue(snapshot.advertised.contains(.oneShotApproval))
    XCTAssertTrue(snapshot.observed.contains(.oneShotApproval))
    XCTAssertFalse(snapshot.enforced.contains(.oneShotApproval))
  }

  func testRequestValidationRejectsMutationNetworkAndUnsupportedOverrides() async throws {
    let provider = try DeepSeekHarnessACPProvider(
      configuration: try DeepSeekHarnessACPProviderConfiguration(
        transportFactory: { _ in
          XCTFail("Validation must run before launch")
          return ScriptedDeepSeekHarnessTransport()
        }
      )
    )
    let project = FileManager.default.temporaryDirectory.path
    let installation = try AgentInstallation(
      id: .init(rawValue: "validation-installation"),
      providerID: .deepSeekHarness,
      executablePath: "/tmp/dsh-acp-demo"
    )

    let writeRequest = try AgentExecutionRequest(
      taskID: .init(rawValue: "write-task"),
      projectID: .init(rawValue: "project"),
      projectRoot: project,
      prompt: "write",
      mutationIntent: .workspaceWrite,
      workspaceStrategy: .sharedProject,
      networkAccessRequested: false
    )
    do {
      _ = try await provider.start(writeRequest, installation: installation)
      XCTFail("Expected write request rejection")
    } catch let error as AgentRuntimeError {
      XCTAssertEqual(error, .invalidRequest("request.mutationIntent"))
    }

    let networkRequest = try AgentExecutionRequest(
      taskID: .init(rawValue: "network-task"),
      projectID: .init(rawValue: "project"),
      projectRoot: project,
      prompt: "network",
      mutationIntent: .readOnly,
      workspaceStrategy: .sharedProject,
      networkAccessRequested: true
    )
    do {
      _ = try await provider.start(networkRequest, installation: installation)
      XCTFail("Expected network request rejection")
    } catch let error as AgentRuntimeError {
      XCTAssertEqual(error, .invalidRequest("request.networkAccessRequested"))
    }

    let modelRequest = try AgentExecutionRequest(
      taskID: .init(rawValue: "model-task"),
      projectID: .init(rawValue: "project"),
      projectRoot: project,
      prompt: "model",
      model: "deepseek-v4-pro",
      mutationIntent: .readOnly,
      workspaceStrategy: .sharedProject,
      networkAccessRequested: false
    )
    do {
      _ = try await provider.start(modelRequest, installation: installation)
      XCTFail("Expected model override rejection")
    } catch let error as AgentRuntimeError {
      XCTAssertEqual(error, .capabilityUnavailable(.modelSelection))
    }
  }
}
