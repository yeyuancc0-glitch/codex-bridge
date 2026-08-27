import BridgeAgentCore
import BridgeDomain
import CryptoKit
import Darwin
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

  func testEffectiveCapabilitiesIncludeEnforcedSelectionButExcludePermission() {
    let snapshot = DeepSeekHarnessACPProvider.capabilitySnapshot
    XCTAssertEqual(
      snapshot.effective,
      [
        .sessionCreate, .interrupt, .textDelta, .workspaceRead, .modelSelection,
        .effortSelection,
      ]
    )
    XCTAssertTrue(snapshot.advertised.contains(.oneShotApproval))
    XCTAssertTrue(snapshot.observed.contains(.oneShotApproval))
    XCTAssertFalse(snapshot.enforced.contains(.oneShotApproval))
  }

  func testCatalogComesFromDeepSeekProfileWithoutAnotherProvider() async throws {
    let provider = try DeepSeekHarnessACPProvider()
    let fixture = try makeCatalogInstallation()
    addTeardownBlock { try? FileManager.default.removeItem(atPath: fixture.directory) }

    let models = try await provider.models(
      installation: fixture.installation,
      projectRoot: nil,
      selectedModelID: "opencode-go/deepseek-v4-pro"
    )

    XCTAssertEqual(models.map(\.id), ["deepseek-v4-pro"])
    XCTAssertEqual(models[0].supportedReasoningEfforts, ["off", "low", "high", "max"])
    XCTAssertEqual(models[0].defaultReasoningEffort, "max")
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
    let fixture = try makeCatalogInstallation()
    addTeardownBlock { try? FileManager.default.removeItem(atPath: fixture.directory) }
    let installation = fixture.installation

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
      model: "other-provider/deepseek-v4-pro",
      mutationIntent: .readOnly,
      workspaceStrategy: .sharedProject,
      networkAccessRequested: false
    )
    do {
      _ = try await provider.start(modelRequest, installation: installation)
      XCTFail("Expected foreign model rejection")
    } catch let error as AgentRuntimeError {
      XCTAssertEqual(error, .modelUnavailable("other-provider/deepseek-v4-pro"))
    }

    let effortRequest = try AgentExecutionRequest(
      taskID: .init(rawValue: "effort-task"),
      projectID: .init(rawValue: "project"),
      projectRoot: project,
      prompt: "effort",
      effort: "ultra",
      mutationIntent: .readOnly,
      workspaceStrategy: .sharedProject,
      networkAccessRequested: false
    )
    do {
      _ = try await provider.start(effortRequest, installation: installation)
      XCTFail("Expected unsupported effort rejection")
    } catch let error as AgentRuntimeError {
      XCTAssertEqual(error, .invalidRequest("request.effort"))
    }
  }

  private func makeCatalogInstallation() throws -> (
    installation: AgentInstallation, directory: String
  ) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("deepseek-provider-catalog-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(
      atPath: directory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    let executable = URL(fileURLWithPath: directory).appendingPathComponent("dsh-acp-demo").path
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: URL(fileURLWithPath: executable))
    XCTAssertEqual(chmod(executable, 0o700), 0)

    var artifacts: [AgentInstallationArtifact] = []
    for role in AgentInstallationArtifactRole.allCases {
      let path = URL(fileURLWithPath: directory).appendingPathComponent(role.rawValue).path
      let data =
        role == .launchConfiguration
        ? try DeepSeekHarnessACPProfile.bundledConfigurationTemplate()
        : Data("fixture\n".utf8)
      try data.write(to: URL(fileURLWithPath: path))
      artifacts.append(try artifact(role: role, path: path, data: data))
    }
    return try (
      AgentInstallation(
        id: .init(rawValue: "catalog-installation"),
        providerID: .deepSeekHarness,
        executablePath: executable,
        artifacts: artifacts
      ),
      directory
    )
  }

  private func artifact(
    role: AgentInstallationArtifactRole,
    path: String,
    data: Data
  ) throws -> AgentInstallationArtifact {
    var metadata = stat()
    guard lstat(path, &metadata) == 0 else { throw POSIXError(.ENOENT) }
    let modificationTime =
      Int64(metadata.st_mtimespec.tv_sec) * 1_000_000_000
      + Int64(metadata.st_mtimespec.tv_nsec)
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return AgentInstallationArtifact(
      role: role,
      canonicalPath: path,
      device: UInt64(metadata.st_dev),
      inode: UInt64(metadata.st_ino),
      fileSize: UInt64(metadata.st_size),
      modificationTimeNanoseconds: modificationTime,
      sha256: digest
    )
  }
}
