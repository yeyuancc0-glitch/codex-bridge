import Logging
import MCP

public struct MCPServiceServerFactory: Sendable {
  private let appVersion: String
  private let catalog: MCPServiceToolCatalog
  private let dispatcher: MCPServiceToolDispatcher

  public init(
    appVersion: String,
    service: any BridgeMCPServiceAPI,
    exposureMode: MCPServiceExposureMode,
    logger: Logger = Logger(label: "CodexBridge.BridgeMCP.LightweightServer")
  ) {
    precondition(!appVersion.isEmpty)
    self.appVersion = appVersion
    catalog = MCPServiceToolCatalog(exposureMode: exposureMode)
    dispatcher = MCPServiceToolDispatcher(
      service: service,
      exposureMode: exposureMode,
      logger: logger
    )
  }

  public func makeServer() async -> Server {
    let definitions = catalog.definitions
    let dispatcher = dispatcher
    let server = Server(
      name: "codex-bridge",
      version: appVersion,
      title: "Codex Bridge",
      instructions: "This service exposes only user-approved local projects. List projects, "
        + "Threads and models before submitting work. Task submission never grants local "
        + "approval; the user must approve execution in the macOS App.",
      capabilities: .init(tools: .init(listChanged: false)),
      configuration: .strict
    )
    await server.withMethodHandler(ListTools.self) { parameters in
      guard parameters.cursor == nil else {
        throw MCPError.invalidParams("The tool catalog does not use cursors.")
      }
      return ListTools.Result(tools: definitions)
    }
    await server.withMethodHandler(CallTool.self) { parameters in
      let sessionID =
        Server.currentHandlerContext?.httpContext?
        .header(HTTPHeaderName.sessionID) ?? "direct"
      return try await dispatcher.call(parameters, sessionID: sessionID)
    }
    return server
  }
}
