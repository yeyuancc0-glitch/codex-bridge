import BridgeFiles
import BridgeSecurity
import Foundation
import MCP

extension MCPServiceToolDispatcher {
  func validate(
    _ snapshot: MCPServiceTaskSnapshot,
    requestedTaskID: String,
    eventLimit: Int
  ) throws {
    guard snapshot.taskID == requestedTaskID,
      !snapshot.projectID.isEmpty,
      !snapshot.status.isEmpty,
      !snapshot.supervisorStatus.isEmpty,
      snapshot.recentEvents.count <= eventLimit,
      snapshot.changedFiles.allSatisfy({
        OutboundContentSecurity.isSafeOutboundRelativePath($0)
      }),
      snapshot.currentStep.map(OutboundContentSecurity.isSafe) ?? true,
      snapshot.supervisorSummary.map(OutboundContentSecurity.isSafe) ?? true,
      snapshot.resultSummary.map(OutboundContentSecurity.isSafe) ?? true
    else {
      throw MCPToolAdapterError.invalidQueryOutput
    }
    var prior: Int64 = -1
    for event in snapshot.recentEvents {
      guard event.sequence > prior,
        !event.kind.isEmpty,
        OutboundContentSecurity.isSafe(event.summary)
      else {
        throw MCPToolAdapterError.invalidQueryOutput
      }
      prior = event.sequence
    }
  }

}
