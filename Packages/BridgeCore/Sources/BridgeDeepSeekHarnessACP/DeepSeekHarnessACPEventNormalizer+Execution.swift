import BridgeAgentCore

extension DeepSeekHarnessACPEventNormalizer {
  func normalizeForExecution(
    _ clientEnvelope: DeepSeekHarnessACPClientEventEnvelope
  ) throws -> [AgentEventEnvelope] {
    var events: [AgentEventEnvelope] = []
    if case .toolUpdated = clientEnvelope.event,
      let finalizedContent = try finalizeCurrentContent()
    {
      events.append(finalizedContent)
    }
    if let event = try normalize(clientEnvelope) {
      events.append(event)
    }
    return events
  }
}
