namespace CodexBridge.App.Models;

public sealed record ProjectListResponse(IReadOnlyList<ProjectSummary> Projects);

public sealed record ProjectSummary(
    string ProjectId,
    string Name,
    ProjectCapabilities Capabilities,
    string? GitState)
{
    public string PolicyAutomationName => $"编辑 {Name} 的权限";
    public string ManageAutomationName => $"管理 {Name} 的 Direct 命令、Threads 和 Skills";
    public string RemoveAutomationName => $"移除项目 {Name}";
}

public sealed record ProjectDetail(
    string ProjectId,
    string Name,
    ProjectCapabilities Capabilities,
    string? GitState,
    IReadOnlyList<string> VerificationCommands,
    int? ThreadCount,
    DirectWorkspace? DirectWorkspace);

public sealed record DirectWorkspace(
    string FileWritePermission,
    string CommandMode,
    IReadOnlyList<ProjectCommand> Commands,
    IReadOnlyList<CommandBlacklistRule> CommandBlacklist);

public sealed record ProjectCommand(
    string CommandId,
    string Name,
    string Executable,
    IReadOnlyList<string> Arguments,
    string? WorkingDirectory,
    bool RequiresNetwork,
    string Risk);

public sealed record CommandBlacklistRule(
    string RuleId,
    string? Executable,
    string? Pattern);

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
    string UpdatedAt)
{
    public string DetailsAutomationName => $"查看任务 {TaskId} 的详情";
    public string StopAutomationName => $"停止任务 {TaskId}";
    public string DeleteAutomationName => $"删除任务 {TaskId}";
}

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
    string? Reason)
{
    public string ApproveAutomationName => $"批准 {Title}";
    public string DenyAutomationName => $"拒绝 {Title}";
}

public sealed record DirectApprovalListResponse(IReadOnlyList<DirectApprovalSummary> Approvals);

public sealed record DirectApprovalSummary(
    string ApprovalId,
    string ProjectId,
    string Kind,
    string Summary,
    DateTimeOffset CreatedAt)
{
    public string ApproveAutomationName => $"批准 Direct 操作 {Summary}";
    public string DenyAutomationName => $"拒绝 Direct 操作 {Summary}";
}

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

public sealed record TaskConversationSubscription(
    int SubscriptionId,
    TaskConversationPage Page);

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

public sealed record ThreadPage(
    IReadOnlyList<ThreadSummary> Threads,
    string? NextCursor);

public sealed record ThreadSummary(
    string ThreadId,
    string? Title,
    string Status,
    string? UpdatedAt,
    string? Preview)
{
    public string DisplayTitle => string.IsNullOrWhiteSpace(Title) ? ThreadId : Title;
    public string Detail => string.Join(" · ", new[] { Status, UpdatedAt }
        .Where(value => !string.IsNullOrWhiteSpace(value)));
}

public sealed record ThreadReadPage(
    ThreadSummary Thread,
    string Detail,
    IReadOnlyList<ThreadEntry> Entries,
    string? NextCursor);

public sealed record ThreadEntry(
    string TurnId,
    string Role,
    string Text,
    string? Status)
{
    public string Heading => string.IsNullOrWhiteSpace(Status) ? Role : $"{Role} · {Status}";
}

public sealed record ServiceSkillList(IReadOnlyList<ServiceSkill> Skills);

public sealed record ServiceSkill(
    string Name,
    string Description,
    string Scope,
    IReadOnlyList<string> Triggers,
    IReadOnlyList<ServiceSkillAction> Actions,
    bool HasReferences)
{
    public string Metadata => $"{Scope} · {Actions.Count} 个动作" +
        (HasReferences ? " · 含参考资料" : string.Empty);
    public string TriggerSummary => Triggers.Count == 0
        ? "无显式触发词"
        : string.Join("、", Triggers);
}

public sealed record ServiceSkillAction(
    string Name,
    string ScriptPath,
    string? Interpreter,
    IReadOnlyList<string>? CommandPrefix,
    bool RequiresNetwork,
    string NetworkRequirement,
    string Description);

public sealed class ProjectCommandEditor
{
    public string CommandId { get; set; } = Guid.NewGuid().ToString("N");
    public string Name { get; set; } = string.Empty;
    public string Executable { get; set; } = string.Empty;
    public string ArgumentsText { get; set; } = string.Empty;
    public string WorkingDirectory { get; set; } = string.Empty;
    public bool RequiresNetwork { get; set; }
    public string Risk { get; set; } = "normal";

    public static ProjectCommandEditor From(ProjectCommand command) => new()
    {
        CommandId = command.CommandId,
        Name = command.Name,
        Executable = command.Executable,
        ArgumentsText = string.Join(Environment.NewLine, command.Arguments),
        WorkingDirectory = command.WorkingDirectory ?? string.Empty,
        RequiresNetwork = command.RequiresNetwork,
        Risk = command.Risk,
    };

    public ProjectCommand ToRequest() => new(
        CommandId.Trim(),
        Name.Trim(),
        Executable.Trim(),
        ArgumentsText.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries)
            .Select(value => value.Trim())
            .Where(value => value.Length > 0)
            .ToArray(),
        NullIfEmpty(WorkingDirectory),
        RequiresNetwork,
        Risk);

    private static string? NullIfEmpty(string value)
    {
        var trimmed = value.Trim();
        return trimmed.Length == 0 ? null : trimmed;
    }
}

public sealed class CommandBlacklistEditor
{
    public string RuleId { get; set; } = Guid.NewGuid().ToString("N");
    public string Executable { get; set; } = string.Empty;
    public string Pattern { get; set; } = string.Empty;

    public static CommandBlacklistEditor From(CommandBlacklistRule rule) => new()
    {
        RuleId = rule.RuleId,
        Executable = rule.Executable ?? string.Empty,
        Pattern = rule.Pattern ?? string.Empty,
    };

    public CommandBlacklistRule ToRequest() => new(
        RuleId.Trim(),
        NullIfEmpty(Executable),
        NullIfEmpty(Pattern));

    private static string? NullIfEmpty(string value)
    {
        var trimmed = value.Trim();
        return trimmed.Length == 0 ? null : trimmed;
    }
}
