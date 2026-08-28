import BridgeACP
import BridgeAgentCore
import Foundation

public struct OpenCodeACPClientInfo: Equatable, Sendable {
  public let name: String
  public let title: String
  public let version: String

  public init(name: String, title: String, version: String) {
    self.name = name
    self.title = title
    self.version = version
  }
}

public struct OpenCodeACPInitialization: Equatable, Sendable {
  public let protocolVersion: Int
  public let agentName: String?
  public let agentTitle: String?
  public let agentVersion: String?
  public let advertisedCapabilities: Set<AgentCapability>
  public let supportsLoadSession: Bool
  public let supportsResumeSession: Bool
  public let supportsCloseSession: Bool

  public init(
    protocolVersion: Int,
    agentName: String?,
    agentTitle: String?,
    agentVersion: String?,
    advertisedCapabilities: Set<AgentCapability>,
    supportsLoadSession: Bool,
    supportsResumeSession: Bool,
    supportsCloseSession: Bool
  ) {
    self.protocolVersion = protocolVersion
    self.agentName = agentName
    self.agentTitle = agentTitle
    self.agentVersion = agentVersion
    self.advertisedCapabilities = advertisedCapabilities
    self.supportsLoadSession = supportsLoadSession
    self.supportsResumeSession = supportsResumeSession
    self.supportsCloseSession = supportsCloseSession
  }
}

public struct OpenCodeACPSession: Equatable, Sendable {
  public let id: String
  public let configOptions: [OpenCodeACPConfigOption]

  public init(id: String, configOptions: [OpenCodeACPConfigOption] = []) {
    self.id = id
    self.configOptions = configOptions
  }
}

public struct OpenCodeACPConfigOption: Equatable, Sendable {
  public let id: String
  public let currentValue: String?
  public let values: [OpenCodeACPConfigValue]

  public init(id: String, currentValue: String?, values: [OpenCodeACPConfigValue]) {
    self.id = id
    self.currentValue = currentValue
    self.values = values
  }
}

public struct OpenCodeACPConfigValue: Equatable, Sendable {
  public let value: String
  public let name: String

  public init(value: String, name: String) {
    self.value = value
    self.name = name
  }
}

public struct OpenCodeACPPromptResult: Equatable, Sendable {
  public let stopReason: String
  public let eventSequenceBarrier: Int64

  public init(stopReason: String, eventSequenceBarrier: Int64) {
    self.stopReason = stopReason
    self.eventSequenceBarrier = eventSequenceBarrier
  }
}

public actor OpenCodeACPClient {
  public nonisolated let events: AsyncStream<OpenCodeACPClientEventEnvelope>

  private let transport: any OpenCodeACPTransport
  let requestBroker: BridgeACP.ACPRequestBroker
  private let clientInfo: OpenCodeACPClientInfo
  let eventContinuation: AsyncStream<OpenCodeACPClientEventEnvelope>.Continuation
  var readerTask: Task<Void, Never>?
  var nextEventSequence: Int64 = 0
  var pendingPermissions: [String: OpenCodeACPPermissionRequest] = [:]
  var started = false
  var closed = false
  var initializationStorage: OpenCodeACPInitialization?
  var initializationTask: Task<OpenCodeACPInitialization, any Error>?
  var activeSessionID: String?
  var sessionOperationInFlight = false

  public init(
    transport: any OpenCodeACPTransport,
    clientInfo: OpenCodeACPClientInfo,
    requestTimeout: Duration = .seconds(30),
    eventBufferLimit: Int = 256
  ) {
    let pair = AsyncStream.makeStream(
      of: OpenCodeACPClientEventEnvelope.self,
      bufferingPolicy: .bufferingOldest(max(1, eventBufferLimit))
    )
    self.transport = transport
    requestBroker = BridgeACP.ACPRequestBroker(
      transport: transport,
      requestTimeout: requestTimeout
    )
    self.clientInfo = clientInfo
    events = pair.stream
    eventContinuation = pair.continuation
  }

  public var initialization: OpenCodeACPInitialization? {
    initializationStorage
  }

  public var eventSequence: Int64 {
    nextEventSequence
  }

  public func start() {
    guard !started, !closed else { return }
    started = true
    let source = transport.incoming
    readerTask = Task { [weak self] in
      do {
        for try await frame in source {
          guard let self else { return }
          await self.receive(frame)
        }
        await self?.transportEnded(error: nil)
      } catch {
        await self?.transportEnded(error: error)
      }
    }
  }

  public func initialize() async throws -> OpenCodeACPInitialization {
    start()
    if let initializationStorage { return initializationStorage }
    if let initializationTask {
      do {
        let initialization = try await initializationTask.value
        initializationStorage = initialization
        self.initializationTask = nil
        return initialization
      } catch {
        self.initializationTask = nil
        throw error
      }
    }

    let task = Task { [weak self] () throws -> OpenCodeACPInitialization in
      guard let self else { throw OpenCodeACPError.transportClosed }
      return try await self.performInitialization()
    }
    initializationTask = task
    do {
      let initialization = try await task.value
      initializationStorage = initialization
      initializationTask = nil
      return initialization
    } catch {
      initializationTask = nil
      throw error
    }
  }

  private func performInitialization() async throws -> OpenCodeACPInitialization {
    let response = try await request(
      method: "initialize",
      params: .object([
        "protocolVersion": .integer(1),
        "clientCapabilities": .object([:]),
        "clientInfo": .object([
          "name": .string(clientInfo.name),
          "title": .string(clientInfo.title),
          "version": .string(clientInfo.version),
        ]),
      ])
    )
    let initialization = try Self.parseInitialization(response.value)
    guard initialization.protocolVersion == 1 else {
      throw OpenCodeACPError.unsupportedProtocol(initialization.protocolVersion)
    }
    return initialization
  }
}
