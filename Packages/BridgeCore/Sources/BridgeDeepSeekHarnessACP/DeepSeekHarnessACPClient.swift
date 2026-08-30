import BridgeACP
import BridgeAgentCore
import Foundation

public actor DeepSeekHarnessACPClient {
  public nonisolated let events: AsyncStream<DeepSeekHarnessACPClientEventEnvelope>

  let broker: ACPRequestBroker
  let transport: any ACPTransport
  private let clientInfo: DeepSeekHarnessACPClientInfo
  private let requestTimeout: Duration
  let eventContinuation: AsyncStream<DeepSeekHarnessACPClientEventEnvelope>.Continuation
  var readerTask: Task<Void, Never>?
  var initializationTask: Task<DeepSeekHarnessACPInitialization, any Error>?
  var initializationStorage: DeepSeekHarnessACPInitialization?
  var activeSessionID: String?
  var pendingPermissions: [String: DeepSeekHarnessACPPermissionRequest] = [:]
  var nextEventSequence: Int64 = 0
  var started = false
  var closed = false
  var terminalFailureStorage: DeepSeekHarnessACPError?
  var sessionOperationInFlight = false

  public init(
    transport: any ACPTransport,
    clientInfo: DeepSeekHarnessACPClientInfo,
    requestTimeout: Duration = DeepSeekHarnessACPConstants.requestTimeout,
    eventBufferLimit: Int = DeepSeekHarnessACPConstants.maximumEventBuffer
  ) {
    let pair = AsyncStream.makeStream(
      of: DeepSeekHarnessACPClientEventEnvelope.self,
      bufferingPolicy: .bufferingOldest(max(1, eventBufferLimit))
    )
    self.transport = transport
    broker = ACPRequestBroker(transport: transport, requestTimeout: requestTimeout)
    self.clientInfo = clientInfo
    self.requestTimeout = requestTimeout
    events = pair.stream
    eventContinuation = pair.continuation
  }

  public var initialization: DeepSeekHarnessACPInitialization? {
    initializationStorage
  }

  public var eventSequence: Int64 {
    nextEventSequence
  }

  func terminalFailure() -> DeepSeekHarnessACPError? {
    terminalFailureStorage
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

  public func initialize() async throws -> DeepSeekHarnessACPInitialization {
    start()
    if let initializationStorage { return initializationStorage }
    if let initializationTask {
      do {
        let value = try await initializationTask.value
        initializationStorage = value
        self.initializationTask = nil
        return value
      } catch {
        self.initializationTask = nil
        throw error
      }
    }
    let task = Task { [weak self] () throws -> DeepSeekHarnessACPInitialization in
      guard let self else { throw DeepSeekHarnessACPError.transportClosed }
      return try await self.performInitialization()
    }
    initializationTask = task
    do {
      let value = try await task.value
      initializationStorage = value
      initializationTask = nil
      return value
    } catch {
      initializationTask = nil
      throw error
    }
  }

  private func performInitialization() async throws -> DeepSeekHarnessACPInitialization {
    let response = try await request(
      method: "initialize",
      params: .object([
        "protocolVersion": .integer(Int64(DeepSeekHarnessACPConstants.acpProtocolVersion)),
        "clientCapabilities": .object([:]),
        "clientInfo": .object([
          "name": .string(clientInfo.name),
          "title": .string(clientInfo.title),
          "version": .string(clientInfo.version),
        ]),
      ])
    )
    guard let object = response.value.objectValue,
      let protocolVersion = object["protocolVersion"]?.intValue
    else {
      throw DeepSeekHarnessACPError.malformedResponse
    }
    let agentInfo: [String: ACPJSONValue]?
    if let value = object["agentInfo"] {
      guard let decoded = value.objectValue,
        decoded["name"]?.stringValue != nil,
        decoded["version"]?.stringValue != nil
      else {
        throw DeepSeekHarnessACPError.malformedResponse
      }
      agentInfo = decoded
    } else {
      agentInfo = nil
    }
    let initialization = DeepSeekHarnessACPInitialization(
      protocolVersion: protocolVersion,
      agentName: agentInfo?["name"]?.stringValue,
      agentTitle: agentInfo?["title"]?.stringValue,
      agentVersion: agentInfo?["version"]?.stringValue
    )
    guard initialization.protocolVersion == DeepSeekHarnessACPConstants.acpProtocolVersion else {
      throw DeepSeekHarnessACPError.unsupportedProtocol(initialization.protocolVersion)
    }
    return initialization
  }
}
