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

  func testCatalogComesFromHarnessACPWithoutAnotherProvider() async throws {
    let transport = ScriptedDeepSeekHarnessTransport()
    await transport.setHandler { message, transport in
      guard let id = message.id else { return }
      switch message.method {
      case "initialize":
        try await transport.emit(deepSeekInitializationResult(id: id))
      case "session/new":
        try await transport.emit(
          deepSeekSessionResult(
            id: id,
            sessionID: "catalog-session",
            configOptions: deepSeekModelConfigOptions()
          )
        )
      default:
        break
      }
    }
    let fixture = try makeCatalogInstallation()
    addTeardownBlock { try? FileManager.default.removeItem(atPath: fixture.directory) }
    let provider = try DeepSeekHarnessACPProvider(
      configuration: DeepSeekHarnessACPProviderConfiguration(
        runtimeBaseDirectory: URL(fileURLWithPath: fixture.directory)
          .appendingPathComponent("runtime").path,
        transportFactory: { _ in transport }
      )
    )

    let models = try await provider.models(
      installation: fixture.installation,
      projectRoot: nil,
      selectedModelID: "stale-saved-model"
    )

    XCTAssertEqual(models.map(\.id), ["deepseek-v4-pro", "gateway-new"])
    XCTAssertEqual(models[0].supportedReasoningEfforts, ["off", "low", "high", "max"])
    XCTAssertEqual(models[0].defaultReasoningEffort, "max")
    let sent = await transport.sentMessages()
    XCTAssertTrue(sent.contains { $0.method == "session/new" })
    XCTAssertFalse(sent.contains { $0.method == "session/prompt" })
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
    let source = URL(fileURLWithPath: directory).appendingPathComponent("source").path
    let profile = URL(fileURLWithPath: directory).appendingPathComponent("profile").path
    try FileManager.default.createDirectory(atPath: source, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(atPath: profile, withIntermediateDirectories: false)
    let node = URL(fileURLWithPath: source).appendingPathComponent("node").path
    try Data("#!/bin/sh\necho v22.19.0\n".utf8).write(to: URL(fileURLWithPath: node))
    XCTAssertEqual(chmod(node, 0o700), 0)
    let executable = URL(fileURLWithPath: source).appendingPathComponent("dsh-acp-demo").path
    try Data("#!\(node)\n".utf8).write(to: URL(fileURLWithPath: executable))
    XCTAssertEqual(chmod(executable, 0o700), 0)
    let manifest = URL(fileURLWithPath: source).appendingPathComponent("package.json").path
    let manifestData = Data(
      "{\"version\":\"0.1.1-rc.2\",\"packageManager\":\"pnpm@11.7.0\",\"engines\":{\"node\":\"^22.19.0 || >=24.0.0\"}}"
        .utf8
    )
    try manifestData.write(to: URL(fileURLWithPath: manifest))
    let lock = URL(fileURLWithPath: source).appendingPathComponent("pnpm-lock.yaml").path
    let lockData = Data(
      "packages:\n  /@agentclientprotocol/sdk@0.25.1:\n    resolution: {}\n".utf8
    )
    try lockData.write(to: URL(fileURLWithPath: lock))
    let modules = URL(fileURLWithPath: source)
      .appendingPathComponent("node_modules/.pnpm/node_modules").path
    try FileManager.default.createDirectory(atPath: modules, withIntermediateDirectories: true)
    let configuration = URL(fileURLWithPath: profile).appendingPathComponent("cordis.yml").path
    let configurationData = try DeepSeekHarnessACPProfile.bundledConfigurationTemplate()
    try configurationData.write(to: URL(fileURLWithPath: configuration))
    let artifactInputs: [(AgentInstallationArtifactRole, String, Data)] = [
      (.launchConfiguration, configuration, configurationData),
      (.runtimeManifest, manifest, manifestData),
      (.dependencyLock, lock, lockData),
      (.nodeInterpreter, node, Data("#!/bin/sh\necho v22.19.0\n".utf8)),
    ]
    let artifacts = try artifactInputs.map { role, path, data in
      try artifact(role: role, path: path, data: data)
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
