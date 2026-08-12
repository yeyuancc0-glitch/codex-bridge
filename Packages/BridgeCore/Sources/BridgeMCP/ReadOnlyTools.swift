import Foundation
import MCP

public struct MCPToolDeadlines: Sendable {
  public static let production = MCPToolDeadlines(
    bridgeStatus: .seconds(5),
    listProjects: .seconds(5),
    listThreads: .seconds(15),
    readThreadSummary: .seconds(15),
    readThreadFull: .seconds(20),
    listModels: .seconds(10)
  )

  public let bridgeStatus: ContinuousClock.Duration
  public let listProjects: ContinuousClock.Duration
  public let listThreads: ContinuousClock.Duration
  public let readThreadSummary: ContinuousClock.Duration
  public let readThreadFull: ContinuousClock.Duration
  public let listModels: ContinuousClock.Duration

  public init(
    bridgeStatus: ContinuousClock.Duration,
    listProjects: ContinuousClock.Duration,
    listThreads: ContinuousClock.Duration,
    readThreadSummary: ContinuousClock.Duration,
    readThreadFull: ContinuousClock.Duration,
    listModels: ContinuousClock.Duration
  ) {
    let values = [
      bridgeStatus, listProjects, listThreads, readThreadSummary, readThreadFull, listModels,
    ]
    precondition(values.allSatisfy { $0 > .zero })
    self.bridgeStatus = bridgeStatus
    self.listProjects = listProjects
    self.listThreads = listThreads
    self.readThreadSummary = readThreadSummary
    self.readThreadFull = readThreadFull
    self.listModels = listModels
  }
}

public struct ReadOnlyTools: Sendable {
  private let queries: any BridgeMCPQueries
  private let deadlines: MCPToolDeadlines
  private let clock = ContinuousClock()

  public init(
    queries: any BridgeMCPQueries,
    deadlines: MCPToolDeadlines = .production
  ) {
    self.queries = queries
    self.deadlines = deadlines
  }

  public func bridgeStatus(arguments: [String: Value]?) async throws -> BridgeStatusOutput {
    _ = try StrictToolArguments(arguments, allowed: [])
    let deadline = clock.now.advanced(by: deadlines.bridgeStatus)
    let snapshot = try await withToolDeadline(until: deadline) {
      try await queries.statusSnapshot(deadline: deadline)
    }
    guard snapshot.pendingApprovalCount >= 0 else {
      throw MCPToolAdapterError.invalidQueryOutput
    }
    return BridgeStatusOutput(snapshot: snapshot)
  }

  public func listProjects(arguments: [String: Value]?) async throws -> ListProjectsOutput {
    let values = try StrictToolArguments(arguments, allowed: ["cursor", "limit"])
    let cursor = try values.optionalString("cursor", maximumUTF8Bytes: 2_048)
    let limit = try values.limit()
    let deadline = clock.now.advanced(by: deadlines.listProjects)
    let page = try await withToolDeadline(until: deadline) {
      try await queries.listMCPVisibleProjects(
        cursor: cursor,
        limit: limit,
        deadline: deadline
      )
    }
    return ListProjectsOutput(page: page)
  }

  public func listThreads(arguments: [String: Value]?) async throws -> ListThreadsOutput {
    let values = try StrictToolArguments(
      arguments,
      allowed: ["project_id", "cursor", "limit", "search"],
      required: ["project_id"]
    )
    let projectID = try values.requiredIdentifier("project_id", maximumUTF8Bytes: 128)
    let cursor = try values.optionalString("cursor", maximumUTF8Bytes: 2_048)
    let limit = try values.limit()
    let search = try values.optionalString("search", maximumUTF8Bytes: 200)
    let deadline = clock.now.advanced(by: deadlines.listThreads)
    let page = try await withToolDeadline(until: deadline) {
      try await queries.listThreads(
        projectID: projectID,
        cursor: cursor,
        limit: limit,
        search: search,
        deadline: deadline
      )
    }
    return ListThreadsOutput(page: page)
  }

  public func readThread(arguments: [String: Value]?) async throws -> ReadThreadOutput {
    let values = try StrictToolArguments(
      arguments,
      allowed: ["project_id", "thread_id", "detail", "cursor", "limit"],
      required: ["project_id", "thread_id"]
    )
    let detail = try values.threadDetail()
    let duration = detail == .full ? deadlines.readThreadFull : deadlines.readThreadSummary
    let projectID = try values.requiredIdentifier("project_id", maximumUTF8Bytes: 128)
    let threadID = try values.requiredIdentifier("thread_id", maximumUTF8Bytes: 256)
    let cursor = try values.optionalString("cursor", maximumUTF8Bytes: 2_048)
    let limit = try values.limit()
    let deadline = clock.now.advanced(by: duration)
    let page = try await withToolDeadline(until: deadline) {
      try await queries.readThread(
        projectID: projectID,
        threadID: threadID,
        detail: detail,
        cursor: cursor,
        limit: limit,
        deadline: deadline
      )
    }
    return ReadThreadOutput(page: page)
  }

  public func listModels(arguments: [String: Value]?) async throws -> ListModelsOutput {
    _ = try StrictToolArguments(arguments, allowed: [])
    let deadline = clock.now.advanced(by: deadlines.listModels)
    let models = try await withToolDeadline(until: deadline) {
      try await queries.listModels(deadline: deadline)
    }
    return ListModelsOutput(list: models)
  }
}

private func withToolDeadline<Output: Sendable>(
  until deadline: ContinuousClock.Instant,
  operation: @escaping @Sendable () async throws -> Output
) async throws -> Output {
  try await ToolDeadlineRace<Output>().run(until: deadline, operation: operation)
}

private actor ToolDeadlineRace<Output: Sendable> {
  private struct Pending {
    let continuation: CheckedContinuation<Output, any Error>
    let operationTask: Task<Void, Never>
    let timeoutTask: Task<Void, Never>
  }

  private var pending: Pending?

  func run(
    until deadline: ContinuousClock.Instant,
    operation: @escaping @Sendable () async throws -> Output
  ) async throws -> Output {
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        begin(until: deadline, continuation: continuation, operation: operation)
      }
    } onCancel: {
      Task { await self.cancel() }
    }
  }

  private func begin(
    until deadline: ContinuousClock.Instant,
    continuation: CheckedContinuation<Output, any Error>,
    operation: @escaping @Sendable () async throws -> Output
  ) {
    let operationTask = Task {
      do {
        finish(.success(try await operation()))
      } catch {
        finish(.failure(error))
      }
    }
    let timeoutTask = Task {
      do {
        try await ContinuousClock().sleep(until: deadline)
      } catch {
        return
      }
      finish(.failure(BridgeMCPQueryError.timeout))
    }
    pending = Pending(
      continuation: continuation,
      operationTask: operationTask,
      timeoutTask: timeoutTask
    )
  }

  private func finish(_ result: Result<Output, any Error>) {
    guard let pending else { return }
    self.pending = nil
    pending.operationTask.cancel()
    pending.timeoutTask.cancel()
    pending.continuation.resume(with: result)
  }

  private func cancel() {
    finish(.failure(CancellationError()))
  }
}

enum MCPToolAdapterError: Error {
  case invalidQueryOutput
}

private struct StrictToolArguments {
  private let values: [String: Value]

  init(
    _ values: [String: Value]?,
    allowed: Set<String>,
    required: Set<String> = []
  ) throws {
    let values = values ?? [:]
    guard Set(values.keys).isSubset(of: allowed) else {
      throw MCPError.invalidParams("Unknown tool argument.")
    }
    guard required.allSatisfy({ values[$0] != nil && values[$0] != .null }) else {
      throw MCPError.invalidParams("A required tool argument is missing.")
    }
    self.values = values
  }

  func requiredIdentifier(_ key: String, maximumUTF8Bytes: Int) throws -> String {
    guard case .string(let value)? = values[key] else {
      throw MCPError.invalidParams("Argument '\(key)' must be a string.")
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      value == trimmed,
      !value.isEmpty,
      value.utf8.count <= maximumUTF8Bytes,
      value.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw MCPError.invalidParams("Argument '\(key)' is invalid.")
    }
    return value
  }

  func optionalString(_ key: String, maximumUTF8Bytes: Int) throws -> String? {
    guard let rawValue = values[key], rawValue != .null else { return nil }
    guard case .string(let value) = rawValue, value.utf8.count <= maximumUTF8Bytes,
      value.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw MCPError.invalidParams("Argument '\(key)' must be a bounded string.")
    }
    return value
  }

  func limit() throws -> Int {
    guard let value = values["limit"], value != .null else { return 25 }
    guard case .int(let limit) = value, (1...100).contains(limit) else {
      throw MCPError.invalidParams("Argument 'limit' must be an integer from 1 through 100.")
    }
    return limit
  }

  func threadDetail() throws -> MCPThreadDetail {
    guard let value = values["detail"], value != .null else { return .summary }
    guard case .string(let rawValue) = value, let detail = MCPThreadDetail(rawValue: rawValue)
    else {
      throw MCPError.invalidParams("Argument 'detail' must be 'summary' or 'full'.")
    }
    return detail
  }
}
