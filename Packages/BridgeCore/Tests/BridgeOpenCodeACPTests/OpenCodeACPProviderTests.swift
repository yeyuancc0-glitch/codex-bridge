import BridgeAgentCore
import BridgeDomain
import Foundation
import XCTest

@testable import BridgeOpenCodeACP

final class OpenCodeACPProviderTests: XCTestCase {
  func testProbeUsesEphemeralWorkspaceAndReportsObservedCapabilities() async throws {
    let transport = ScriptedACPTransport()
    await transport.setHandler { message, transport in
      guard message.method == "initialize", let id = message.id else { return }
      try await transport.emit(
        ACPWireMessage(
          id: id,
          result: Self.initializationResult()
        )
      )
    }

    let runtimeBase = temporaryPath(prefix: "probe-runtime")
    let sourceHome = try makeTemporaryDirectory(prefix: "probe-home")
    let dataHome = try makeTemporaryDirectory(prefix: "probe-data")
    let captured = LockedValue<OpenCodeACPLaunchConfiguration>()
    addTeardownBlock {
      for path in [runtimeBase, sourceHome, dataHome] {
        try? FileManager.default.removeItem(atPath: path)
      }
    }

    let provider = try OpenCodeACPProvider(
      configuration: OpenCodeACPProviderConfiguration(
        runtimeBaseDirectory: runtimeBase,
        sourceEnvironment: [
          "HOME": sourceHome,
          "XDG_DATA_HOME": dataHome,
        ],
        transportFactory: { launch in
          captured.set(launch)
          return transport
        }
      )
    )
    let installation = try makeInstallation(id: "probe-installation")
    let result = await provider.probe(
      try AgentProbeRequest(installation: installation)
    )

    XCTAssertTrue(result.available)
    XCTAssertEqual(result.installation.version, "1.18.22")
    XCTAssertEqual(result.installation.protocolRevision, "1")
    XCTAssertTrue(result.capabilities.effective.contains(.workspaceRead))
    XCTAssertTrue(result.capabilities.effective.contains(.reasoningDelta))
    XCTAssertTrue(result.capabilities.effective.contains(.plan))
    XCTAssertTrue(result.capabilities.effective.contains(.usage))
    XCTAssertTrue(result.capabilities.effective.contains(.profileSelection))
    XCTAssertTrue(result.capabilities.effective.contains(.workspaceWriteInPlace))
    XCTAssertTrue(result.capabilities.effective.contains(.oneShotApproval))

    let launch = try XCTUnwrap(captured.get())
    XCTAssertFalse(FileManager.default.fileExists(atPath: launch.process.workingDirectory))
    XCTAssertFalse(FileManager.default.fileExists(atPath: launch.runDirectory))
    XCTAssertEqual(
      launch.process.argv,
      [launch.resolvedExecutablePath, "acp", "--cwd", launch.process.workingDirectory]
    )
  }

  func testStartsReadOnlyExecutionAndNormalizesFinalConversation() async throws {
    let transport = ScriptedACPTransport()
    await transport.setHandler { message, transport in
      if message.method == "initialize", let id = message.id {
        try await transport.emit(
          ACPWireMessage(id: id, result: Self.initializationResult())
        )
        return
      }
      if message.method == "session/new", let id = message.id {
        try await transport.emit(
          ACPWireMessage(
            id: id,
            result: Self.sessionResult(
              id: "session-provider",
              models: [("opencode-go/ox-alpha-free", "Ox Alpha Free (Unlimited)")]
            )
          )
        )
        return
      }
      if message.method == "session/set_config_option", let id = message.id {
        try await transport.emit(
          ACPWireMessage(id: id, result: .object(["configOptions": .array([])]))
        )
        return
      }
      if message.method == "session/prompt", let id = message.id {
        try await transport.emit(
          ACPWireMessage(
            method: "session/update",
            params: Self.messageUpdate(text: "Provider response")
          )
        )
        try await transport.emit(
          ACPWireMessage(
            method: "session/update",
            params: Self.planUpdate()
          )
        )
        try await transport.emit(
          ACPWireMessage(
            id: id,
            result: .object(["stopReason": .string("end_turn")])
          )
        )
      }
    }

    let runtimeBase = temporaryPath(prefix: "execution-runtime")
    let projectRoot = try makeTemporaryDirectory(prefix: "execution-project")
    let sourceHome = try makeTemporaryDirectory(prefix: "execution-home")
    let dataHome = try makeTemporaryDirectory(prefix: "execution-data")
    let captured = LockedValue<OpenCodeACPLaunchConfiguration>()
    addTeardownBlock {
      for path in [runtimeBase, projectRoot, sourceHome, dataHome] {
        try? FileManager.default.removeItem(atPath: path)
      }
    }

    let provider = try OpenCodeACPProvider(
      configuration: OpenCodeACPProviderConfiguration(
        runtimeBaseDirectory: runtimeBase,
        sourceEnvironment: [
          "HOME": sourceHome,
          "XDG_DATA_HOME": dataHome,
          "UNRELATED_SETTING": "must-not-cross-provider-boundary",
        ],
        transportFactory: { launch in
          captured.set(launch)
          return transport
        }
      )
    )
    let request = try AgentExecutionRequest(
      taskID: TaskID(rawValue: "task-provider"),
      projectID: ProjectID(rawValue: "project-provider"),
      projectRoot: projectRoot,
      prompt: "Inspect this project without changing it.",
      model: "opencode-go/ox-alpha-free",
      profileID: OpenCodeACPProfiles.controlledReadOnly,
      mutationIntent: .readOnly,
      workspaceStrategy: .sharedProject,
      networkAccessRequested: false,
      requiredCapabilities: [
        .sessionCreate,
        .workspaceRead,
        .profileSelection,
      ]
    )
    let handle = try await provider.start(
      request,
      installation: try makeInstallation(id: "execution-installation")
    )

    var events: [AgentEventEnvelope] = []
    for try await event in handle.events {
      events.append(event)
    }

    XCTAssertEqual(handle.binding.providerID, .openCode)
    XCTAssertEqual(handle.binding.providerSessionID, "session-provider")
    XCTAssertNotNil(handle.binding.providerRunID)
    XCTAssertTrue(handle.capabilities.supports(request.requiredCapabilities))
    XCTAssertEqual(events.map(\.providerSequence), Array(0..<Int64(events.count)))

    let contentUpdates = events.compactMap { envelope -> AgentContentUpdate? in
      guard case .content(let update) = envelope.event else { return nil }
      return update
    }
    XCTAssertEqual(contentUpdates.count, 2)
    XCTAssertEqual(contentUpdates[0].mode, .delta)
    XCTAssertEqual(contentUpdates[0].content, "Provider response")
    XCTAssertEqual(contentUpdates[1].mode, .full)
    XCTAssertEqual(contentUpdates[1].content, "Provider response")
    XCTAssertTrue(contentUpdates[1].isFinal)
    XCTAssertTrue(contentUpdates[1].authoritative)
    XCTAssertTrue(
      events.contains { envelope in
        guard case .plan(let entries) = envelope.event else { return false }
        return entries.map(\.content) == ["Inspect", "Summarize"]
      })
    XCTAssertTrue(
      events.contains { envelope in
        guard case .completed(let summary, let stopReason) = envelope.event else { return false }
        return summary == "Provider response" && stopReason == "end_turn"
      })

    let launch = try XCTUnwrap(captured.get())
    XCTAssertEqual(launch.process.workingDirectory, projectRoot)
    XCTAssertNil(launch.process.environment["UNRELATED_SETTING"])
    XCTAssertEqual(
      launch.process.argv,
      [launch.resolvedExecutablePath, "acp", "--cwd", projectRoot]
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: launch.runDirectory))
    let sent = await transport.sentMessages()
    let configMessages = sent.filter { $0.method == "session/set_config_option" }
    XCTAssertEqual(configMessages.count, 2)
    let modeMessage = try XCTUnwrap(
      configMessages.first { $0.params?["configId"] == .string("mode") }
    )
    XCTAssertEqual(modeMessage.params?["value"], .string("plan"))
    let configIndex = try XCTUnwrap(
      sent.firstIndex { $0.params?["configId"] == .string("mode") }
    )
    let promptIndex = try XCTUnwrap(sent.firstIndex { $0.method == "session/prompt" })
    XCTAssertLessThan(configIndex, promptIndex)
    let modelMessage = try XCTUnwrap(
      configMessages.first { $0.params?["configId"] == .string("model") }
    )
    XCTAssertEqual(modelMessage.params?["value"], .string("opencode-go/ox-alpha-free"))
  }

  func testGoOxAlphaModelIsNotAliasedToZen() async throws {
    let transport = ScriptedACPTransport()
    await transport.setHandler { message, transport in
      guard let id = message.id else { return }
      switch message.method {
      case "initialize":
        try await transport.emit(ACPWireMessage(id: id, result: Self.initializationResult()))
      case "session/new":
        try await transport.emit(
          ACPWireMessage(
            id: id,
            result: Self.sessionResult(
              id: "session-legacy-model",
              models: [("opencode/x-preview-f-free", "OpenCode Zen/Ox Alpha Free")]
            )
          )
        )
      case "session/set_config_option":
        try await transport.emit(ACPWireMessage(id: id, result: .object([:])))
      case "session/prompt":
        try await transport.emit(
          ACPWireMessage(id: id, result: .object(["stopReason": .string("end_turn")]))
        )
      default:
        break
      }
    }
    let runtimeBase = temporaryPath(prefix: "legacy-model-runtime")
    let projectRoot = try makeTemporaryDirectory(prefix: "legacy-model-project")
    let sourceHome = try makeTemporaryDirectory(prefix: "legacy-model-home")
    addTeardownBlock {
      for path in [runtimeBase, projectRoot, sourceHome] {
        try? FileManager.default.removeItem(atPath: path)
      }
    }
    let provider = try OpenCodeACPProvider(
      configuration: OpenCodeACPProviderConfiguration(
        runtimeBaseDirectory: runtimeBase,
        sourceEnvironment: ["HOME": sourceHome],
        transportFactory: { _ in transport }
      )
    )
    let request = try AgentExecutionRequest(
      taskID: TaskID(rawValue: "task-legacy-model"),
      projectID: ProjectID(rawValue: "project-legacy-model"),
      projectRoot: projectRoot,
      prompt: "Reply with OK.",
      model: "opencode-go/ox-alpha-free",
      mutationIntent: .readOnly,
      workspaceStrategy: .sharedProject,
      networkAccessRequested: false
    )

    do {
      _ = try await provider.start(
        request,
        installation: try makeInstallation(id: "legacy-model-installation")
      )
      XCTFail("Expected the unavailable Go model to be rejected instead of routed to Zen")
    } catch {
      XCTAssertEqual(error as? AgentRuntimeError, .modelUnavailable("opencode-go/ox-alpha-free"))
    }

    let sent = await transport.sentMessages()
    XCTAssertFalse(
      sent.contains {
        $0.method == "session/set_config_option"
          && $0.params?["configId"] == .string("model")
      }
    )
  }

  func testModelsComeFromSessionConfiguration() async throws {
    let transport = ScriptedACPTransport()
    await transport.setHandler { message, transport in
      guard let id = message.id else { return }
      switch message.method {
      case "initialize":
        try await transport.emit(ACPWireMessage(id: id, result: Self.initializationResult()))
      case "session/new":
        try await transport.emit(
          ACPWireMessage(
            id: id,
            result: Self.sessionResult(
              id: "session-model-list",
              models: [
                ("opencode/x-preview-f-free", "OpenCode Zen/Ox Alpha Free"),
                ("opencode/big-pickle", "Big Pickle"),
                ("opencode-go/ox-alpha-free", "Ox Alpha Free (Unlimited)"),
              ]
            )
          )
        )
      case "session/set_config_option":
        let result =
          Self.sessionResult(
            id: "session-model-list",
            models: [
              ("opencode/x-preview-f-free", "OpenCode Zen/Ox Alpha Free"),
              ("opencode/big-pickle", "Big Pickle"),
              ("opencode-go/ox-alpha-free", "Ox Alpha Free (Unlimited)"),
            ]
          )["configOptions"] ?? .array([])
        try await transport.emit(
          ACPWireMessage(id: id, result: .object(["configOptions": result]))
        )
      default:
        break
      }
    }
    let runtimeBase = temporaryPath(prefix: "model-list-runtime")
    let sourceHome = try makeTemporaryDirectory(prefix: "model-list-home")
    addTeardownBlock {
      for path in [runtimeBase, sourceHome] {
        try? FileManager.default.removeItem(atPath: path)
      }
    }
    let provider = try OpenCodeACPProvider(
      configuration: OpenCodeACPProviderConfiguration(
        runtimeBaseDirectory: runtimeBase,
        sourceEnvironment: ["HOME": sourceHome],
        transportFactory: { _ in transport }
      )
    )

    let models = try await provider.models(
      installation: makeInstallation(id: "model-list-installation"),
      projectRoot: nil
    )

    XCTAssertEqual(
      models.map(\.id),
      ["opencode/x-preview-f-free", "opencode/big-pickle", "opencode-go/ox-alpha-free"]
    )
    XCTAssertEqual(models.first?.displayName, "OpenCode Zen/Ox Alpha Free")
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: runtimeBase).isEmpty)
  }

  func testModelsExposeDynamicEffortForProviderDefaultModel() async throws {
    let transport = ScriptedACPTransport()
    let sourceHome = try makeTemporaryDirectory(prefix: "default-effort-home")
    addTeardownBlock { try? FileManager.default.removeItem(atPath: sourceHome) }
    await transport.setHandler { message, transport in
      guard let id = message.id else { return }
      switch message.method {
      case "initialize":
        try await transport.emit(ACPWireMessage(id: id, result: Self.initializationResult()))
      case "session/new":
        try await transport.emit(
          ACPWireMessage(
            id: id,
            result: Self.sessionResult(
              id: "session-default-effort",
              models: [("openai/gpt-5.6-sol", "GPT-5.6 Sol")]
            )
          )
        )
      case "session/set_config_option":
        let result =
          Self.sessionResultWithEffort(
            id: "session-default-effort",
            models: [("openai/gpt-5.6-sol", "GPT-5.6 Sol")]
          )["configOptions"] ?? .array([])
        try await transport.emit(
          ACPWireMessage(id: id, result: .object(["configOptions": result]))
        )
      default:
        break
      }
    }
    let provider = try OpenCodeACPProvider(
      configuration: OpenCodeACPProviderConfiguration(
        sourceEnvironment: ["HOME": sourceHome],
        transportFactory: { _ in transport }
      )
    )

    let models = try await provider.models(
      installation: makeInstallation(id: "default-effort-installation"),
      projectRoot: nil
    )

    XCTAssertEqual(models.first?.supportedReasoningEfforts, ["low", "high"])
    XCTAssertEqual(models.first?.defaultReasoningEffort, "high")
  }

  func testAppliesDynamicEffortForProviderDefaultModel() async throws {
    let transport = ScriptedACPTransport()
    let captured = LockedValue<OpenCodeACPLaunchConfiguration>()
    let projectRoot = try makeTemporaryDirectory(prefix: "effort-project")
    let sourceHome = try makeTemporaryDirectory(prefix: "effort-home")
    addTeardownBlock {
      for path in [projectRoot, sourceHome] {
        try? FileManager.default.removeItem(atPath: path)
      }
    }
    await transport.setHandler { message, transport in
      guard let id = message.id else { return }
      switch message.method {
      case "initialize":
        try await transport.emit(ACPWireMessage(id: id, result: Self.initializationResult()))
      case "session/new":
        try await transport.emit(
          ACPWireMessage(
            id: id,
            result: Self.sessionResult(
              id: "session-effort",
              models: [("openai/gpt-5.6-sol", "GPT-5.6 Sol")]
            )
          )
        )
      case "session/set_config_option":
        let configID = message.params?["configId"]?.stringValue
        let result =
          configID == "model"
          ? Self.sessionResultWithEffort(
            id: "session-effort",
            models: [("openai/gpt-5.6-sol", "GPT-5.6 Sol")]
          )["configOptions"] ?? .array([])
          : .array([])
        try await transport.emit(
          ACPWireMessage(
            id: id,
            result: .object(["configOptions": result])
          )
        )
      case "session/prompt":
        try await transport.emit(
          ACPWireMessage(id: id, result: .object(["stopReason": .string("end_turn")]))
        )
      default:
        break
      }
    }
    let provider = try OpenCodeACPProvider(
      configuration: OpenCodeACPProviderConfiguration(
        sourceEnvironment: ["HOME": sourceHome],
        transportFactory: { launch in
          captured.set(launch)
          return transport
        }
      )
    )
    let request = try AgentExecutionRequest(
      taskID: TaskID(rawValue: "task-effort-rejected"),
      projectID: ProjectID(rawValue: "project-effort-rejected"),
      projectRoot: projectRoot,
      prompt: "Inspect.",
      effort: "high",
      mutationIntent: .readOnly,
      workspaceStrategy: .sharedProject,
      networkAccessRequested: false
    )

    let handle = try await provider.start(
      request,
      installation: makeInstallation(id: "effort-installation")
    )
    for try await _ in handle.events {}
    XCTAssertTrue(handle.capabilities.effective.contains(.effortSelection))
    let sent = await transport.sentMessages()
    let effortMessage = try XCTUnwrap(
      sent.first {
        $0.method == "session/set_config_option" && $0.params?["configId"] == .string("effort")
      }
    )
    XCTAssertEqual(effortMessage.params?["value"], .string("high"))
    XCTAssertNotNil(captured.get())
  }

  func testStartsWorkspaceWriteWithNativeBuildMode() async throws {
    let transport = ScriptedACPTransport()
    let captured = LockedValue<OpenCodeACPLaunchConfiguration>()
    let runtimeBase = temporaryPath(prefix: "rejected-runtime")
    let projectRoot = try makeTemporaryDirectory(prefix: "rejected-project")
    let sourceHome = try makeTemporaryDirectory(prefix: "rejected-home")
    addTeardownBlock {
      for path in [runtimeBase, projectRoot, sourceHome] {
        try? FileManager.default.removeItem(atPath: path)
      }
    }

    await transport.setHandler { message, transport in
      guard let id = message.id else { return }
      switch message.method {
      case "initialize":
        try await transport.emit(ACPWireMessage(id: id, result: Self.initializationResult()))
      case "session/new":
        try await transport.emit(
          ACPWireMessage(
            id: id,
            result: Self.sessionResult(id: "session-write", models: [])
          )
        )
      case "session/set_config_option":
        try await transport.emit(ACPWireMessage(id: id, result: .object([:])))
      case "session/prompt":
        try await transport.emit(
          ACPWireMessage(id: id, result: .object(["stopReason": .string("end_turn")]))
        )
      default:
        break
      }
    }

    let provider = try OpenCodeACPProvider(
      configuration: OpenCodeACPProviderConfiguration(
        runtimeBaseDirectory: runtimeBase,
        sourceEnvironment: ["HOME": sourceHome],
        transportFactory: { launch in
          captured.set(launch)
          return transport
        }
      )
    )
    let request = try AgentExecutionRequest(
      taskID: TaskID(rawValue: "task-write-rejected"),
      projectID: ProjectID(rawValue: "project-write-rejected"),
      projectRoot: projectRoot,
      prompt: "Modify the project.",
      mutationIntent: .workspaceWrite,
      workspaceStrategy: .exclusiveProject,
      networkAccessRequested: false
    )

    let handle = try await provider.start(
      request,
      installation: try makeInstallation(id: "write-installation")
    )
    for try await _ in handle.events {}
    let launch = try XCTUnwrap(captured.get())
    XCTAssertEqual(
      launch.process.argv,
      [launch.resolvedExecutablePath, "acp", "--cwd", projectRoot]
    )
    let sent = await transport.sentMessages()
    let modeMessage = try XCTUnwrap(
      sent.first {
        $0.method == "session/set_config_option"
          && $0.params?["configId"] == .string("mode")
      }
    )
    XCTAssertEqual(modeMessage.params?["value"], .string("build"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: launch.runDirectory))
  }

  func testInactivityTimeoutFailsRunAndCleansRuntime() async throws {
    let transport = ScriptedACPTransport()
    await transport.setHandler { message, transport in
      if message.method == "initialize", let id = message.id {
        try await transport.emit(
          ACPWireMessage(id: id, result: Self.initializationResult())
        )
        return
      }
      if message.method == "session/new", let id = message.id {
        try await transport.emit(
          ACPWireMessage(
            id: id,
            result: Self.sessionResult(id: "session-timeout", models: [])
          )
        )
        return
      }
      if message.method == "session/set_config_option", let id = message.id {
        try await transport.emit(ACPWireMessage(id: id, result: .object([:])))
      }
    }

    let runtimeBase = temporaryPath(prefix: "timeout-runtime")
    let projectRoot = try makeTemporaryDirectory(prefix: "timeout-project")
    let sourceHome = try makeTemporaryDirectory(prefix: "timeout-home")
    let captured = LockedValue<OpenCodeACPLaunchConfiguration>()
    addTeardownBlock {
      for path in [runtimeBase, projectRoot, sourceHome] {
        try? FileManager.default.removeItem(atPath: path)
      }
    }
    let provider = try OpenCodeACPProvider(
      configuration: OpenCodeACPProviderConfiguration(
        inactivityTimeout: .milliseconds(50),
        runtimeBaseDirectory: runtimeBase,
        sourceEnvironment: ["HOME": sourceHome],
        transportFactory: { launch in
          captured.set(launch)
          return transport
        }
      )
    )
    let request = try AgentExecutionRequest(
      taskID: TaskID(rawValue: "task-timeout"),
      projectID: ProjectID(rawValue: "project-timeout"),
      projectRoot: projectRoot,
      prompt: "Inspect without producing events.",
      mutationIntent: .readOnly,
      workspaceStrategy: .sharedProject,
      networkAccessRequested: false
    )

    let handle = try await provider.start(
      request,
      installation: try makeInstallation(id: "timeout-installation")
    )
    var events: [AgentEventEnvelope] = []
    for try await event in handle.events {
      events.append(event)
    }

    XCTAssertTrue(
      events.contains { envelope in
        guard case .failed(let code, _) = envelope.event else { return false }
        return code == "opencode_inactivity_timeout"
      }
    )
    let launch = try XCTUnwrap(captured.get())
    XCTAssertFalse(FileManager.default.fileExists(atPath: launch.runDirectory))
    let sent = await transport.sentMessages()
    XCTAssertTrue(sent.contains { $0.method == "session/cancel" })
  }

  func testProbeRejectsIncompatibleVersionAndCleansRuntime() async throws {
    let transport = ScriptedACPTransport()
    await transport.setHandler { message, transport in
      guard message.method == "initialize", let id = message.id else { return }
      var value = Self.initializationResult().objectValue ?? [:]
      value["agentInfo"] = .object([
        "name": .string("OpenCode"),
        "title": .string("OpenCode"),
        "version": .string("1.19.0"),
      ])
      try await transport.emit(
        ACPWireMessage(id: id, result: .object(value))
      )
    }

    let runtimeBase = temporaryPath(prefix: "version-runtime")
    let sourceHome = try makeTemporaryDirectory(prefix: "version-home")
    let captured = LockedValue<OpenCodeACPLaunchConfiguration>()
    addTeardownBlock {
      try? FileManager.default.removeItem(atPath: runtimeBase)
      try? FileManager.default.removeItem(atPath: sourceHome)
    }

    let provider = try OpenCodeACPProvider(
      configuration: OpenCodeACPProviderConfiguration(
        runtimeBaseDirectory: runtimeBase,
        sourceEnvironment: ["HOME": sourceHome],
        transportFactory: { launch in
          captured.set(launch)
          return transport
        }
      )
    )
    let result = await provider.probe(
      try AgentProbeRequest(
        installation: makeInstallation(id: "version-installation")
      )
    )

    XCTAssertFalse(result.available)
    XCTAssertTrue(result.unavailableReason?.contains("incompatible") == true)
    let launch = try XCTUnwrap(captured.get())
    XCTAssertFalse(FileManager.default.fileExists(atPath: launch.process.workingDirectory))
    XCTAssertFalse(FileManager.default.fileExists(atPath: launch.runDirectory))
  }

  func testRuntimeBaseIsPrivateAndOnlyKeepsTheBaseDirectory() async throws {
    let transport = ScriptedACPTransport()
    await transport.setHandler { message, transport in
      guard message.method == "initialize", let id = message.id else { return }
      try await transport.emit(
        ACPWireMessage(id: id, result: Self.initializationResult())
      )
    }

    let runtimeBase = try makeTemporaryDirectory(prefix: "private-runtime")
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: runtimeBase
    )
    let sourceHome = try makeTemporaryDirectory(prefix: "private-home")
    addTeardownBlock {
      try? FileManager.default.removeItem(atPath: runtimeBase)
      try? FileManager.default.removeItem(atPath: sourceHome)
    }

    let provider = try OpenCodeACPProvider(
      configuration: OpenCodeACPProviderConfiguration(
        runtimeBaseDirectory: runtimeBase,
        sourceEnvironment: ["HOME": sourceHome],
        transportFactory: { _ in transport }
      )
    )
    let result = await provider.probe(
      try AgentProbeRequest(
        installation: makeInstallation(id: "private-runtime-installation")
      )
    )

    XCTAssertTrue(result.available)
    XCTAssertEqual(try permissions(of: runtimeBase), 0o700)
    XCTAssertTrue(
      try FileManager.default.contentsOfDirectory(atPath: runtimeBase).isEmpty
    )
  }

  private static func initializationResult() -> ACPJSONValue {
    .object([
      "protocolVersion": .integer(1),
      "agentCapabilities": .object([
        "loadSession": .bool(true),
        "sessionCapabilities": .object([
          "resume": .object([:]),
          "close": .object([:]),
        ]),
      ]),
      "agentInfo": .object([
        "name": .string("OpenCode"),
        "title": .string("OpenCode"),
        "version": .string("1.18.22"),
      ]),
    ])
  }

  private static func sessionResult(
    id: String,
    models: [(String, String)]
  ) -> ACPJSONValue {
    var modelOption: [String: ACPJSONValue] = [
      "id": .string("model"),
      "name": .string("Model"),
      "type": .string("select"),
      "options": .array(
        models.map { model in
          .object([
            "value": .string(model.0),
            "name": .string(model.1),
          ])
        }
      ),
    ]
    if let firstModel = models.first {
      modelOption["currentValue"] = .string(firstModel.0)
    }
    return .object([
      "sessionId": .string(id),
      "configOptions": .array([
        .object(modelOption),
        .object([
          "id": .string("mode"),
          "name": .string("Mode"),
          "type": .string("select"),
          "currentValue": .string("plan"),
          "options": .array([
            .object([
              "value": .string("plan"),
              "name": .string("Plan"),
            ]),
            .object([
              "value": .string("build"),
              "name": .string("Build"),
            ]),
          ]),
        ]),
      ]),
    ])
  }

  private static func sessionResultWithEffort(
    id: String,
    models: [(String, String)]
  ) -> ACPJSONValue {
    guard var object = sessionResult(id: id, models: models).objectValue,
      var options = object["configOptions"]?.arrayValue,
      var model = options.first?.objectValue
    else {
      return .object([:])
    }
    model["currentValue"] = .string("openai/gpt-5.6-sol")
    model["options"] = .array([
      .object(["value": .string("openai/gpt-5.6-sol"), "name": .string("GPT-5.6 Sol")])
    ])
    options[0] = .object(model)
    options.append(
      .object([
        "id": .string("effort"),
        "name": .string("Effort"),
        "type": .string("select"),
        "currentValue": .string("high"),
        "options": .array([
          .object(["value": .string("low"), "name": .string("Low")]),
          .object(["value": .string("high"), "name": .string("High")]),
        ]),
      ])
    )
    object["configOptions"] = .array(options)
    return .object(object)
  }

  private static func messageUpdate(text: String) -> ACPJSONValue {
    .object([
      "sessionId": .string("session-provider"),
      "update": .object([
        "sessionUpdate": .string("agent_message_chunk"),
        "messageId": .string("provider-message"),
        "content": .object([
          "type": .string("text"),
          "text": .string(text),
        ]),
      ]),
    ])
  }

  private static func planUpdate() -> ACPJSONValue {
    .object([
      "sessionId": .string("session-provider"),
      "update": .object([
        "sessionUpdate": .string("plan"),
        "entries": .array([
          .object([
            "content": .string("Inspect"),
            "priority": .string("high"),
            "status": .string("completed"),
          ]),
          .object([
            "content": .string("Summarize"),
            "priority": .string("medium"),
            "status": .string("in_progress"),
          ]),
        ]),
      ]),
    ])
  }

  private func makeInstallation(id: String) throws -> AgentInstallation {
    try AgentInstallation(
      id: AgentInstallationID(rawValue: id),
      providerID: .openCode,
      executablePath: "/bin/echo"
    )
  }

  private func makeTemporaryDirectory(prefix: String) throws -> String {
    let path = temporaryPath(prefix: prefix)
    try FileManager.default.createDirectory(
      atPath: path,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    return path
  }

  private func temporaryPath(prefix: String) -> String {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true).path
  }

  private func permissions(of path: String) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    return try XCTUnwrap((attributes[.posixPermissions] as? NSNumber)?.intValue)
  }
}
