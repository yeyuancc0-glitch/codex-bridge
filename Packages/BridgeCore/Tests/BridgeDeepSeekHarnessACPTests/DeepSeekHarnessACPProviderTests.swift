import BridgeACP
import BridgeAgentCore
import BridgeDomain
import CryptoKit
import Darwin
import Foundation
import XCTest

@testable import BridgeDeepSeekHarnessACP

final class DeepSeekHarnessACPProviderTests: XCTestCase {
  func testRemoteStartFailureRetainsSanitizedProviderMessage() {
    let error = DeepSeekHarnessACPProvider.runtimeError(
      for: DeepSeekHarnessACPError.remote(
        code: -32_602,
        message: "MCP failed: Authorization: Bearer start-secret token=token-secret"
      )
    )

    guard case .malformedEvent(let detail) = error else {
      return XCTFail("Expected a malformed-event runtime error")
    }
    XCTAssertTrue(detail.contains("deepseek-harness-acp-remote--32602"))
    XCTAssertTrue(detail.contains("MCP failed"))
    XCTAssertFalse(detail.contains("start-secret"))
    XCTAssertFalse(detail.contains("token-secret"))
  }

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

  func testEffectiveCapabilitiesIncludeWritableWorkspaceAndInteractiveApproval() {
    let snapshot = DeepSeekHarnessACPProvider.capabilitySnapshot
    XCTAssertEqual(
      snapshot.effective,
      [
        .sessionCreate, .interrupt, .steer, .steerInterruptAndContinue, .textDelta,
        .toolLifecycle, .workspaceRead,
        .workspaceWriteInPlace, .oneShotApproval, .structuredApprovalPayload, .modelSelection,
        .effortSelection, .shell, .webSearch, .webFetch, .codeExecution, .subagents, .workflow,
        .skills,
      ]
    )
    XCTAssertTrue(snapshot.advertised.contains(.oneShotApproval))
    XCTAssertTrue(snapshot.observed.contains(.oneShotApproval))
    XCTAssertTrue(snapshot.enforced.contains(.oneShotApproval))
    XCTAssertTrue(snapshot.effective.contains(.steer))
    XCTAssertTrue(snapshot.effective.contains(.workspaceWriteInPlace))
    XCTAssertTrue(snapshot.effective.contains(.structuredApprovalPayload))
    XCTAssertTrue(snapshot.effective.contains(.toolLifecycle))
    XCTAssertTrue(snapshot.effective.contains(.webSearch))
    XCTAssertTrue(snapshot.effective.contains(.subagents))
    XCTAssertTrue(snapshot.effective.contains(.codeExecution))
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

  func testRequestValidationRejectsMutationAndUnsupportedOverrides() async throws {
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

    let isolatedRequest = try AgentExecutionRequest(
      taskID: .init(rawValue: "isolated-task"),
      projectID: .init(rawValue: "project"),
      projectRoot: project,
      prompt: "isolated",
      mutationIntent: .workspaceWrite,
      workspaceStrategy: .isolatedGitWorktree,
      networkAccessRequested: false
    )
    do {
      _ = try await provider.start(isolatedRequest, installation: installation)
      XCTFail("Expected isolated workspace strategy rejection")
    } catch let error as AgentRuntimeError {
      XCTAssertEqual(error, .invalidRequest("request.workspaceStrategy"))
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

  func testWorkspaceWriteStartExposesInteractiveApproval() async throws {
    let transport = ScriptedDeepSeekHarnessTransport()
    let promptState = ProviderPromptState()
    await transport.setHandler { message, transport in
      if message.method == "session/prompt", let id = message.id {
        let prompt = try XCTUnwrap(
          message.params?["prompt"]?.arrayValue?.first?["text"]?.stringValue
        )
        XCTAssertEqual(prompt, "write")
        await promptState.set(id)
        try await transport.emit(
          deepSeekPermissionRequest(
            sessionID: "provider-approval-session",
            toolCallID: "provider-tool",
            options: [("allow-once", "allow_once"), ("reject-once", "reject_once")]
          )
        )
        return
      }
      if message.method == nil, message.id == .string("permission-1") {
        guard let promptID = await promptState.value() else { return }
        try await transport.emit(
          deepSeekMessageChunk(
            sessionID: "provider-approval-session",
            text: "approved"
          )
        )
        try await transport.emit(
          deepSeekPromptResult(id: promptID, outcome: "completed")
        )
        return
      }
      guard let id = message.id else { return }
      switch message.method {
      case "initialize":
        try await transport.emit(deepSeekInitializationResult(id: id))
      case "session/new":
        try await transport.emit(
          deepSeekSessionResult(id: id, sessionID: "provider-approval-session")
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
    let request = try AgentExecutionRequest(
      taskID: .init(rawValue: "provider-write-task"),
      projectID: .init(rawValue: "project"),
      projectRoot: FileManager.default.temporaryDirectory.path,
      prompt: "write",
      mutationIntent: .workspaceWrite,
      workspaceStrategy: .exclusiveProject,
      networkAccessRequested: true,
      requiredCapabilities: [
        .workspaceRead, .workspaceWriteInPlace, .steer, .oneShotApproval,
        .structuredApprovalPayload,
      ]
    )

    let handle = try await provider.start(request, installation: fixture.installation)
    XCTAssertNotNil(handle.control.steer)
    var iterator = handle.events.makeAsyncIterator()
    guard let first = try await iterator.next(),
      case .approvalRequested(let approval) = first.event
    else {
      return XCTFail("Expected a provider approval request")
    }
    XCTAssertEqual(approval.providerItemID, "provider-tool")
    XCTAssertTrue(handle.capabilities.effective.contains(.workspaceWriteInPlace))
    XCTAssertTrue(handle.capabilities.effective.contains(.structuredApprovalPayload))
    try await XCTUnwrap(handle.control.resolveApproval)?(
      approval.approvalID,
      "allow-once"
    )

    var events = [first]
    while let event = try await iterator.next() {
      events.append(event)
    }
    XCTAssertTrue(
      events.contains {
        if case .completed = $0.event { return true }
        return false
      }
    )
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

private actor ProviderPromptState {
  private var promptID: ACPRequestID?

  func set(_ id: ACPRequestID) {
    promptID = id
  }

  func value() -> ACPRequestID? {
    promptID
  }
}
