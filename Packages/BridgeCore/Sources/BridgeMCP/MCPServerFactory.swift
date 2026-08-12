import Logging
import MCP

public struct MCPServerFactory: Sendable {
  private let appVersion: String
  private let catalog: MCPToolCatalog
  private let dispatcher: MCPToolDispatcher

  public init(
    appVersion: String,
    queries: any BridgeMCPQueries,
    logger: Logger = Logger(label: "CodexBridge.BridgeMCP.Server")
  ) {
    precondition(!appVersion.isEmpty)
    self.appVersion = appVersion
    catalog = MCPToolCatalog()
    dispatcher = MCPToolDispatcher(
      queries: queries,
      admission: MCPToolAdmission(),
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
      instructions: "This server controls only user-approved local Codex projects. Always list "
        + "projects, threads, and models before starting a task. Never invent project IDs, "
        + "thread IDs, model IDs, or paths.",
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
