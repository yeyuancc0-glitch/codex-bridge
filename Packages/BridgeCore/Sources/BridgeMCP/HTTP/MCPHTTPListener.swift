import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOHTTP1
@preconcurrency import NIOPosix

public actor MCPHTTPListener {
  private let configuration: MCPHTTPConfiguration
  private let handler: MCPAuthenticatedHTTPRequestHandler
  private let emissionObserver: MCPHTTPEmissionObserver?
  private let admission: MCPHTTPAdmission
  private var serverChannel: (any Channel)?
  private var eventLoopGroup: MultiThreadedEventLoopGroup?
  private var currentStartID: UUID?
  private var isStopping = false
  private var stopWaiters: [CheckedContinuation<Void, Never>] = []

  public init(
    configuration: MCPHTTPConfiguration,
    handler: @escaping MCPHTTPRequestHandler,
    emissionObserver: MCPHTTPEmissionObserver? = nil
  ) {
    self.configuration = configuration
    self.handler = { request in await handler(request.request) }
    self.emissionObserver = emissionObserver
    admission = MCPHTTPAdmission(
      maximumConnections: configuration.maximumConnections,
      maximumActiveRequests: configuration.maximumActiveRequests
    )
  }

  public init(
    configuration: MCPHTTPConfiguration,
    authenticatedHandler: @escaping MCPAuthenticatedHTTPRequestHandler,
    emissionObserver: MCPHTTPEmissionObserver? = nil
  ) {
    self.configuration = configuration
    self.handler = authenticatedHandler
    self.emissionObserver = emissionObserver
    admission = MCPHTTPAdmission(
      maximumConnections: configuration.maximumConnections,
      maximumActiveRequests: configuration.maximumActiveRequests
    )
  }

  public func start() async throws -> MCPHTTPBoundEndpoint {
    if let endpoint = boundEndpoint {
      return endpoint
    }
    guard !isStopping else {
      throw MCPHTTPListenerError.lifecycleTransitionInProgress
    }
    if let currentStartID {
      return try await waitForStart(currentStartID)
    }

    let startID = UUID()
    currentStartID = startID
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    eventLoopGroup = group
    var mutableDecoderLimits = NIOHTTPDecoderLimitConfiguration()
    mutableDecoderLimits.maxHeaderFieldSize = configuration.maximumHeaderBytes
    mutableDecoderLimits.maxHeaderListSize = configuration.maximumHeaderBytes
    let decoderLimits = mutableDecoderLimits

    let configuration = self.configuration
    let handler = self.handler
    let emissionObserver = self.emissionObserver
    let admission = self.admission
    let baseBootstrap = ServerBootstrap(group: group)
      .serverChannelOption(ChannelOptions.backlog, value: 64)

    #if os(Windows)
      // Winsock SO_REUSEADDR permits a second listener to take the same port.
      // A fixed Qwen endpoint must instead fail closed on port conflicts.
      let bootstrap = baseBootstrap
    #else
      let bootstrap =
        baseBootstrap
        .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
    #endif

    let configuredBootstrap =
      bootstrap
      .childChannelInitializer { channel in
        guard admission.register(channel) else {
          return channel.close()
        }
        return channel.pipeline.configureHTTPServerPipeline(
          withPipeliningAssistance: true,
          withErrorHandling: true,
          withDecoderLimitConfiguration: decoderLimits
        ).flatMap {
          channel.pipeline.addHandler(
            MCPHTTPHandler(
              configuration: configuration,
              authenticatedHandler: handler,
              emissionObserver: emissionObserver,
              admission: admission
            )
          )
        }.flatMapError { error in
          admission.unregister(channel)
          return channel.close().flatMapThrowing { throw error }
        }
      }
      .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
      .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
      .childChannelOption(
        ChannelOptions.writeBufferWaterMark,
        value: ChannelOptions.Types.WriteBufferWaterMark(
          low: 32 * 1_024,
          high: 64 * 1_024
        )
      )

    do {
      let channel = try await configuredBootstrap.bind(
        host: MCPHTTPConfiguration.loopbackHost,
        port: configuration.port
      ).get()
      guard
        channel.localAddress?.ipAddress == MCPHTTPConfiguration.loopbackHost,
        let port = channel.localAddress?.port
      else {
        try await channel.close().get()
        throw MCPHTTPListenerError.unexpectedBindAddress
      }
      guard currentStartID == startID, !isStopping else {
        try? await channel.close().get()
        throw CancellationError()
      }
      serverChannel = channel
      currentStartID = nil
      return MCPHTTPBoundEndpoint(host: MCPHTTPConfiguration.loopbackHost, port: port)
    } catch {
      if currentStartID == startID {
        currentStartID = nil
      }
      if eventLoopGroup === group {
        eventLoopGroup = nil
        try? await group.shutdownGracefully()
      }
      throw error
    }
  }

  public func stop() async {
    if isStopping {
      await withCheckedContinuation { continuation in
        stopWaiters.append(continuation)
      }
      return
    }
    isStopping = true
    admission.beginStopping()
    currentStartID = nil
    let channel = serverChannel
    let group = eventLoopGroup
    serverChannel = nil
    eventLoopGroup = nil

    try? await channel?.close().get()
    let children = admission.activeChannels()
    for child in children {
      try? await child.close().get()
    }
    await admission.waitForRequestDrain()
    try? await group?.shutdownGracefully()
    admission.resetAfterStop()
    isStopping = false
    let waiters = stopWaiters
    stopWaiters.removeAll(keepingCapacity: false)
    for waiter in waiters {
      waiter.resume()
    }
  }

  public func metrics() -> MCPHTTPMetrics {
    admission.metrics()
  }

  public var boundEndpoint: MCPHTTPBoundEndpoint? {
    guard
      let address = serverChannel?.localAddress,
      address.ipAddress == MCPHTTPConfiguration.loopbackHost,
      let port = address.port
    else {
      return nil
    }
    return MCPHTTPBoundEndpoint(host: MCPHTTPConfiguration.loopbackHost, port: port)
  }

  private func waitForStart(_ startID: UUID) async throws -> MCPHTTPBoundEndpoint {
    while currentStartID == startID {
      try await Task.sleep(for: .milliseconds(1))
    }
    if let endpoint = boundEndpoint {
      return endpoint
    }
    guard !isStopping else {
      throw MCPHTTPListenerError.lifecycleTransitionInProgress
    }
    return try await start()
  }
}

public enum MCPHTTPListenerError: Error, Equatable, Sendable {
  case unexpectedBindAddress
  case lifecycleTransitionInProgress
}
