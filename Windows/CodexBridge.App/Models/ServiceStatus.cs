namespace CodexBridge.App.Models;

public sealed record ServiceStatusResponse(
    BridgeStatus Status,
    string? LocalMcpUrl,
    string ExposureMode,
    TunnelStatus Tunnel,
    string? WorkbenchProjectId);

public sealed record BridgeStatus(
    string AppVersion,
    string McpState,
    string TunnelState,
    string? CodexVersion,
    string? LoginMode,
    string ExecutionState,
    string SupervisorState,
    IReadOnlyList<string> Degradations,
    int PendingApprovalCount);

public sealed record TunnelStatus(
    bool Configured,
    bool Enabled,
    bool HelperAvailable,
    string? TunnelId,
    string Lifecycle,
    bool AcceptsRemoteSubmissions,
    bool ActionRequired);
