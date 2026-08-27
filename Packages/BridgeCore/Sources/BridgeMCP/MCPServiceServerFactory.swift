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
      + "Set model_override to true only for such an explicit request. For OpenCode, omit "
      + "permission_mode unless the user explicitly asks for native ACP Plan/read-only or Build/workspace-write; "
      + "only then set permission_mode_override=true. Unmarked permission_mode values are ignored "
      + "and Bridge uses the saved OpenCode default mode. Network access follows native "
      + "permissions and network_access does not override it. For a new OpenCode conversation, "
      + "omit thread_id. To continue one, explicitly set provider_id to opencode and pass the "
      + "provider_session_id returned by get_task as thread_id. skill_name, supervisor_model and "
      + "supervisor_effort must be omitted. OpenCode execution_effort is optional and must match "
      + "a value advertised for the selected model."
      + " Follow the wait_policy returned by submit_task and get_task: fast waits 120 seconds for "
      + "approval, standard waits 300 seconds for active work (the default), and deep waits 600 "
      + "seconds for quiet long-running work. Do not call get_task before the returned "
      + "recommended_poll_after_seconds unless the user explicitly asks. A non-terminal status, "
      + "unchanged updated_at, or empty recent_activity never proves failure; only a terminal "
      + "status is authoritative. Use diagnostic_after_quiet_seconds only to trigger a diagnostic "
      + "check, never to fail or resubmit a task. Never report an operation as executed unless "
      + "the corresponding tool call returned an authoritative receipt. A provider task requires "
      + "a provider_task receipt with task_id; a Direct command requires a direct_command receipt "
      + "with session_id or terminal command result; a Git commit requires a git_commit receipt; "
      + "and a file mutation requires a file_mutation receipt. A planned, attempted, skipped, "
      + "not-invoked, or receipt-less action must never be described as completed or submitted."
      + " A git_commit receipt proves the call completed; only a non-null commit_hash proves that "
      + "a new commit was created."
    guard !customInstructions.isEmpty else { return base }
    return "The user's global custom instructions follow. Read and follow them before "
      + "calling any Codex Bridge tool, subject to the service's security and approval "
      + "boundaries:\n\n" + customInstructions + "\n\n" + base
  }
}
