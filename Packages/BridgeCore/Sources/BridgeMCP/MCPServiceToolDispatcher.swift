import BridgeFiles
import BridgeSecurity
import Foundation
import Logging
import MCP

public struct MCPServiceToolDeadlines: Sendable {
  public static let production = MCPServiceToolDeadlines(
    read: .seconds(15),
    submit: .seconds(5),
    mutation: .seconds(10),
    projectChanges: .seconds(20)
  )

  public let read: ContinuousClock.Duration
  public let submit: ContinuousClock.Duration
  public let mutation: ContinuousClock.Duration
  public let projectChanges: ContinuousClock.Duration

  public init(
    read: ContinuousClock.Duration,
    submit: ContinuousClock.Duration,
    mutation: ContinuousClock.Duration,
    projectChanges: ContinuousClock.Duration = .seconds(20)
  ) {
    precondition(
      read > .zero && submit > .zero && mutation > .zero && projectChanges > .zero
    )
    self.read = read
    self.submit = submit
    self.mutation = mutation
    self.projectChanges = projectChanges
  }
}

public struct MCPServiceToolDispatcher: Sendable {
  let service: any BridgeMCPServiceAPI
  let exposureMode: MCPServiceExposureMode
  let clientID: MCPClientID
  let resultEncoder: MCPToolResultEncoder
  let admission: MCPToolAdmission
  let deadlines: MCPServiceToolDeadlines
  let logger: Logger
  let clock = ContinuousClock()

  public init(
    service: any BridgeMCPServiceAPI,
    exposureMode: MCPServiceExposureMode,
    clientID: MCPClientID = .chatGPT,
    resultEncoder: MCPToolResultEncoder = .init(),
    admission: MCPToolAdmission = .init(),
    deadlines: MCPServiceToolDeadlines = .production,
    logger: Logger = Logger(label: "CodexBridge.BridgeMCP.ServiceTools")
  ) {
    self.service = service
    self.exposureMode = exposureMode
    self.clientID = clientID
    self.resultEncoder = resultEncoder
    self.admission = admission
    self.deadlines = deadlines
    self.logger = logger
  }

  public func call(
    _ parameters: CallTool.Parameters,
    sessionID: String = "direct"
  ) async throws -> CallTool.Result {
    guard let contract = MCPServiceToolCatalog.contract(named: parameters.name),
      contract.isExposed(in: exposureMode)
    else {
      throw MCPError.invalidParams("Unknown tool name.")
    }
    let key = sessionID.isEmpty ? "direct" : sessionID
    guard await admission.acquire(sessionID: key) else {
      return try encodeQueryError(.busy)
    }
    defer { Task { await admission.release(sessionID: key) } }

    do {
      return try await callAdmitted(
        contract,
        arguments: parameters.arguments,
        sessionID: key
      )
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
    _ contract: MCPServiceToolContract,
    arguments: [String: Value]?,
    sessionID: String
  ) async throws -> CallTool.Result {
    switch contract.route {
    case .readOnly:
      return try await callReadOnly(contract.name, arguments: arguments)
    case .task:
      return try await callTask(contract.name, arguments: arguments, sessionID: sessionID)
    case .direct:
      return try await callDirect(contract.name, arguments: arguments)
    }
  }
}
