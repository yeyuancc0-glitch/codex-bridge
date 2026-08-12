import Foundation
import Logging
import MCP

public actor MCPToolAdmission {
  public let globalLimit: Int
  public let perSessionLimit: Int

  private var activeCount = 0
  private var activeBySession: [String: Int] = [:]

  public init(globalLimit: Int = 8, perSessionLimit: Int = 2) {
    precondition(globalLimit > 0)
    precondition(perSessionLimit > 0 && perSessionLimit <= globalLimit)
    self.globalLimit = globalLimit
    self.perSessionLimit = perSessionLimit
  }

  func acquire(sessionID: String) -> Bool {
    let sessionCount = activeBySession[sessionID, default: 0]
    guard activeCount < globalLimit, sessionCount < perSessionLimit else { return false }
    activeCount += 1
    activeBySession[sessionID] = sessionCount + 1
    return true
  }

  func release(sessionID: String) {
    guard let sessionCount = activeBySession[sessionID], sessionCount > 0 else { return }
    activeCount -= 1
    if sessionCount == 1 {
      activeBySession.removeValue(forKey: sessionID)
    } else {
      activeBySession[sessionID] = sessionCount - 1
    }
  }
}

public struct MCPToolDispatcher: Sendable {
  private let tools: ReadOnlyTools
  private let resultEncoder: MCPToolResultEncoder
  private let admission: MCPToolAdmission
  private let logger: Logger

  public init(
    queries: any BridgeMCPQueries,
    resultEncoder: MCPToolResultEncoder = .init(),
    admission: MCPToolAdmission = .init(),
    deadlines: MCPToolDeadlines = .production,
    logger: Logger = Logger(label: "CodexBridge.BridgeMCP.Tools")
  ) {
    tools = ReadOnlyTools(queries: queries, deadlines: deadlines)
    self.resultEncoder = resultEncoder
    self.admission = admission
    self.logger = logger
  }

  public func call(_ parameters: CallTool.Parameters) async throws -> CallTool.Result {
    let sessionID =
      Server.currentHandlerContext?.httpContext?.header(HTTPHeaderName.sessionID) ?? "direct"
    return try await call(parameters, sessionID: sessionID)
  }

  public func call(
    _ parameters: CallTool.Parameters,
    sessionID: String
  ) async throws -> CallTool.Result {
    guard let name = MCPToolName(rawValue: parameters.name) else {
      throw MCPError.invalidParams("Unknown tool name.")
    }
    let admissionKey = sessionID.isEmpty ? "direct" : sessionID
    guard await admission.acquire(sessionID: admissionKey) else {
      return try encodeQueryError(.busy)
    }

    do {
      let result = try await callWithErrorMapping(name, arguments: parameters.arguments)
      await admission.release(sessionID: admissionKey)
      return result
    } catch {
      await admission.release(sessionID: admissionKey)
      throw error
    }
  }

  private func callWithErrorMapping(
    _ name: MCPToolName,
    arguments: [String: Value]?
  ) async throws -> CallTool.Result {
    do {
      return try await callAdmitted(name, arguments: arguments)
    } catch let error as BridgeMCPQueryError {
      return try encodeQueryError(error)
    } catch let error as MCPToolResultEncodingError {
      return try encodeResultError(error)
    } catch let error as MCPError {
      throw error
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      let correlationID = UUID().uuidString.lowercased()
      logger.error(
        "MCP tool request failed.",
        metadata: ["correlation_id": .string(correlationID)]
      )
      throw MCPError.internalError("The tool request failed.")
    }
  }

  private func callAdmitted(
    _ name: MCPToolName,
    arguments: [String: Value]?
  ) async throws -> CallTool.Result {
    switch name {
    case .bridgeStatus:
      return try resultEncoder.encode(await tools.bridgeStatus(arguments: arguments))
    case .listProjects:
      return try resultEncoder.encode(await tools.listProjects(arguments: arguments))
    case .listThreads:
      return try resultEncoder.encode(await tools.listThreads(arguments: arguments))
    case .readThread:
      return try resultEncoder.encode(await tools.readThread(arguments: arguments))
    case .listModels:
      return try resultEncoder.encode(await tools.listModels(arguments: arguments))
    }
  }

  private func encodeQueryError(_ error: BridgeMCPQueryError) throws -> CallTool.Result {
    let description: MCPToolErrorDTO
    switch error {
    case .projectNotFound:
      description = .init(
        code: "project_not_found",
        message: "The requested project is not available.",
        retryable: false
      )
    case .threadNotFound:
      description = .init(
        code: "thread_not_found",
        message: "The requested thread is not available in this project.",
        retryable: false
      )
    case .pathDenied:
      description = .init(
        code: "path_denied",
        message: "The requested data is outside the approved project boundary.",
        retryable: false
      )
    case .taskNotFound:
      description = .init(
        code: "task_not_found",
        message: "The requested task is not available.",
        retryable: false
      )
    case .busy:
      description = .init(
        code: "busy",
        message: "The Bridge is at its current request limit.",
        retryable: true
      )
    case .timeout:
      description = .init(
        code: "timeout",
        message: "The local operation did not finish before its deadline.",
        retryable: true
      )
    case .unavailable:
      description = .init(
        code: "unavailable",
        message: "A required local Bridge component is unavailable.",
        retryable: true
      )
    }
    return try resultEncoder.encode(MCPToolErrorOutput(error: description), isError: true)
  }

  private func encodeResultError(_ error: MCPToolResultEncodingError) throws -> CallTool.Result {
    switch error {
    case .resultTooLarge:
      let description = MCPToolErrorDTO(
        code: "result_too_large",
        message: "The result is too large. Request a smaller page.",
        retryable: true
      )
      return try resultEncoder.encode(MCPToolErrorOutput(error: description), isError: true)
    }
  }
}
