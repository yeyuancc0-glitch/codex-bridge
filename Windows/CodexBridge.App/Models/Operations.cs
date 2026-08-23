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
    public bool CanToggleEnabled => ClientId == "qwen.studio";
    public bool CanManageCredential => CanToggleEnabled && Enabled;
    public bool CanChangeExposure => Enabled;
    public string EnabledAction => Enabled ? "停用" : "启用";
    public string ExposureAction => ExposureMode == "full" ? "改为只读" : "允许完整工具";
    public string State => Enabled ? $"{ExposureMode} · {ActiveSessionCount} 个活动会话" : "已停用";
}

public sealed record McpClientConfigurationExport(string ConfigurationJson);

public sealed record ModelCatalogResponse(
    IReadOnlyList<ModelSummary> Models,
    ModelPreferences Preferences);

public sealed record ModelSummary(
    string ModelId,
    string DisplayName,
    bool IsDefault,
    IReadOnlyList<string> ReasoningEfforts,
    string? DefaultReasoningEffort,
    IReadOnlyList<string> ServiceTiers,
    IReadOnlyList<string> AdditionalSpeedTiers)
{
    public string DisplayLabel => $"{DisplayName} · {ModelId}";
    public bool SupportsFastMode =>
        ServiceTiers.Contains("fast") || AdditionalSpeedTiers.Contains("fast");
}

public sealed record ModelPreferences(
    string ExecutionModel,
    string ExecutionEffort,
    string SupervisorModel,
    string SupervisorEffort,
    bool SupervisorEnabled,
    string AccessMode,
    bool FastModeEnabled);

public sealed record SelectionOption(string Value, string Label);

public sealed record TaskConversationPage(
    string TaskId,
    IReadOnlyList<TaskConversationMessage> Messages);

public sealed record TaskConversationMessage(
    long? MessageId,
    string Key,
    string Role,
    string Kind,
    string Content,
    string? ToolName,
    string? ToolStatus,
    string? ToolArguments,
    bool Final);
