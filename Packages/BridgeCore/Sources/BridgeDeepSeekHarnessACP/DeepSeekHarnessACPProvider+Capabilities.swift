import BridgeAgentCore

extension DeepSeekHarnessACPProvider {
  public static let capabilitySnapshot = AgentCapabilitySnapshot(
    advertised: [
      .sessionCreate,
      .interrupt,
      .steer,
      .textDelta,
      .workspaceRead,
      .workspaceWriteInPlace,
      .oneShotApproval,
      .structuredApprovalPayload,
      .modelSelection,
      .effortSelection,
    ],
    observed: [
      .sessionCreate,
      .interrupt,
      .steer,
      .textDelta,
      .workspaceRead,
      .workspaceWriteInPlace,
      .oneShotApproval,
      .structuredApprovalPayload,
      .modelSelection,
      .effortSelection,
    ],
    enforced: [
      .sessionCreate,
      .interrupt,
      .steer,
      .textDelta,
      .workspaceRead,
      .workspaceWriteInPlace,
      .oneShotApproval,
      .structuredApprovalPayload,
      .modelSelection,
      .effortSelection,
    ]
  )
}
