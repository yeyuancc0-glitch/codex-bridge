namespace CodexBridge.App.Models;

public sealed record ProjectListResponse(IReadOnlyList<ProjectSummary> Projects);

public sealed record ProjectSummary(
    string ProjectId,
    string Name,
    ProjectCapabilities Capabilities,
    string? GitState);

public sealed record ProjectCapabilities(string Read, string Write, string Network)
{
    public string Summary => $"读 {Read} · 写 {Write} · 网络 {Network}";
}

public sealed record TaskListResponse(IReadOnlyList<TaskSummary> Tasks);

public sealed record TaskSummary(
    string TaskId,
    string ProjectId,
    string? Source,
    string? SourceClientId,
    string Status,
    string? ThreadId,
    string? TurnId,
    string? CurrentStep,
    IReadOnlyList<string> ChangedFiles,
    IReadOnlyList<TaskEvent> RecentEvents,
    string SupervisorStatus,
    string? SupervisorSummary,
    bool LocalApprovalRequired,
    string? ResultSummary,
    string? FailureCode,
    string UpdatedAt);

public sealed record TaskEvent(long Seq, string Kind, string Summary, string OccurredAt);

public sealed record ApprovalListResponse(IReadOnlyList<ApprovalSummary> Approvals);

public sealed record ApprovalSummary(
    string ApprovalId,
    string TaskId,
    string ThreadId,
    string TurnId,
    string ItemId,
    string Kind,
    string Title,
    string Summary,
    string? DisplayCommand,
    IReadOnlyList<string> RelativePaths,
    string? Reason);

public sealed record DirectApprovalListResponse(IReadOnlyList<DirectApprovalSummary> Approvals);

public sealed record DirectApprovalSummary(
    string ApprovalId,
    string ProjectId,
    string Kind,
    string Summary,
    DateTimeOffset CreatedAt);

public sealed record McpClientListResponse(IReadOnlyList<McpClientStatus> Clients);

public sealed record McpClientStatus(
    string ClientId,
    string DisplayName,
    bool Enabled,
    string ExposureMode,
    int ActiveSessionCount,
    string? LastConnectedAt)
{
    public string State => Enabled ? $"{ExposureMode} · {ActiveSessionCount} 个活动会话" : "已停用";
}
