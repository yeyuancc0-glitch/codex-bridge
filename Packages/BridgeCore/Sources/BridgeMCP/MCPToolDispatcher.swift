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
  private let taskTools: TaskTools
  private let projectTools: ProjectTools
  private let resultEncoder: MCPToolResultEncoder
  private let admission: MCPToolAdmission
  private let logger: Logger

  public init(
    queries: any BridgeMCPQueries,
    taskOperations: (any BridgeMCPTaskOperations)? = nil,
    projectOperations: (any BridgeMCPProjectOperations)? = nil,
    resultEncoder: MCPToolResultEncoder = .init(),
    admission: MCPToolAdmission = .init(),
    deadlines: MCPToolDeadlines = .production,
    taskDeadlines: MCPTaskToolDeadlines = .production,
    logger: Logger = Logger(label: "CodexBridge.BridgeMCP.Tools")
  ) {
    tools = ReadOnlyTools(queries: queries, deadlines: deadlines)
    taskTools = TaskTools(operations: taskOperations, deadlines: taskDeadlines)
    projectTools = ProjectTools(operations: projectOperations)
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
    guard let name = MCPDispatchedToolName(rawValue: parameters.name) else {
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
    _ name: MCPDispatchedToolName,
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
    _ name: MCPDispatchedToolName,
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
    case .getTask:
      return try resultEncoder.encode(await taskTools.getTask(arguments: arguments))
    case .getTaskEvents:
      return try resultEncoder.encode(await taskTools.getTaskEvents(arguments: arguments))
    case .getTaskDiff:
      return try resultEncoder.encode(await taskTools.getTaskDiff(arguments: arguments))
    case .getFinalReport:
      return try resultEncoder.encode(await taskTools.getFinalReport(arguments: arguments))
    case .submitTask:
      return try resultEncoder.encode(await taskTools.submitTask(arguments: arguments))
    case .steerTask:
      return try resultEncoder.encode(await taskTools.steerTask(arguments: arguments))
    case .interruptTask:
      return try resultEncoder.encode(await taskTools.interruptTask(arguments: arguments))
    case .getProject:
      return try resultEncoder.encode(await projectTools.getProject(arguments: arguments))
    case .searchProjectFiles:
      return try resultEncoder.encode(await projectTools.searchProjectFiles(arguments: arguments))
    case .readProjectFile:
      return try resultEncoder.encode(await projectTools.readProjectFile(arguments: arguments))
    case .openInCodex:
      return try resultEncoder.encode(await projectTools.openInCodex(arguments: arguments))
    }
  }

  private func encodeQueryError(_ error: BridgeMCPQueryError) throws -> CallTool.Result {
    try resultEncoder.encode(MCPToolErrorOutput(error: error.toolError), isError: true)
  }
  private func encodeResultError(_ error: MCPToolResultEncodingError) throws -> CallTool.Result {
    switch error {
    case .resultTooLarge:
      let description = MCPToolErrorDTO(
        code: "result_too_large",
        category: .capabilityUnavailable,
        message: "The result is too large. Request a smaller page.",
        retryable: true,
        nextAction: "request_smaller_page"
      )
      return try resultEncoder.encode(MCPToolErrorOutput(error: description), isError: true)
    }
  }

}
