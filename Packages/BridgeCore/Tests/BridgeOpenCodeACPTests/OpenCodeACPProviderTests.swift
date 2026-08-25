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

    let launch = try XCTUnwrap(captured.get())
    XCTAssertFalse(FileManager.default.fileExists(atPath: launch.process.workingDirectory))
    XCTAssertFalse(FileManager.default.fileExists(atPath: launch.runDirectory))
    XCTAssertTrue(launch.process.argv.contains("--pure"))
    XCTAssertTrue(launch.process.argv.contains("acp"))
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
            result: .object(["sessionId": .string("session-provider")])
          )
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
        guard case .completed(_, let stopReason) = envelope.event else { return false }
        return stopReason == "end_turn"
      })

    let launch = try XCTUnwrap(captured.get())
    XCTAssertEqual(launch.process.workingDirectory, projectRoot)
    XCTAssertNil(launch.process.environment["UNRELATED_SETTING"])
    XCTAssertTrue(launch.process.argv[2].contains("(deny file-write*)"))
    XCTAssertTrue(launch.process.argv[2].contains("(deny network*)"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: launch.runDirectory))
  }

  func testRejectsWorkspaceWriteBeforeLaunchingProvider() async throws {
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

    do {
      _ = try await provider.start(
        request,
        installation: try makeInstallation(id: "write-installation")
      )
      XCTFail("Expected workspace writes to be rejected")
    } catch {
      XCTAssertEqual(
        error as? AgentRuntimeError,
        .capabilityUnavailable(.workspaceWriteInPlace)
      )
    }
    XCTAssertNil(captured.get())
    XCTAssertFalse(FileManager.default.fileExists(atPath: runtimeBase))
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
