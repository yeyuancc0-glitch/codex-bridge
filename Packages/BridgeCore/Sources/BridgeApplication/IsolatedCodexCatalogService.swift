import BridgeCodexRPC
import Foundation

public struct IsolatedCodexCatalogConfiguration: Sendable {
  public let appServer: AppServerConfiguration
  public let clientInfo: CodexClientInfo
  public let requestTimeoutNanoseconds: UInt64
  public let eventBufferLimit: Int

  public init(
    appServer: AppServerConfiguration = .codex(),
    clientInfo: CodexClientInfo,
    requestTimeoutNanoseconds: UInt64 = 20_000_000_000,
    eventBufferLimit: Int = 64
  ) {
    self.appServer = appServer
    self.clientInfo = clientInfo
    self.requestTimeoutNanoseconds = max(1, requestTimeoutNanoseconds)
    self.eventBufferLimit = max(1, eventBufferLimit)
  }
}

public actor IsolatedCodexCatalogService: CodexCatalogQuerying {
  private let configuration: IsolatedCodexCatalogConfiguration

  public init(configuration: IsolatedCodexCatalogConfiguration) {
    self.configuration = configuration
  }

  public func listThreads(
    canonicalWorkingDirectories: [String],
    cursor: String?,
    limit: Int,
    search: String?,
    deadline: ContinuousClock.Instant
  ) async throws -> CatalogThreadPage {
    guard !canonicalWorkingDirectories.isEmpty, (1...100).contains(limit) else {
      throw BridgeApplicationError.invalidArgument
    }
    return try await withClient(deadline: deadline) { client in
      let response = try await client.listThreads(
        ThreadListParams(
          cursor: cursor,
          limit: UInt32(limit),
          sortKey: "updated_at",
          sortDirection: "desc",
          archived: false,
          cwd: .anyOf(canonicalWorkingDirectories),
          searchTerm: search,
          useStateDbOnly: true
        )
      )
      return CatalogThreadPage(
        threads: response.data.map { Self.thread($0, includeTurns: false) },
        nextCursor: response.nextCursor
      )
    }
  }

  public func readThread(
    threadID: String,
    includeTurns: Bool,
    deadline: ContinuousClock.Instant
  ) async throws -> CatalogThread {
    guard Self.validIdentifier(threadID, maximum: 1_024) else {
      throw BridgeApplicationError.invalidArgument
    }
    return try await withClient(deadline: deadline) { client in
      let response = try await client.readThread(
        ThreadReadParams(threadId: threadID, includeTurns: includeTurns)
      )
      return Self.thread(response.thread, includeTurns: includeTurns)
    }
  }

  public func listModels(deadline: ContinuousClock.Instant) async throws -> [CatalogModel] {
    try await withClient(deadline: deadline) { client in
      var cursor: String?
      var result: [CatalogModel] = []
      for _ in 0..<8 {
        let page = try await client.listModels(
          ModelListParams(cursor: cursor, limit: 100, includeHidden: false)
        )
        result.append(contentsOf: page.data.map(Self.model))
        guard let next = page.nextCursor, !next.isEmpty, next != cursor else { return result }
        cursor = next
      }
      throw BridgeApplicationError.catalogLimitExceeded
    }
  }

  private func withClient<Output: Sendable>(
    deadline: ContinuousClock.Instant,
    operation: @escaping @Sendable (CodexAppServerClient) async throws -> Output
  ) async throws -> Output {
    try Self.checkDeadline(deadline)
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
      try Self.checkDeadline(deadline)
      drain.cancel()
      await client.stop()
      return output
    } catch is CancellationError {
      drain.cancel()
      await client.stop()
      throw CancellationError()
    } catch let error as BridgeApplicationError {
      drain.cancel()
      await client.stop()
      throw error
    } catch {
      drain.cancel()
      await client.stop()
      throw BridgeApplicationError.catalogUnavailable
    }
  }

  private static func thread(_ source: CodexThread, includeTurns: Bool) -> CatalogThread {
    CatalogThread(
      threadID: source.id,
      cwd: source.cwd,
      title: source.name,
      status: status(source.status),
      updatedAt: date(source.updatedAt),
      preview: source.preview,
      entries: includeTurns ? source.turns.flatMap(entries) : []
    )
  }

  private static func entries(_ turn: CodexTurn) -> [CatalogThreadEntry] {
    turn.items.compactMap { item in
      guard let object = item.objectValue,
        let type = object["type"]?.stringValue,
        let text = messageText(object)
      else { return nil }
      let role: String
      switch type {
      case "agentMessage": role = "assistant"
      case "userMessage": role = "user"
      default: return nil
      }
      return CatalogThreadEntry(
        turnID: turn.id,
        role: role,
        text: text,
        status: turn.status
      )
    }
  }

  private static func messageText(_ object: [String: JSONValue]) -> String? {
    if let text = object["text"]?.stringValue { return text }
    guard case .array(let content)? = object["content"] else { return nil }
    let text = content.compactMap { value -> String? in
      value.objectValue?["text"]?.stringValue
    }.joined(separator: "\n")
    return text.isEmpty ? nil : text
  }

  private static func model(_ source: CodexModel) -> CatalogModel {
    CatalogModel(
      id: source.id,
      displayName: source.displayName,
      isDefault: source.isDefault,
      reasoningEfforts: source.supportedReasoningEfforts.map(\.reasoningEffort)
    )
  }

  private static func status(_ value: JSONValue) -> String {
    value.stringValue ?? value.objectValue?["type"]?.stringValue ?? "unknown"
  }

  private static func date(_ timestamp: Int64) -> Date? {
    guard timestamp >= 0 else { return nil }
    return Date(timeIntervalSince1970: TimeInterval(timestamp))
  }

  private static func validIdentifier(_ value: String, maximum: Int) -> Bool {
    !value.isEmpty && value.utf8.count <= maximum && !value.contains("\0")
      && value.rangeOfCharacter(from: .controlCharacters) == nil
  }

  private static func checkDeadline(_ deadline: ContinuousClock.Instant) throws {
    guard ContinuousClock.now < deadline else { throw BridgeApplicationError.deadlineExceeded }
  }
}
