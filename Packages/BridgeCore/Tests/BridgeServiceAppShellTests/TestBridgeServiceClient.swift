import BridgeIPC
import BridgeMCP
import BridgeSkills
import Foundation

@testable import BridgeServiceAppShell

actor TestBridgeServiceClient: BridgeServiceClientProtocol {
  struct AgentModelsQuery: Equatable, Sendable {
    let installationID: String
    let projectID: String?
    let modelID: String?
    let useStoredDefault: Bool
  }

  struct MutationSnapshot: Sendable {
    let approvalDecisions: [String]
    let configuredTunnelIDs: [String]
    let tunnelDisconnectCount: Int
    let tunnelClearCount: Int
    let modelPreferences: IPCModelPreferences
    let customInstructions: String
  }

  private var closes = 0
  private var approvalDecisions: [String] = []
  private var exposureMode = MCPServiceExposureMode.readOnly
  private var tunnelStatus = IPCTunnelStatus.unconfigured
  private var configuredTunnelIDs: [String] = []
  private var tunnelDisconnectCount = 0
  private var tunnelClearCount = 0
  private var modelPreferencesValue = IPCModelPreferences(
    executionModel: "fixture-model",
    executionEffort: "medium",
    supervisorModel: "fixture-model",
    supervisorEffort: "medium"
  )
  private var customInstructionsValue = "Fixture global instructions"
  private let failModelCatalog: Bool
  private let failThreadList: Bool
  private var failSubscription = false
  private var threadListCalls = 0
  private var threadReadCalls = 0
  private var skillsValue: [MCPServiceSkill] = []
  private var deletedTaskIDs: [String] = []
  private var subscribeCalls = 0
  private var unsubscribedSubscriptionIDs: [Int] = []
  private var pushContinuations: [AsyncStream<IPCTaskConversationPush>.Continuation] = []
  private var subscriptionPage = IPCTaskConversationPage(
    taskID: "task-1",
    messages: [
      IPCTaskConversationMessage(
        messageID: nil,
        key: "user:1",
        role: "user",
        content: "hello"
      )
    ]
  )
  private var conversationPages: [TaskConversationQuery: IPCTaskConversationPage] = [:]
  private var workbenchProjectSelections: [String?] = []
  private var taskSnapshotsValue: [MCPServiceTaskSnapshot]?
  private var taskControlActions: [String] = []
  private var approvalsValue: [IPCApprovalSummary] = [
    IPCApprovalSummary(
      approvalID: "approval-1",
      taskID: "task-1",
      threadID: "thread-1",
      turnID: "turn-1",
      itemID: "item-1",
      kind: "command",
      title: "Run command",
      summary: "Run a bounded command."
    )
  ]
  private var agentInstallationsValue: [IPCAgentInstallationSummary] = []
  private var agentActions: [String] = []
  private var agentModelOptionsValue: [IPCAgentModelSummary] = []
  private var agentModelOptionsByInstallation: [String: [IPCAgentModelSummary]] = [:]
  private var agentModelDefaultValue: String?
  private var agentModelDefaultPermissionMode = "build"
  private var agentModelDefaultEffort: String?
  private var agentModelDefaultWrites: [String?] = []
  private var agentDefaultsByProvider: [String: IPCAgentModelDefaultResponse] = [:]
  private var agentModelDefaultReadDelay: Duration = .zero
  private var agentModelDefaultReadDelaysByProvider: [String: Duration] = [:]
  private var agentModelDefaultReadCount = 0
  private var agentModelDefaultReadCountsByProvider: [String: Int] = [:]
  private var agentModelRequestCount = 0
  private var agentModelsQueries: [AgentModelsQuery] = []
  private var failAgentModels = false
  private var submittedAgentRequestValue: IPCAgentSubmitRequest?
  private var registrationRequestValue: IPCAgentRegistrationRequest?
  private var approvalResolutionDelay: Duration = .zero
  private var failApprovalReplyAfterResolution = false
  private let agentProvidersValue = [
    IPCAgentProviderSummary(
      providerID: "opencode",
      displayName: "OpenCode",
      adapterRevision: 1,
      supportsSteer: true
    )
  ]

  struct TaskConversationQuery: Hashable {
    let taskID: String
    let beforeMessageID: Int64?

    init(_ request: IPCTaskConversationRequest) {
      taskID = request.taskID
      beforeMessageID = request.beforeMessageID
    }
  }

  init(failModelCatalog: Bool = false, failThreadList: Bool = false) {
    self.failModelCatalog = failModelCatalog
    self.failThreadList = failThreadList
  }

  func setFailSubscription(_ fail: Bool) {
    failSubscription = fail
  }

  func setSubscriptionPage(_ page: IPCTaskConversationPage) {
    subscriptionPage = page
  }

  func setConversationPages(_ pages: [TaskConversationQuery: IPCTaskConversationPage]) {
    conversationPages = pages
  }

  func setTaskSnapshots(_ snapshots: [MCPServiceTaskSnapshot]) {
    taskSnapshotsValue = snapshots
  }

  func setSkills(_ names: [String]) {
    skillsValue = names.map {
      MCPServiceSkill(
        manifest: SkillManifest(
          name: $0,
          description: "Fixture skill",
          scope: .global,
          rootPath: "/fixture/\($0)"
        ))
    }
  }

  func configureAgentModels(
    _ models: [IPCAgentModelSummary],
    installationID: String? = nil,
    fail: Bool = false
  ) {
    if let installationID {
      agentModelOptionsByInstallation[installationID] = models
    } else {
      agentModelOptionsValue = models
    }
    failAgentModels = fail
  }

  func configureAgentInstallations(_ installations: [IPCAgentInstallationSummary]) {
    agentInstallationsValue = installations
  }

  func configureAgentDefault(_ model: String?) {
    agentModelDefaultValue = model
  }

  func configureOpenCodeDefault(
    model: String?,
    permissionMode: String,
    effort: String?
  ) {
    agentModelDefaultValue = model
    agentModelDefaultPermissionMode = permissionMode
    agentModelDefaultEffort = effort
  }

  func setAgentDefaultReadDelay(_ delay: Duration) {
    agentModelDefaultReadDelay = delay
  }

  func setAgentDefaultReadDelay(_ delay: Duration, providerID: String) {
    agentModelDefaultReadDelaysByProvider[providerID] = delay
  }

  func agentModelDefaultReadCountValue() -> Int {
    agentModelDefaultReadCount
  }

  func agentModelDefaultReadCountValue(providerID: String) -> Int {
    agentModelDefaultReadCountsByProvider[providerID, default: 0]
  }

  func setAgentModelsFailure(_ fail: Bool) {
    failAgentModels = fail
  }

  func agentModelRequestCountValue() -> Int {
    agentModelRequestCount
  }

  func agentModelsQueriesValue() -> [AgentModelsQuery] {
    agentModelsQueries
  }

  func setApprovalResolutionDelay(_ delay: Duration) {
    approvalResolutionDelay = delay
  }

  func setFailApprovalReplyAfterResolution(_ fail: Bool) {
    failApprovalReplyAfterResolution = fail
  }

  func agentDefaultWrites() -> [String?] {
    agentModelDefaultWrites
  }

  func submittedAgentRequest() -> IPCAgentSubmitRequest? {
    submittedAgentRequestValue
  }

  func registrationRequest() -> IPCAgentRegistrationRequest? {
    registrationRequestValue
  }

  func status() async throws -> IPCServiceStatusResponse {
    IPCServiceStatusResponse(
      status: BridgeStatusSnapshot(
        appVersion: "test",
        mcpState: "ready",
        tunnelState: "stopped",
        executionState: "ready",
        supervisorState: "ready",
        pendingApprovalCount: 1
      ),
      localMCPURL: "http://127.0.0.1:1234/mcp",
      exposureMode: exposureMode,
      tunnel: tunnelStatus
    )
  }

  func projects() async throws -> [MCPProjectSummary] {
    [
      MCPProjectSummary(
        projectID: "project-1",
        name: "Fixture",
        capabilities: MCPProjectCapabilities(
          read: "allowed",
          write: "requiresLocalApproval",
          network: "denied"
        )
      )
    ]
  }

  func registerProject(_ request: IPCProjectRegistrationRequest) async throws -> MCPProjectDetail {
    MCPProjectDetail(
      projectID: "project-1",
      name: request.name,
      capabilities: MCPProjectCapabilities(
        read: request.readPermission,
        write: request.writePermission,
        network: request.networkPermission
      )
    )
  }

  func updateProjectPolicy(_ request: IPCProjectPolicyRequest) async throws -> MCPProjectDetail {
    MCPProjectDetail(
      projectID: request.projectID,
      name: "Fixture",
      capabilities: MCPProjectCapabilities(
        read: request.readPermission,
        write: request.writePermission,
        network: request.networkPermission
      )
    )
  }

  func customInstructions() async throws -> String {
    customInstructionsValue
  }

  func setCustomInstructions(_ instructions: String) async throws {
    customInstructionsValue = instructions
  }

  func removeProject(projectID _: String) async throws {}

  func projectCommands(projectID: String) async throws -> MCPProjectDetail {
    MCPProjectDetail(
      projectID: projectID,
      name: "Fixture",
      capabilities: MCPProjectCapabilities(
        read: "allowed",
        write: "requiresLocalApproval",
        network: "denied"
      ),
      directWorkspace: MCPDirectWorkspace(
        fileWritePermission: "requiresLocalApproval",
        commandMode: "safe",
        commands: [
          MCPProjectCommand(
            commandID: "wcmd-test",
            name: "Tests",
            executable: "Scripts/with-xcode.sh",
            arguments: ["swift", "test"]
          )
        ]
      )
    )
  }

  func updateProjectCommands(
    projectID: String,
    commands: [IPCWorkspaceCommand],
    commandBlacklist: [IPCBlacklistRule] = []
  ) async throws -> MCPProjectDetail {
    MCPProjectDetail(
      projectID: projectID,
      name: "Fixture",
      capabilities: MCPProjectCapabilities(
        read: "allowed",
        write: "requiresLocalApproval",
        network: "denied"
      ),
      directWorkspace: MCPDirectWorkspace(
        fileWritePermission: "requiresLocalApproval",
        commandMode: "safe",
        commands: commands.map {
          MCPProjectCommand(
            commandID: $0.commandID,
            name: $0.name,
            executable: $0.executable,
            arguments: $0.arguments,
            workingDirectory: $0.workingDirectory,
            requiresNetwork: $0.requiresNetwork,
            risk: $0.risk
          )
        },
        commandBlacklist: commandBlacklist.map {
          MCPCommandBlacklistRule(
            ruleID: $0.ruleID,
            executable: $0.executable,
            pattern: $0.pattern
          )
        }
      )
    )
  }

  func setProjectCommandMode(
    projectID: String,
    commandMode: String
  ) async throws -> MCPProjectDetail {
    MCPProjectDetail(
      projectID: projectID,
      name: "Fixture",
      capabilities: MCPProjectCapabilities(
        read: "allowed",
        write: "requiresLocalApproval",
        network: "denied"
      ),
      directWorkspace: MCPDirectWorkspace(
        fileWritePermission: "requiresLocalApproval",
        commandMode: commandMode,
        commands: []
      )
    )
  }

  func setWorkbenchProject(projectID: String?) async throws {
    workbenchProjectSelections.append(projectID)
  }

  func workbenchProjectSelectionsValue() -> [String?] {
    workbenchProjectSelections
  }

  func agentCatalog() async throws -> IPCAgentCatalogResponse {
    IPCAgentCatalogResponse(
      providers: agentProvidersValue,
      installations: agentInstallationsValue
    )
  }

  func registerAgentInstallation(
    _ request: IPCAgentRegistrationRequest
  ) async throws -> IPCAgentInstallationSummary {
    registrationRequestValue = request
    let installation = makeAgentInstallation(
      installationID: "agent-installation-1",
      displayName: request.displayName,
      executablePath: request.executablePath,
      isEnabled: false
    )
    agentInstallationsValue = [installation]
    agentActions.append("register:\(request.providerID)")
    return installation
  }

  func reprobeAgentInstallation(
    installationID: String,
    acceptReplacement: Bool
  ) async throws -> IPCAgentInstallationSummary {
    agentActions.append("reprobe:\(installationID):\(acceptReplacement)")
    guard
      let existing = agentInstallationsValue.first(where: {
        $0.installationID == installationID
      })
    else {
      throw BridgeServiceClientError.responseFailed
    }
    let installation = makeAgentInstallation(
      installationID: existing.installationID,
      displayName: existing.displayName,
      executablePath: existing.executablePath,
      isEnabled: existing.isEnabled
    )
    agentInstallationsValue = [installation]
    return installation
  }

  func setAgentInstallationEnabled(
    installationID: String,
    enabled: Bool
  ) async throws -> IPCAgentInstallationSummary {
    agentActions.append("enabled:\(installationID):\(enabled)")
    guard
      let existing = agentInstallationsValue.first(where: {
        $0.installationID == installationID
      })
    else {
      throw BridgeServiceClientError.responseFailed
    }
    let installation = makeAgentInstallation(
      installationID: existing.installationID,
      displayName: existing.displayName,
      executablePath: existing.executablePath,
      isEnabled: enabled
    )
    agentInstallationsValue = [installation]
    return installation
  }

  func removeAgentInstallation(installationID: String) async throws {
    agentActions.append("remove:\(installationID)")
    agentInstallationsValue.removeAll { $0.installationID == installationID }
  }

  func submitAgentTask(
    _ request: IPCAgentSubmitRequest
  ) async throws -> IPCAgentSubmitResponse {
    submittedAgentRequestValue = request
    agentActions.append("submit:\(request.providerID):\(request.model ?? "default")")
    return IPCAgentSubmitResponse(taskID: "tsk-test-agent", status: "awaiting_local_approval")
  }

  func agentModels(installationID: String) async throws -> IPCAgentModelsResponse {
    try await agentModels(
      installationID: installationID,
      projectID: nil,
      modelID: nil,
      useStoredDefault: true
    )
  }

  func agentModels(
    installationID: String,
    projectID: String?,
    modelID: String?,
    useStoredDefault: Bool
  ) async throws -> IPCAgentModelsResponse {
    agentModelRequestCount += 1
    agentModelsQueries.append(
      AgentModelsQuery(
        installationID: installationID,
        projectID: projectID,
        modelID: modelID,
        useStoredDefault: useStoredDefault
      )
    )
    guard !failAgentModels else { throw BridgeServiceClientError.unavailable }
    return IPCAgentModelsResponse(
      models: agentModelOptionsByInstallation[installationID] ?? agentModelOptionsValue
    )
  }

  func agentModelDefault() async throws -> IPCAgentModelDefaultResponse {
    agentModelDefaultReadCount += 1
    let value = agentModelDefaultValue
    let delay = agentModelDefaultReadDelaysByProvider["opencode"] ?? agentModelDefaultReadDelay
    if delay > .zero {
      try await Task.sleep(for: delay)
    }
    return IPCAgentModelDefaultResponse(
      model: value,
      permissionMode: agentModelDefaultPermissionMode,
      effort: agentModelDefaultEffort
    )
  }

  func agentModelDefault(providerID: String) async throws -> IPCAgentModelDefaultResponse {
    if providerID == "opencode" { return try await agentModelDefault() }
    agentModelDefaultReadCountsByProvider[providerID, default: 0] += 1
    if let delay = agentModelDefaultReadDelaysByProvider[providerID], delay > .zero {
      try await Task.sleep(for: delay)
    }
    return agentDefaultsByProvider[providerID]
      ?? IPCAgentModelDefaultResponse(
        providerID: providerID, model: nil, permissionMode: "read-only")
  }

  func setAgentModelDefault(_ model: String?) async throws {
    agentModelDefaultValue = model
    agentModelDefaultWrites.append(model)
  }

  func setOpenCodeDefaults(
    model: String?,
    permissionMode: String?,
    effort: String?
  ) async throws -> IPCAgentModelDefaultResponse {
    agentModelDefaultValue = model
    agentModelDefaultPermissionMode = permissionMode ?? agentModelDefaultPermissionMode
    agentModelDefaultEffort = effort
    agentModelDefaultWrites.append(model)
    return IPCAgentModelDefaultResponse(
      model: model,
      permissionMode: agentModelDefaultPermissionMode,
      effort: effort
    )
  }

  func setAgentDefaults(
    providerID: String,
    model: String?,
    permissionMode: String?,
    effort: String?
  ) async throws -> IPCAgentModelDefaultResponse {
    if providerID == "opencode" {
      return try await setOpenCodeDefaults(
        model: model,
        permissionMode: permissionMode,
        effort: effort
      )
    }
    let response = IPCAgentModelDefaultResponse(
      providerID: providerID,
      model: model,
      permissionMode: permissionMode ?? "read-only",
      effort: effort
    )
    agentDefaultsByProvider[providerID] = response
    return response
  }

  func agentActionsValue() -> [String] {
    agentActions
  }

  func models() async throws -> MCPModelList {
    MCPModelList(
      models: [
        MCPModelSummary(
          modelID: "fixture-model",
          displayName: "Fixture Model",
          isDefault: true,
          reasoningEfforts: ["low", "medium"],
          defaultReasoningEffort: "medium"
        )
      ]
    )
  }

  func skills(projectID _: String) async throws -> MCPServiceSkillList {
    MCPServiceSkillList(skills: skillsValue)
  }

  func modelCatalog() async throws -> IPCModelCatalogResponse {
    if failModelCatalog {
      throw BridgeServiceClientError.unavailable
    }
    let catalog = try await models()
    return IPCModelCatalogResponse(
      models: catalog.models,
      preferences: modelPreferencesValue
    )
  }

  func modelPreferences() async throws -> IPCModelPreferences {
    modelPreferencesValue
  }

  func setModelPreferences(_ preferences: IPCModelPreferences) async throws {
    modelPreferencesValue = preferences
  }

  func setSupervisorEnabled(_ enabled: Bool) async throws {
    modelPreferencesValue = IPCModelPreferences(
      executionModel: modelPreferencesValue.executionModel,
      executionEffort: modelPreferencesValue.executionEffort,
      supervisorModel: modelPreferencesValue.supervisorModel,
      supervisorEffort: modelPreferencesValue.supervisorEffort,
      supervisorEnabled: enabled,
      accessMode: modelPreferencesValue.accessMode,
      fastModeEnabled: modelPreferencesValue.fastModeEnabled
    )
  }

  func threads(_ request: IPCThreadListRequest) async throws -> MCPThreadPage {
    threadListCalls += 1
    if failThreadList { throw BridgeServiceClientError.unavailable }
    return MCPThreadPage(
      threads: [
        MCPThreadSummary(
          threadID: "thread-1",
          title: "Fixture Thread",
          status: "idle"
        )
      ]
    )
  }

  func readThread(_ request: IPCThreadReadRequest) async throws -> MCPThreadReadPage {
    threadReadCalls += 1
    return MCPThreadReadPage(
      thread: MCPThreadSummary(
        threadID: request.threadID,
        title: "Fixture Thread",
        status: "idle"
      ),
      detail: request.detail,
      entries: []
    )
  }

  func tasks(_ request: IPCTaskListRequest) async throws -> [MCPServiceTaskSnapshot] {
    _ = request
    return taskSnapshotsValue ?? [taskSnapshot()]
  }

  func task(_ request: IPCTaskRequest) async throws -> MCPServiceTaskSnapshot {
    _ = request
    return taskSnapshot()
  }

  func stopTask(taskID _: String) async throws {}

  func steerTask(
    taskID: String,
    expectedTurnID: String,
    input: String
  ) async throws -> MCPServiceTaskMutationReceipt {
    taskControlActions.append("steer:\(taskID):\(expectedTurnID):\(input)")
    return MCPServiceTaskMutationReceipt(
      taskID: taskID,
      status: "running",
      accepted: true
    )
  }

  func interruptTask(
    taskID: String,
    expectedTurnID: String
  ) async throws -> MCPServiceTaskMutationReceipt {
    taskControlActions.append("interrupt:\(taskID):\(expectedTurnID)")
    return MCPServiceTaskMutationReceipt(
      taskID: taskID,
      status: "interrupted",
      accepted: true
    )
  }

  func taskControlActionsValue() -> [String] {
    taskControlActions
  }

  func deleteTask(taskID: String) async throws {
    deletedTaskIDs.append(taskID)
  }

  func deletedTaskIDsValue() -> [String] {
    deletedTaskIDs
  }

  func taskConversation(
    _ request: IPCTaskConversationRequest
  ) async throws -> IPCTaskConversationPage {
    conversationPages[TaskConversationQuery(request)]
      ?? IPCTaskConversationPage(taskID: request.taskID, messages: [])
  }

  func subscribeTaskConversation(
    taskID: String,
    limit _: Int
  ) async throws -> (IPCTaskConversationSubscription, AsyncStream<IPCTaskConversationPush>) {
    subscribeCalls += 1
    if failSubscription {
      throw BridgeServiceClientError.unavailable
    }
    let (stream, continuation) = AsyncStream.makeStream(of: IPCTaskConversationPush.self)
    pushContinuations.append(continuation)
    return (
      IPCTaskConversationSubscription(subscriptionID: 7, page: subscriptionPage),
      stream
    )
  }

  func subscribeCallsValue() -> Int {
    subscribeCalls
  }

  func pushConversation(_ push: IPCTaskConversationPush) {
    pushContinuations.last?.yield(push)
  }

  func unsubscribeTaskConversation(taskID _: String, subscriptionID: Int) async throws {
    unsubscribedSubscriptionIDs.append(subscriptionID)
  }

  func unsubscribedSubscriptionIDsValue() -> [Int] {
    unsubscribedSubscriptionIDs
  }

  func approvals(taskID _: String?) async throws -> [IPCApprovalSummary] {
    approvalsValue
  }

  func resolveApproval(_ request: IPCApprovalResolutionRequest) async throws {
    if approvalResolutionDelay > .zero {
      try await Task.sleep(for: approvalResolutionDelay)
    }
    approvalDecisions.append("\(request.approvalID):\(request.decision)")
    approvalsValue.removeAll { $0.approvalID == request.approvalID }
    if failApprovalReplyAfterResolution {
      throw BridgeServiceClientError.unavailable
    }
  }

  private var directApprovalDecisions: [String] = []
  private var directApprovalsValue: [IPCPendingDirectApproval] = [
    IPCPendingDirectApproval(
      approvalID: "direct-approval-1",
      projectID: "prj-1",
      kind: "command",
      summary: "Run swift test",
      createdAt: Date()
    )
  ]

  func pendingDirectApprovals() async throws -> [IPCPendingDirectApproval] {
    directApprovalsValue
  }

  func approveDirectApproval(approvalID: String) async throws -> Bool {
    directApprovalDecisions.append("approve:\(approvalID)")
    directApprovalsValue = directApprovalsValue.filter { $0.approvalID != approvalID }
    return true
  }

  func denyDirectApproval(approvalID: String) async throws -> Bool {
    directApprovalDecisions.append("deny:\(approvalID)")
    directApprovalsValue = directApprovalsValue.filter { $0.approvalID != approvalID }
    return true
  }

  private var directApprovalModeValue = "require"

  func directApprovalMode() async throws -> String {
    directApprovalModeValue
  }

  func setDirectApprovalMode(_ mode: String) async throws {
    directApprovalModeValue = mode
  }

  func setExposureMode(_ mode: MCPServiceExposureMode) async throws {
    exposureMode = mode
  }

  func configureTunnel(
    _ request: IPCTunnelConfigurationRequest
  ) async throws -> IPCTunnelStatus {
    configuredTunnelIDs.append(request.tunnelID)
    tunnelStatus = IPCTunnelStatus(
      configured: true,
      enabled: true,
      helperAvailable: true,
      tunnelID: request.tunnelID,
      lifecycle: "ready",
      acceptsRemoteSubmissions: true,
      actionRequired: false
    )
    return tunnelStatus
  }

  func connectTunnel() async throws -> IPCTunnelStatus {
    tunnelStatus = IPCTunnelStatus(
      configured: tunnelStatus.configured,
      enabled: true,
      helperAvailable: tunnelStatus.helperAvailable,
      tunnelID: tunnelStatus.tunnelID,
      lifecycle: "ready",
      acceptsRemoteSubmissions: true,
      actionRequired: false
    )
    return tunnelStatus
  }

  func disconnectTunnel() async throws {
    tunnelDisconnectCount += 1
    tunnelStatus = IPCTunnelStatus(
      configured: tunnelStatus.configured,
      enabled: false,
      helperAvailable: tunnelStatus.helperAvailable,
      tunnelID: tunnelStatus.tunnelID,
      lifecycle: "stopped",
      acceptsRemoteSubmissions: false,
      actionRequired: false
    )
  }

  func clearTunnel() async throws {
    tunnelClearCount += 1
    tunnelStatus = .unconfigured
  }

  func close() async {
    closes += 1
  }

  func closeCount() -> Int {
    closes
  }

  func threadCallCounts() -> (list: Int, read: Int) {
    (threadListCalls, threadReadCalls)
  }

  func mutationSnapshot() -> MutationSnapshot {
    MutationSnapshot(
      approvalDecisions: approvalDecisions,
      configuredTunnelIDs: configuredTunnelIDs,
      tunnelDisconnectCount: tunnelDisconnectCount,
      tunnelClearCount: tunnelClearCount,
      modelPreferences: modelPreferencesValue,
      customInstructions: customInstructionsValue
    )
  }

  private func makeAgentInstallation(
    installationID: String,
    displayName: String,
    executablePath: String,
    isEnabled: Bool
  ) -> IPCAgentInstallationSummary {
    IPCAgentInstallationSummary(
      installationID: installationID,
      providerID: "opencode",
      displayName: displayName,
      executablePath: executablePath,
      version: "1.18.22",
      protocolRevision: "1",
      adapterRevision: 1,
      trustProfile: "managed",
      securityProfileID: "controlled-readonly",
      isEnabled: isEnabled,
      availability: "available",
      effectiveCapabilities: ["workspace.read"],
      lastProbedAt: "2026-08-25T00:00:00Z",
      updatedAt: "2026-08-25T00:00:00Z"
    )
  }

  private func taskSnapshot() -> MCPServiceTaskSnapshot {
    MCPServiceTaskSnapshot(
      taskID: "task-1",
      projectID: "project-1",
      status: "awaiting_local_approval",
      supervisorStatus: "starting",
      localApprovalRequired: true,
      updatedAt: "2026-08-17T00:00:00Z"
    )
  }
}
