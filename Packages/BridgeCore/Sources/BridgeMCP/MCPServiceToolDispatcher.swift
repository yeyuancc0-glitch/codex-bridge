import BridgeFiles
import BridgeSecurity
import Foundation
import Logging
import MCP

public struct MCPServiceToolDeadlines: Sendable {
  public static let production = MCPServiceToolDeadlines(
    read: .seconds(15),
    submit: .seconds(5),
    mutation: .seconds(10)
  )

  public let read: ContinuousClock.Duration
  public let submit: ContinuousClock.Duration
  public let mutation: ContinuousClock.Duration

  public init(
    read: ContinuousClock.Duration,
    submit: ContinuousClock.Duration,
    mutation: ContinuousClock.Duration
  ) {
    precondition(read > .zero && submit > .zero && mutation > .zero)
    self.read = read
    self.submit = submit
    self.mutation = mutation
  }
}

public struct MCPServiceToolDispatcher: Sendable {
  let service: any BridgeMCPServiceAPI
  let exposureMode: MCPServiceExposureMode
  let resultEncoder: MCPToolResultEncoder
  let admission: MCPToolAdmission
  let deadlines: MCPServiceToolDeadlines
  let logger: Logger
  let clock = ContinuousClock()

  public init(
    service: any BridgeMCPServiceAPI,
    exposureMode: MCPServiceExposureMode,
    resultEncoder: MCPToolResultEncoder = .init(),
    admission: MCPToolAdmission = .init(),
    deadlines: MCPServiceToolDeadlines = .production,
    logger: Logger = Logger(label: "CodexBridge.BridgeMCP.ServiceTools")
  ) {
    self.service = service
    self.exposureMode = exposureMode
    self.resultEncoder = resultEncoder
    self.admission = admission
    self.deadlines = deadlines
    self.logger = logger
  }

  public func call(
    _ parameters: CallTool.Parameters,
    sessionID: String = "direct"
  ) async throws -> CallTool.Result {
    guard let name = MCPServiceToolName(rawValue: parameters.name), isExposed(name) else {
      throw MCPError.invalidParams("Unknown tool name.")
    }
    let key = sessionID.isEmpty ? "direct" : sessionID
    guard await admission.acquire(sessionID: key) else {
      return try encodeQueryError(.busy)
    }
    defer { Task { await admission.release(sessionID: key) } }

    do {
      return try await callAdmitted(name, arguments: parameters.arguments)
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
        "Lightweight MCP service tool request failed. name=\(parameters.name) error=\(error) type=\(String(describing: type(of: error)))",
        metadata: ["correlation_id": .string(correlationID)]
      )
      throw MCPError.internalError("The tool request failed.")
    }
  }

  private func callAdmitted(
    _ name: MCPServiceToolName,
    arguments: [String: Value]?
  ) async throws -> CallTool.Result {
    switch name {
    case .bridgeStatus, .listProjects, .getProject, .searchProjectFiles, .readProjectFile,
      .listThreads, .readThread, .listModels, .listSkills, .readSkill, .getProjectChanges,
      .listProjectCommands:
      return try await callReadOnly(name, arguments: arguments)
    case .runSkillAction, .getTask, .submitTask, .steerTask, .interruptTask:
      return try await callTask(name, arguments: arguments)
    case .directWriteProjectFile, .directEditProjectFile, .directApplyProjectPatch,
      .directManageProjectPath, .directExecCommand, .directGitCommit, .directReadCommand,
      .directWriteStdin, .directInterruptCommand:
      return try await callDirect(name, arguments: arguments)
    }
  }

  private func isExposed(_ name: MCPServiceToolName) -> Bool {
    exposureMode == .full
      || ![
        .submitTask, .steerTask, .interruptTask, .directWriteProjectFile, .directEditProjectFile,
        .directApplyProjectPatch, .directManageProjectPath, .runSkillAction,
      ].contains(name)
  }
}
