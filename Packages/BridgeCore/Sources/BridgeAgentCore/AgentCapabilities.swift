import Foundation

public enum AgentCapability: String, Codable, CaseIterable, Hashable, Sendable {
  case sessionCreate = "lifecycle.session_create"
  case sessionContinue = "lifecycle.session_continue"
  case interrupt = "lifecycle.interrupt"
  case steer = "lifecycle.steer"
  case steerInterruptAndContinue = "lifecycle.steer_interrupt_and_continue"
  case textDelta = "presentation.text_delta"
  case reasoningDelta = "presentation.reasoning_delta"
  case toolLifecycle = "presentation.tool_lifecycle"
  case plan = "presentation.plan"
  case usage = "presentation.usage"
  case childRuns = "presentation.child_runs"
  case oneShotApproval = "approval.one_shot"
  case sessionRuleApproval = "approval.session_rule"
  case structuredApprovalPayload = "approval.structured_payload"
  case workspaceRead = "workspace.read"
  case workspaceWriteInPlace = "workspace.write_in_place"
  case workspaceWriteIsolated = "workspace.write_isolated"
  case modelSelection = "selection.model"
  case effortSelection = "selection.effort"
  case profileSelection = "selection.profile"
  case structuredOutput = "selection.structured_output"
  case shell = "tools.shell"
  case webSearch = "tools.web_search"
  case webFetch = "tools.web_fetch"
  case codeExecution = "tools.code_execution"
  case mcpClient = "tools.mcp_client"
  case subagents = "tools.subagents"
  case workflow = "tools.workflow"
  case skills = "tools.skills"
}

public struct AgentCapabilitySnapshot: Codable, Equatable, Sendable {
  public let advertised: Set<AgentCapability>
  public let observed: Set<AgentCapability>
  public let enforced: Set<AgentCapability>

  public init(
    advertised: Set<AgentCapability>,
    observed: Set<AgentCapability>,
    enforced: Set<AgentCapability>
  ) {
    self.advertised = advertised
    self.observed = observed
    self.enforced = enforced
  }

  public var effective: Set<AgentCapability> {
    advertised.intersection(observed).intersection(enforced)
  }

  public func supports(_ required: Set<AgentCapability>) -> Bool {
    effective.isSuperset(of: required)
  }

  public static let empty = AgentCapabilitySnapshot(
    advertised: [],
    observed: [],
    enforced: []
  )
}

public enum AgentMutationIntent: String, Codable, CaseIterable, Sendable {
  case readOnly = "read_only"
  case workspaceWrite = "workspace_write"
}

public enum AgentWorkspaceStrategy: String, Codable, CaseIterable, Sendable {
  case sharedProject = "shared_project"
  case exclusiveProject = "exclusive_project"
  case isolatedGitWorktree = "isolated_git_worktree"
}

public enum AgentTrustProfile: String, Codable, CaseIterable, Sendable {
  case managed
  case userTrusted = "user_trusted"
}
