import BridgeCodexRPC
import Foundation

@main
struct CodexRPCFixture {
  private enum Scenario: String {
    case basic
    case steer
    case interrupt
    case supervisor
  }

  static func main() async {
    do {
      try await run()
    } catch {
      FileHandle.standardError.write(Data("fixture failed: \(error)\n".utf8))
      Foundation.exit(1)
    }
  }

  private static func run() async throws {
    let arguments = CommandLine.arguments
    guard arguments.count == 2, let scenario = Scenario(rawValue: arguments[1]) else {
      throw FixtureError.usage
    }
    let fixtureURL = try makeFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: fixtureURL) }

    let client = CodexAppServerClient(defaultTimeoutNanoseconds: 30_000_000_000)
    do {
      try await client.start()
      _ = try await client.initialize(clientInfo: .bridge(version: "0.1.0-dev"))

      let models = try await client.listModels()
      let model = try chooseModel(models, scenario: scenario)
      let thread = try await client.startThread(
        ThreadStartParams(
          cwd: fixtureURL.path,
          sandbox: .readOnly,
          approvalPolicy: .never,
          ephemeral: true,
          model: model.id,
          developerInstructions: "This is an isolated read-only protocol fixture. Do not use tools."
        )
      )
      guard thread.thread.cwd == fixtureURL.path, thread.cwd == fixtureURL.path else {
        throw FixtureError.cwdMismatch
      }

      let outcome = try await runScenario(
        scenario,
        client: client,
        threadID: thread.thread.id,
        model: model
      )
      try validate(outcome, scenario: scenario)

      let summary: [String: Any] = [
        "scenario": scenario.rawValue,
        "model": model.id,
        "effort": model.effort,
        "threadId": thread.thread.id,
        "turnId": outcome.turnID,
        "status": outcome.status,
        "response": outcome.response,
        "cwdMatches": true,
      ]
      await client.stop()
      let data = try JSONSerialization.data(
        withJSONObject: summary,
        options: [.prettyPrinted, .sortedKeys]
      )
      FileHandle.standardOutput.write(data)
      FileHandle.standardOutput.write(Data("\n".utf8))
    } catch {
      await client.stop()
      throw error
    }
  }

  private static func chooseModel(
    _ response: ModelListResponse,
    scenario: Scenario
  ) throws -> (id: String, effort: String) {
    let model =
      scenario == .supervisor
      ? response.data.first(where: { $0.id.lowercased().contains("luna") })
      : response.data.first(where: { $0.isDefault }) ?? response.data.first
    guard let model,
      let effort = model.supportedReasoningEfforts.first?.reasoningEffort
    else {
      throw FixtureError.noModel
    }
    return (model.id, effort)
  }

  private static func runScenario(
    _ scenario: Scenario,
    client: CodexAppServerClient,
    threadID: String,
    model: (id: String, effort: String)
  ) async throws -> (turnID: String, status: String, response: String) {
    let prompt: String
    let outputSchema: JSONValue?
    switch scenario {
    case .basic:
      prompt = "Reply with exactly READY and do not use tools."
      outputSchema = nil
    case .steer:
      prompt = "Write a detailed 2000-word essay about protocol design. Do not use tools."
      outputSchema = nil
    case .interrupt:
      prompt = "Write a detailed 4000-word essay about software architecture. Do not use tools."
      outputSchema = nil
    case .supervisor:
      prompt = """
        Evaluate this synthetic read-only checkpoint. Goal: reply READY. Observed: READY.
        Return a JSON object with decision pass, steer, or pause, plus a short reason.
        """
      outputSchema = supervisorSchema
    }

    let events = FixtureEventCursor()
    await events.start(stream: client.events)
    let turn = try await client.startTurn(
      TurnStartParams(
        threadId: threadID,
        text: prompt,
        sandboxPolicy: .readOnly(),
        approvalPolicy: .never,
        model: model.id,
        effort: model.effort,
        outputSchema: outputSchema
      )
    )

    if scenario == .steer || scenario == .interrupt {
      try await waitForTurnStarted(
        events: events,
        threadID: threadID,
        turnID: turn.turn.id
      )
    }
    if scenario == .steer {
      _ = try await client.steerTurn(
        TurnSteerParams(
          threadId: threadID,
          expectedTurnId: turn.turn.id,
          text: "Replace the prior request. Reply with exactly STEERED and do not use tools."
        )
      )
    }
    if scenario == .interrupt {
      _ = try await client.interruptTurn(
        TurnInterruptParams(threadId: threadID, turnId: turn.turn.id)
      )
    }

    let completed = try await waitForTurn(
      events: events,
      threadID: threadID,
      turnID: turn.turn.id
    )
    let response = agentMessage(in: completed.turn)
    if scenario == .supervisor {
      guard let data = response.data(using: .utf8),
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let decision = object["decision"] as? String,
        ["pass", "steer", "pause"].contains(decision)
      else {
        throw FixtureError.invalidSupervisorOutput
      }
    }
    return (turn.turn.id, completed.turn.status, response)
  }

  private static let supervisorSchema: JSONValue = .object([
    "type": .string("object"),
    "additionalProperties": .bool(false),
    "required": .array([.string("decision"), .string("reason")]),
    "properties": .object([
      "decision": .object([
        "type": .string("string"),
        "enum": .array([.string("pass"), .string("steer"), .string("pause")]),
      ]),
      "reason": .object(["type": .string("string")]),
    ]),
  ])

  private static func waitForTurn(
    events: FixtureEventCursor,
    threadID: String,
    turnID: String
  ) async throws -> TurnNotification {
    try await withTimeout(timeoutNanoseconds: 180_000_000_000) {
      while let event = try await events.next() {
        guard case .notification(let notification) = event else {
          throw FixtureError.unexpectedServerRequest
        }
        guard case .turnCompleted(let completed) = try notification.decodedCodexNotification()
        else {
          continue
        }
        guard completed.threadId == threadID, completed.turn.id == turnID else {
          continue
        }
        return completed
      }
      throw FixtureError.connectionClosed
    }
  }

  private static func waitForTurnStarted(
    events: FixtureEventCursor,
    threadID: String,
    turnID: String
  ) async throws {
    try await withTimeout(timeoutNanoseconds: 30_000_000_000) {
      while let event = try await events.next() {
        guard case .notification(let notification) = event else {
          throw FixtureError.unexpectedServerRequest
        }
        guard case .turnStarted(let started) = try notification.decodedCodexNotification()
        else {
          continue
        }
        guard started.threadId == threadID, started.turn.id == turnID else {
          continue
        }
        return
      }
      throw FixtureError.connectionClosed
    }
  }

  private static func agentMessage(in turn: CodexTurn) -> String {
    for item in turn.items.reversed() {
      guard let object = item.objectValue,
        object["type"]?.stringValue == "agentMessage",
        let text = object["text"]?.stringValue
      else {
        continue
      }
      return text
    }
    return ""
  }

  private static func makeFixtureDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
      path: "codex-bridge-live-fixture-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url.standardizedFileURL.resolvingSymlinksInPath()
  }

  private static func validate(
    _ outcome: (turnID: String, status: String, response: String),
    scenario: Scenario
  ) throws {
    switch scenario {
    case .basic:
      guard outcome.status == "completed", outcome.response == "READY" else {
        throw FixtureError.unexpectedOutcome
      }
    case .steer:
      guard outcome.status == "completed", outcome.response == "STEERED" else {
        throw FixtureError.unexpectedOutcome
      }
    case .interrupt:
      guard outcome.status == "interrupted" else { throw FixtureError.unexpectedOutcome }
    case .supervisor:
      guard outcome.status == "completed" else { throw FixtureError.unexpectedOutcome }
    }
  }

  private static func withTimeout<T: Sendable>(
    timeoutNanoseconds: UInt64,
    _ operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask { try await operation() }
      group.addTask {
        try await Task.sleep(nanoseconds: timeoutNanoseconds)
        throw FixtureError.timeout
      }
      guard let result = try await group.next() else {
        throw FixtureError.connectionClosed
      }
      group.cancelAll()
      return result
    }
  }
}

private actor FixtureEventCursor {
  private struct Waiter {
    let id: UUID
    let continuation: CheckedContinuation<AppServerEvent?, any Error>
  }

  private var buffered: [AppServerEvent] = []
  private var waiter: Waiter?
  private var finished = false
  private var terminalError: (any Error)?

  func start(stream: AsyncStream<AppServerEvent>) {
    Task {
      for await event in stream {
        receive(event)
      }
      finish()
    }
  }

  func next() async throws -> AppServerEvent? {
    let id = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        beginNext(id: id, continuation: continuation)
      }
    } onCancel: {
      Task { await self.cancel(id: id) }
    }
  }

  private func beginNext(
    id: UUID,
    continuation: CheckedContinuation<AppServerEvent?, any Error>
  ) {
    if !buffered.isEmpty {
      continuation.resume(returning: buffered.removeFirst())
    } else if finished {
      if let terminalError {
        continuation.resume(throwing: terminalError)
      } else {
        continuation.resume(returning: nil)
      }
    } else {
      waiter = Waiter(id: id, continuation: continuation)
    }
  }

  private func receive(_ event: AppServerEvent) {
    guard !finished else { return }
    if let waiter {
      self.waiter = nil
      waiter.continuation.resume(returning: event)
    } else if buffered.count < 256 {
      buffered.append(event)
    } else {
      finish(error: FixtureError.eventOverflow)
    }
  }

  private func finish(error: (any Error)? = nil) {
    guard !finished else { return }
    finished = true
    terminalError = error
    if error != nil {
      buffered.removeAll(keepingCapacity: false)
    }
    if let waiter {
      self.waiter = nil
      if let error {
        waiter.continuation.resume(throwing: error)
      } else {
        waiter.continuation.resume(returning: nil)
      }
    }
  }

  private func cancel(id: UUID) {
    guard waiter?.id == id else { return }
    let continuation = waiter?.continuation
    waiter = nil
    continuation?.resume(throwing: CancellationError())
  }
}

private enum FixtureError: Error {
  case usage
  case noModel
  case cwdMismatch
  case unexpectedServerRequest
  case connectionClosed
  case invalidSupervisorOutput
  case unexpectedOutcome
  case timeout
  case eventOverflow
}
