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
    clientID: MCPClientID = .chatGPT,
    logger: Logger = Logger(label: "CodexBridge.BridgeMCP.LightweightServer")
  ) {
    precondition(!appVersion.isEmpty)
    self.appVersion = appVersion
    catalog = MCPServiceToolCatalog(exposureMode: exposureMode)
    dispatcher = MCPServiceToolDispatcher(
      service: service,
      exposureMode: exposureMode,
      clientID: clientID,
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
        + "approval; the user must approve execution in the macOS App. When submitting a task, "
        + "omit execution_model, execution_effort, supervisor_model and supervisor_effort unless "
        + "the user explicitly requested a per-task override; Codex Bridge owns those defaults. "
        + "Set model_override to true only for such an explicit request.",
      capabilities: .init(tools: .init(listChanged: false)),
      configuration: .default
    )
    await server.withMethodHandler(ListTools.self) { parameters in
      guard parameters.cursor == nil || parameters.cursor?.isEmpty == true else {
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
