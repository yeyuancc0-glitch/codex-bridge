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
      version: "\(appVersion)+mcp.\(MCPServiceToolCatalog.contractVersion)",
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
      + "permission_mode for ChatGPT and Qwen submissions to use the Workbench default task mode "
      + "shared by Codex, OpenCode, DeepSeek Harness, and Antigravity. If a client sends a default "
      + "permission_mode without permission_mode_override=true, Bridge treats it as an implicit "
      + "client default. Native ACP Plan/read-only or Build/workspace-write follows the Workbench "
      + "default for OpenCode. A permission_mode value only replaces it when "
      + "permission_mode_override=true and the user explicitly requested it. Network access follows native "
      + "permissions and network_access does not override it. For a new OpenCode conversation, "
      + "omit thread_id. To continue one, explicitly set provider_id to opencode and pass the "
      + "provider_session_id returned by get_task as thread_id. skill_name, supervisor_model and "
      + "supervisor_effort must be omitted. OpenCode execution_effort is optional and must match "
      + "a value advertised for the selected model. DeepSeek Harness must be selected explicitly "
      + "with provider_id=deepseek-harness and a verified installation; it supports fresh "
      + "sessions with provider-native read-only or workspace-write modes, so omit thread_id, "
      + "supervisor_model and supervisor_effort. Its optional execution_model and execution_effort "
      + "must match the selected model declared by the registered Harness profile. Its optional "
      + "skill_name is injected by Bridge when the user explicitly requests that Skill. Its "
      + "verified profile carries its native tool composition, so Web, network, MCP, file, command, "
      + "and subagent tasks may be routed to it when the registered installation exposes them. Its "
      + "execution-time permission requests are surfaced for local approval. DeepSeek steer input is "
      + "a queued follow-up on the same session, not real-time insertion. External Provider network "
      + "execution follows Provider-native policy; network_access records the explicit task request "
      + "without claiming Bridge-level packet isolation. Set network_access=true whenever the "
      + "user explicitly requests web search, URL fetches, external APIs, or other network use; "
      + "false or omitted does not grant task-level network access. "
      + "For Antigravity, explicitly set provider_id "
      + "to antigravity. It supports native plan/accept-edits modes: Plan/read-only (agy mode: plan) "
      + "and Accept Edits/workspace-write "
      + "(agy mode: accept-edits) in-place "
      + "modes, model and effort selection, exact continuation, and queued steer when list_agents "
      + "reports the matching effective capabilities. For ChatGPT and Qwen, an unmarked permission_mode "
      + "uses the Workbench default; any override requires permission_mode_override=true and an explicit user request. "
      + "Continue only with a provider_session_id returned by a terminal "
      + "Antigravity task for the same project and installation. An explicitly requested skill_name "
      + "is injected by Bridge. Antigravity does not support Supervisor. Network and sandboxed "
      + "tools follow agy's native headless policy; a provider permission denial is reported as task "
      + "failure. When local access mode is full-access and network_access=true, Bridge may use "
      + "agy's documented non-interactive approval flag while retaining agy's native sandbox and "
      + "the task's Plan/Accept Edits mode. Bridge still enforces task admission, the selected "
      + "project policy, and local start approval, but does not wrap Agent processes in a filesystem "
      + "or network sandbox. "
      + "Follow the wait_policy returned by submit_task and get_task: fast waits 120 seconds for "
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
