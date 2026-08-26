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
    let instructions = await serverInstructions()
    let server = Server(
      name: "codex-bridge",
      version: appVersion,
      title: "Codex Bridge",
      instructions: instructions,
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

  private func serverInstructions() async -> String {
    let deadline = ContinuousClock().now.advanced(by: .seconds(5))
    let custom = try? await dispatcher.service.serviceCustomInstructions(
      deadline: deadline)
    return Self.instructions(
      customInstructions: custom ?? "",
      clientID: dispatcher.clientID
    )
  }

  package static func instructions(
    customInstructions: String,
    clientID _: MCPClientID
  ) -> String {
    instructions(customInstructions: customInstructions)
  }

  package static func instructions(customInstructions: String) -> String {
    let base =
      "This service exposes only user-approved local projects. List projects, "
      + "Threads and models before submitting work. Task submission never grants local "
      + "approval; the user must approve execution in the macOS App. When submitting a task, "
      + "omit execution_model, execution_effort, supervisor_model and supervisor_effort unless "
      + "the user explicitly requested a per-task override; Codex Bridge owns those defaults. "
      + "Set model_override to true only for such an explicit request. For OpenCode, "
      + "permission_mode selects native ACP Plan or Build, network access follows native "
      + "permissions and network_access does not override it. If permission_mode is omitted, "
      + "Bridge uses the saved OpenCode default mode; thread_id, skill_name, supervisor_model and supervisor_effort "
      + "must be omitted. OpenCode execution_effort is optional and must match a value advertised for the selected model."
    guard !customInstructions.isEmpty else { return base }
    return "The user's global custom instructions follow. Read and follow them before "
      + "calling any Codex Bridge tool, subject to the service's security and approval "
      + "boundaries:\n\n" + customInstructions + "\n\n" + base
  }
}
