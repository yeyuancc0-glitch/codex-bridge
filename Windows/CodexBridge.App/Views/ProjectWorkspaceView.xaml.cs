using CodexBridge.App.Models;
using CodexBridge.App.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using System.Collections.ObjectModel;

namespace CodexBridge.App.Views;

public sealed partial class ProjectWorkspaceView : UserControl
{
    private static readonly IReadOnlyList<SelectionOption> CommandModes =
    [
        new("denied", "禁止直接执行"),
        new("safe", "安全模式（推荐）"),
        new("full", "完全模式"),
    ];

    private readonly BridgeConnection _connection;
    private readonly ProjectSummary _project;
    private readonly CancellationToken _cancellationToken;
    private readonly ObservableCollection<ProjectCommandEditor> _commands = [];
    private readonly ObservableCollection<CommandBlacklistEditor> _blacklist = [];
    private string _loadedMode = "safe";

    public ProjectWorkspaceView(
        BridgeConnection connection,
        ProjectSummary project,
        CancellationToken cancellationToken)
    {
        InitializeComponent();
        _connection = connection;
        _project = project;
        _cancellationToken = cancellationToken;
        CommandModeBox.ItemsSource = CommandModes;
        CommandModeBox.SelectionChanged += CommandModeSelectionChanged;
        CommandList.ItemsSource = _commands;
        BlacklistList.ItemsSource = _blacklist;
        Loaded += ViewLoaded;
    }

    private async void ViewLoaded(object sender, RoutedEventArgs args)
    {
        Loaded -= ViewLoaded;
        await LoadAllAsync();
    }

    private async Task LoadAllAsync()
    {
        try
        {
            await Task.WhenAll(LoadDirectAsync(), LoadThreadsAsync(), LoadSkillsAsync());
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception error)
        {
            DirectStatus.Text = error.Message;
        }
    }

    private async Task LoadDirectAsync()
    {
        var detail = await _connection.SendAsync<ProjectDetail>(
            "get_project_commands",
            new { _project.ProjectId },
            _cancellationToken);
        var workspace = detail.DirectWorkspace;
        _loadedMode = workspace?.CommandMode ?? "safe";
        CommandModeBox.SelectedItem = CommandModes.First(mode => mode.Value == _loadedMode);
        _commands.Clear();
        foreach (var command in workspace?.Commands ?? [])
        {
            _commands.Add(ProjectCommandEditor.From(command));
        }
        _blacklist.Clear();
        foreach (var rule in workspace?.CommandBlacklist ?? [])
        {
            _blacklist.Add(CommandBlacklistEditor.From(rule));
        }
        DirectStatus.Text = "配置已从 Service 读取。";
    }

    private async Task LoadThreadsAsync()
    {
        var page = await _connection.SendAsync<ThreadPage>(
            "list_threads",
            new { _project.ProjectId, Cursor = (string?)null, Limit = 100, Search = (string?)null },
            _cancellationToken);
        ThreadList.ItemsSource = page.Threads;
        ThreadTitle.Text = page.NextCursor is null
            ? $"{page.Threads.Count} 个 Threads"
            : $"显示前 {page.Threads.Count} 个 Threads";
        ThreadEntryList.ItemsSource = null;
    }

    private async Task LoadSkillsAsync()
    {
        var response = await _connection.SendAsync<ServiceSkillList>(
            "list_skills",
            new { _project.ProjectId },
            _cancellationToken);
        SkillList.ItemsSource = response.Skills;
    }

    private void CommandModeSelectionChanged(object sender, SelectionChangedEventArgs args)
    {
        FullModeConfirmation.Visibility = SelectedMode() == "full"
            ? Visibility.Visible
            : Visibility.Collapsed;
        if (SelectedMode() != "full")
        {
            FullModeConfirmation.IsChecked = false;
        }
    }

    private void AddCommandClick(object sender, RoutedEventArgs args)
    {
        _commands.Add(new ProjectCommandEditor());
    }

    private void RemoveCommandClick(object sender, RoutedEventArgs args)
    {
        if (sender is Button { DataContext: ProjectCommandEditor command })
        {
            _commands.Remove(command);
        }
    }

    private void AddBlacklistClick(object sender, RoutedEventArgs args)
    {
        _blacklist.Add(new CommandBlacklistEditor());
    }

    private void RemoveBlacklistClick(object sender, RoutedEventArgs args)
    {
        if (sender is Button { DataContext: CommandBlacklistEditor rule })
        {
            _blacklist.Remove(rule);
        }
    }

    private async void SaveDirectClick(object sender, RoutedEventArgs args)
    {
        var mode = SelectedMode();
        if (mode == "full" && _loadedMode != "full" && FullModeConfirmation.IsChecked != true)
        {
            DirectStatus.Text = "启用完全模式前需要本机确认。";
            return;
        }

        try
        {
            var commands = _commands.Select(command => command.ToRequest()).ToArray();
            var blacklist = _blacklist.Select(rule => rule.ToRequest()).ToArray();
            Validate(commands, blacklist);
            await _connection.SendAsync<ProjectDetail>(
                "update_project_commands",
                new { _project.ProjectId, Commands = commands, CommandBlacklist = blacklist },
                _cancellationToken);
            await _connection.SendAsync<ProjectDetail>(
                "set_project_command_mode",
                new { _project.ProjectId, CommandMode = mode },
                _cancellationToken);
            await LoadDirectAsync();
            DirectStatus.Text = "Direct 配置已保存并由 Service 回读确认。";
        }
        catch (Exception error)
        {
            DirectStatus.Text = error.Message;
        }
    }

    private static void Validate(
        IReadOnlyList<ProjectCommand> commands,
        IReadOnlyList<CommandBlacklistRule> blacklist)
    {
        if (commands.Count > 128 || blacklist.Count > 128)
        {
            throw new InvalidOperationException("允许命令和黑名单各最多 128 条。");
        }
        if (commands.Any(command =>
            command.CommandId.Length == 0 || command.Name.Length == 0 ||
            command.Executable.Length == 0))
        {
            throw new InvalidOperationException("命令 ID、名称和可执行文件不能为空。");
        }
        if (blacklist.Any(rule =>
            rule.RuleId.Length == 0 || (rule.Executable is null && rule.Pattern is null)))
        {
            throw new InvalidOperationException("黑名单规则必须有 ID，并至少填写可执行文件或参数包含。");
        }
    }

    private string SelectedMode()
    {
        return (CommandModeBox.SelectedItem as SelectionOption)?.Value ?? "safe";
    }

    private async void RefreshThreadsClick(object sender, RoutedEventArgs args)
    {
        try { await LoadThreadsAsync(); }
        catch (Exception error) { ThreadTitle.Text = error.Message; }
    }

    private async void ThreadSelectionChanged(object sender, SelectionChangedEventArgs args)
    {
        if (ThreadList.SelectedItem is not ThreadSummary thread)
        {
            return;
        }
        ThreadTitle.Text = "正在读取…";
        try
        {
            var page = await _connection.SendAsync<ThreadReadPage>(
                "read_thread",
                new
                {
                    _project.ProjectId,
                    thread.ThreadId,
                    Detail = "full",
                    Cursor = (string?)null,
                    Limit = 100,
                },
                _cancellationToken);
            ThreadTitle.Text = page.Thread.DisplayTitle;
            ThreadEntryList.ItemsSource = page.Entries;
        }
        catch (Exception error)
        {
            ThreadTitle.Text = error.Message;
            ThreadEntryList.ItemsSource = null;
        }
    }

    private async void RefreshSkillsClick(object sender, RoutedEventArgs args)
    {
        try { await LoadSkillsAsync(); }
        catch (Exception error) { DirectStatus.Text = error.Message; }
    }
}
