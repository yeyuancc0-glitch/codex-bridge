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
      snapshot.recentActivity.count <= eventLimit,
      snapshot.recentActivityAvailable || snapshot.recentActivity.isEmpty,
      snapshot.changedFiles.reduce(0, { $0 + $1.utf8.count }) <= 16 * 1_024,
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
        event.summary.utf8.count <= 1_024,
        OutboundContentSecurity.isSafe(event.summary)
      else {
        throw MCPToolAdapterError.invalidQueryOutput
      }
      prior = event.sequence
    }
    var priorActivity: Int64 = -1
    for activity in snapshot.recentActivity {
      guard activity.sequence > 0,
        activity.sequence > priorActivity,
        !activity.kind.isEmpty,
        OutboundContentSecurity.isSafe(activity.kind),
        activity.summary.utf8.count <= 768,
        OutboundContentSecurity.isSafe(activity.summary),
        !activity.occurredAt.isEmpty,
        activity.occurredAt.utf8.count <= 128,
        OutboundContentSecurity.isSafe(activity.occurredAt),
        activity.toolName.map({
          $0.utf8.count <= 256 && OutboundContentSecurity.isSafe($0)
        }) ?? true,
        activity.toolStatus.map({
          $0.utf8.count <= 64 && OutboundContentSecurity.isSafe($0)
        }) ?? true
      else {
        throw MCPToolAdapterError.invalidQueryOutput
      }
      priorActivity = activity.sequence
    }
  }

}
