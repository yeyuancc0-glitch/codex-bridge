import BridgePresentation
import BridgeReporting
import BridgeTunnel
import Foundation

enum DesktopSupportBundle {
  static func build(
    diagnostics: [LogEntryPresentation],
    connection: DesktopTransportHealth,
    projectCount: Int,
    recentTaskCount: Int,
    generatedAt: Date = Date()
  ) throws -> Data {
    let diagnosticRecords = diagnostics.suffix(100).map { entry in
      AllowedSupportRecord(
        id: entry.id,
        source: .applicationDiagnostic,
        level: level(entry.severity),
        timestamp: entry.timestamp,
        summary: entry.message,
        fields: [SupportRecordField(key: "component", value: entry.source)]
      )
    }
    let connectionRecord = AllowedSupportRecord(
      id: "connection-status",
      source: .connectionStatus,
      level: connectionLevel(connection.lifecycle),
      timestamp: generatedAt,
      summary: "Codex Bridge connection state",
      fields: [
        SupportRecordField(key: "lifecycle", value: connection.lifecycle.rawValue),
        SupportRecordField(
          key: "accepts_remote_submissions",
          value: String(connection.acceptsRemoteSubmissions)
        ),
        SupportRecordField(key: "action_required", value: String(connection.actionRequired)),
        SupportRecordField(key: "registered_project_count", value: String(projectCount)),
        SupportRecordField(key: "recent_task_count", value: String(recentTaskCount)),
      ]
    )
    return try SupportBundleBuilder().build(
      from: SupportBundleInput(
        generatedAt: generatedAt,
        records: diagnosticRecords + [connectionRecord]
      )
    ).json
  }

  private static func level(_ status: PresentationStatus) -> SupportRecordLevel {
    switch status {
    case .checking, .ready, .running, .completed: .info
    case .waiting, .degraded, .disconnected, .paused: .warning
    case .blocked, .failed: .error
    }
  }

  private static func connectionLevel(_ lifecycle: TunnelLifecycle) -> SupportRecordLevel {
    switch lifecycle {
    case .stopped, .starting, .authenticating, .connecting, .ready: .info
    case .degraded: .warning
    case .failed: .error
    }
  }
}
