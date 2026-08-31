import BridgeAgentCore
import BridgeCodexRPC
import BridgeMCP
import BridgeSecurity
import Foundation

public struct ServiceCodexCatalogConfiguration: Sendable {
  public let appServer: AppServerConfiguration
  public let clientInfo: CodexClientInfo
  public let requestTimeoutNanoseconds: UInt64
  public let eventBufferLimit: Int
  public let modelsCacheTTL: Duration

  public init(
    appServer: AppServerConfiguration = .codex(),
    clientInfo: CodexClientInfo,
    requestTimeoutNanoseconds: UInt64 = 20_000_000_000,
    eventBufferLimit: Int = 64,
    modelsCacheTTL: Duration = .seconds(300)
  ) {
    self.appServer = appServer
    self.clientInfo = clientInfo
    self.requestTimeoutNanoseconds = max(1, requestTimeoutNanoseconds)
    self.eventBufferLimit = max(1, eventBufferLimit)
    self.modelsCacheTTL = modelsCacheTTL
  }
}

public actor ServiceCodexCatalog {
  private struct ModelCacheEntry {
    let models: MCPModelList
    let fetchedAt: ContinuousClock.Instant
  }

  private struct InFlightModels {
    let generation: UInt64
    let task: Task<MCPModelList, any Error>
  }

  private let configuration: ServiceCodexCatalogConfiguration
  private let clock = ContinuousClock()
  private var modelCache: ModelCacheEntry?
  private var inFlightModels: InFlightModels?
  private var modelsFetchGeneration: UInt64 = 0

  public init(configuration: ServiceCodexCatalogConfiguration) {
    self.configuration = configuration
  }

  public func listThreads(
    root: String,
    cursor: String?,
    limit: Int,
    search: String?,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPThreadPage {
    guard AgentPathSemantics.isAbsolute(root), (1...100).contains(limit) else {
      throw BridgeMCPQueryError.contractRejected
    }
    return try await withClient(deadline: deadline) { client in
      let response = try await client.listThreads(
        ThreadListParams(
          cursor: cursor,
          limit: UInt32(limit),
          sortKey: "updated_at",
          sortDirection: "desc",
          archived: false,
          cwd: .anyOf([root]),
          searchTerm: search,
          useStateDbOnly: true
        )
      )
      let threads = try response.data.map { thread -> MCPThreadSummary in
        guard Self.samePath(thread.cwd, root) else { throw BridgeMCPQueryError.threadNotFound }
        return try Self.summary(thread)
      }
      return MCPThreadPage(threads: threads, nextCursor: response.nextCursor)
    }
  }

  public func listThreads(
    root: String,
    cursor: String?,
    limit: Int,
    search: String?,
    including allowedThreadIDs: Set<String>,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPThreadPage {
    guard AgentPathSemantics.isAbsolute(root), (1...100).contains(limit) else {
      throw BridgeMCPQueryError.contractRejected
    }
    let offset = try Self.decodeAppCursor(cursor)
    guard !allowedThreadIDs.isEmpty else {
      return MCPThreadPage(threads: [], nextCursor: nil)
    }

    var catalogCursor: String?
    var matching: [MCPThreadSummary] = []
    for _ in 0..<32 {
      try Self.checkDeadline(deadline)
      let page = try await listThreads(
        root: root,
        cursor: catalogCursor,
        limit: 100,
        search: search,
        deadline: deadline
      )
      matching.append(contentsOf: page.threads.filter { allowedThreadIDs.contains($0.threadID) })
      if matching.count > offset + limit || page.nextCursor == nil {
        let end = min(offset + limit, matching.count)
        guard offset <= end else { throw BridgeMCPQueryError.contractRejected }
        let next = end < matching.count ? "app.v1.\(end)" : nil
        return MCPThreadPage(threads: Array(matching[offset..<end]), nextCursor: next)
      }
      guard page.nextCursor != catalogCursor else { throw BridgeMCPQueryError.unavailable }
      catalogCursor = page.nextCursor
    }
    throw BridgeMCPQueryError.unavailable
  }

  public func readThread(
    root: String,
    threadID: String,
    detail: MCPThreadDetail,
    cursor: String?,
    limit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPThreadReadPage {
    guard AgentPathSemantics.isAbsolute(root),
      Self.validIdentifier(threadID, maximum: 1_024), (1...100).contains(limit)
    else {
      throw BridgeMCPQueryError.contractRejected
    }
    return try await withClient(deadline: deadline) { client in
      let response: ThreadReadResponse
      do {
        response = try await client.readThread(
          ThreadReadParams(threadId: threadID, includeTurns: detail == .full)
        )
      } catch let error as CodexRPCError {
        throw Self.publicThreadReadError(error)
      }
      guard response.thread.id == threadID, Self.samePath(response.thread.cwd, root) else {
        throw BridgeMCPQueryError.threadNotFound
      }
      let summary = try Self.summary(response.thread)
      guard detail == .full else {
        guard cursor == nil else { throw BridgeMCPQueryError.contractRejected }
        return MCPThreadReadPage(thread: summary, detail: detail, entries: [])
      }
      let entries = try response.thread.turns.flatMap(Self.entries)
      let offset = try Self.decodeCursor(cursor, maximum: entries.count)
      let end = min(offset + limit, entries.count)
      let page = Array(entries[offset..<end])
      let next = end < entries.count ? "v1.\(end)" : nil
      return MCPThreadReadPage(
        thread: summary,
        detail: detail,
        entries: page,
        nextCursor: next
      )
    }
  }

  private static func publicThreadReadError(_ error: CodexRPCError) -> Error {
    switch error {
    case .remote(_, let message, _)
    where message == "thread not loaded" || message.hasPrefix("invalid thread id"):
      return BridgeMCPQueryError.threadNotFound
    case .timeout:
      return BridgeMCPQueryError.timeout
    default:
      return error
    }
  }

  public func listModels(deadline: ContinuousClock.Instant) async throws -> MCPModelList {
    try Self.checkDeadline(deadline)
    if let cache = modelCache, clock.now < cache.fetchedAt + configuration.modelsCacheTTL {
      return cache.models
    }
    // Single flight: concurrent callers share one app-server spawn instead of
    // starting one cold process per request.
    let inFlight: InFlightModels
    if let existing = inFlightModels {
      inFlight = existing
    } else {
      modelsFetchGeneration += 1
      let created = InFlightModels(
        generation: modelsFetchGeneration,
        task: makeModelsFetchTask()
      )
      inFlightModels = created
      inFlight = created
    }
    let result = await inFlight.task.result
    if inFlightModels?.generation == inFlight.generation {
      inFlightModels = nil
    }
    switch result {
    case .success(let models):
      modelCache = ModelCacheEntry(models: models, fetchedAt: clock.now)
      try Self.checkDeadline(deadline)
      return models
    case .failure(let error):
      try Self.checkDeadline(deadline)
      throw error
    }
  }

  private func makeModelsFetchTask() -> Task<MCPModelList, any Error> {
    let configuration = self.configuration
    let fetchDeadline =
      clock.now
      .advanced(by: .nanoseconds(Int64(clamping: configuration.requestTimeoutNanoseconds)))
    return Task {
      try await Self.fetchModels(configuration: configuration, deadline: fetchDeadline)
    }
  }

  private static func fetchModels(
    configuration: ServiceCodexCatalogConfiguration,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPModelList {
    try await withClient(configuration: configuration, deadline: deadline) { client in
      var cursor: String?
      var models: [MCPModelSummary] = []
      for _ in 0..<8 {
        try checkDeadline(deadline)
        let page = try await client.listModels(
          ModelListParams(cursor: cursor, limit: 100, includeHidden: false)
        )
        models.append(contentsOf: try page.data.map(Self.model))
        guard let next = page.nextCursor, !next.isEmpty, next != cursor else {
          guard Set(models.map(\.modelID)).count == models.count else {
            throw BridgeMCPQueryError.unavailable
          }
          return MCPModelList(models: models)
        }
        cursor = next
      }
      throw BridgeMCPQueryError.unavailable
    }
  }

  private func withClient<Output: Sendable>(
    deadline: ContinuousClock.Instant,
    operation: @escaping @Sendable (CodexAppServerClient) async throws -> Output
  ) async throws -> Output {
    try await Self.withClient(
      configuration: configuration,
      deadline: deadline,
      operation: operation
    )
  }

  private static func withClient<Output: Sendable>(
    configuration: ServiceCodexCatalogConfiguration,
    deadline: ContinuousClock.Instant,
    operation: @escaping @Sendable (CodexAppServerClient) async throws -> Output
  ) async throws -> Output {
    try checkDeadline(deadline)
    let client = CodexAppServerClient(
      configuration: configuration.appServer,
      defaultTimeoutNanoseconds: configuration.requestTimeoutNanoseconds,
      eventBufferLimit: configuration.eventBufferLimit
    )
    let drain = Task {
      for await event in client.events {
        guard case .serverRequest(let request) = event else { continue }
        try? await client.respond(
          to: request.id,
          errorCode: -32601,
          message: "The read-only catalog cannot approve operations."
        )
      }
    }
    do {
      try await client.start()
      _ = try await client.initialize(clientInfo: configuration.clientInfo)
      let output = try await operation(client)
      try checkDeadline(deadline)
      drain.cancel()
      await client.stop()
      return output
    } catch is CancellationError {
      drain.cancel()
      await client.stop()
      throw CancellationError()
    } catch let error as BridgeMCPQueryError {
      drain.cancel()
      await client.stop()
      throw error
    } catch {
      drain.cancel()
      await client.stop()
      throw BridgeMCPQueryError.unavailable
    }
  }

  private static func summary(_ source: CodexThread) throws -> MCPThreadSummary {
    try validateIdentifier(source.id, maximum: 1_024)
    let title = safeOptional(source.name, maximum: 1_024)
    let preview = safeOptional(source.preview, maximum: 4 * 1_024)
    let status =
      source.status.stringValue
      ?? source.status.objectValue?["type"]?.stringValue
      ?? "unknown"
    try validateIdentifier(status, maximum: 128)
    return MCPThreadSummary(
      threadID: source.id,
      title: title,
      status: status,
      updatedAt: source.updatedAt >= 0
        ? ISO8601DateFormatter().string(
          from: Date(timeIntervalSince1970: TimeInterval(source.updatedAt))
        ) : nil,
      preview: preview
    )
  }

  private static func entries(_ turn: CodexTurn) throws -> [MCPThreadEntry] {
    try validateIdentifier(turn.id, maximum: 1_024)
    var result: [MCPThreadEntry] = []
    for item in turn.items {
      guard let object = item.objectValue,
        let type = object["type"]?.stringValue,
        let text = messageText(object)
      else { continue }
      let role: String
      switch type {
      case "agentMessage": role = "assistant"
      case "userMessage": role = "user"
      default: continue
      }
      let safeText = OutboundContentSecurity.redacted(text, maximumUTF8Bytes: 32 * 1_024)
      guard !safeText.isEmpty else { continue }
      result.append(
        MCPThreadEntry(
          turnID: turn.id,
          role: role,
          text: safeText,
          status: safeOptional(turn.status, maximum: 128)
        )
      )
      guard result.count <= 1_000 else { throw BridgeMCPQueryError.unavailable }
    }
    return result
  }

  private static func messageText(_ object: [String: JSONValue]) -> String? {
    if let text = object["text"]?.stringValue { return text }
    guard case .array(let content)? = object["content"] else { return nil }
    let text = content.compactMap { value in
      value.objectValue?["text"]?.stringValue
    }.joined(separator: "\n")
    return text.isEmpty ? nil : text
  }

  private static func model(_ source: CodexModel) throws -> MCPModelSummary {
    try validateIdentifier(source.id, maximum: 256)
    let displayName = OutboundContentSecurity.redacted(
      source.displayName,
      maximumUTF8Bytes: 1_024
    )
    guard !displayName.isEmpty else { throw BridgeMCPQueryError.unavailable }
    let efforts = source.supportedReasoningEfforts.map(\.reasoningEffort)
    guard !efforts.isEmpty, Set(efforts).count == efforts.count else {
      throw BridgeMCPQueryError.unavailable
    }
    for effort in efforts { try validateIdentifier(effort, maximum: 64) }
    var tiers: [String] = []
    for tier in source.serviceTiers ?? [] {
      try validateIdentifier(tier.id, maximum: 64)
      guard !tiers.contains(tier.id) else { throw BridgeMCPQueryError.unavailable }
      tiers.append(tier.id)
    }
    var speedTiers: [String] = []
    for tier in source.additionalSpeedTiers ?? [] {
      try validateIdentifier(tier, maximum: 64)
      guard !speedTiers.contains(tier) else { throw BridgeMCPQueryError.unavailable }
      speedTiers.append(tier)
    }
    let defaultEffort: String?
    if source.defaultReasoningEffort.isEmpty {
      defaultEffort = nil
    } else {
      try validateIdentifier(source.defaultReasoningEffort, maximum: 64)
      guard efforts.contains(source.defaultReasoningEffort) else {
        throw BridgeMCPQueryError.unavailable
      }
      defaultEffort = source.defaultReasoningEffort
    }
    return MCPModelSummary(
      modelID: source.id,
      displayName: displayName,
      isDefault: source.isDefault,
      reasoningEfforts: efforts,
      defaultReasoningEffort: defaultEffort,
      serviceTiers: tiers,
      additionalSpeedTiers: speedTiers
    )
  }

  private static func decodeCursor(_ cursor: String?, maximum: Int) throws -> Int {
    guard let cursor else { return 0 }
    let parts = cursor.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 2, parts[0] == "v1", let value = Int(parts[1]),
      value >= 0, value <= maximum
    else {
      throw BridgeMCPQueryError.contractRejected
    }
    return value
  }

  private static func decodeAppCursor(_ cursor: String?) throws -> Int {
    guard let cursor else { return 0 }
    guard cursor.hasPrefix("app.v1."), let offset = Int(cursor.dropFirst(7)), offset >= 0 else {
      throw BridgeMCPQueryError.contractRejected
    }
    return offset
  }

  private static func safeOptional(_ value: String?, maximum: Int) -> String? {
    guard let value else { return nil }
    let safe = OutboundContentSecurity.redacted(value, maximumUTF8Bytes: maximum)
    return safe.isEmpty ? nil : safe
  }

  private static func samePath(_ lhs: String, _ rhs: String) -> Bool {
    AgentPathSemantics.isContained(lhs, in: rhs)
      && AgentPathSemantics.isContained(rhs, in: lhs)
  }

  private static func validIdentifier(_ value: String, maximum: Int) -> Bool {
    do {
      try validateIdentifier(value, maximum: maximum)
      return true
    } catch {
      return false
    }
  }

  private static func validateIdentifier(_ value: String, maximum: Int) throws {
    guard !value.isEmpty,
      value == value.trimmingCharacters(in: .whitespacesAndNewlines),
      value.utf8.count <= maximum,
      !value.contains("\0"),
      value.rangeOfCharacter(from: .controlCharacters) == nil,
      OutboundContentSecurity.isSafe(value)
    else {
      throw BridgeMCPQueryError.unavailable
    }
  }

  private static func checkDeadline(_ deadline: ContinuousClock.Instant) throws {
    guard ContinuousClock.now < deadline else { throw BridgeMCPQueryError.timeout }
  }
}
