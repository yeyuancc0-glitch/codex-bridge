using CodexBridge.App.Models;
using CodexBridge.App.Services;
using CodexBridge.Ipc;
using System.Text.Json;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using WinRT.Interop;

namespace CodexBridge.App;

public sealed partial class MainWindow : Window
{
    private readonly BridgeConnection _connection = new();
    private readonly CancellationTokenSource _lifetime = new();

    public MainWindow()
    {
        InitializeComponent();
        SetWindowSize(1180, 760);
        Navigation.SelectedItem = Navigation.MenuItems[0];
        Closed += WindowClosed;
        _ = RefreshStatusAsync();
    }

    private async void RefreshButtonClick(object sender, RoutedEventArgs args)
    {
        await RefreshStatusAsync();
    }

    private async Task RefreshStatusAsync()
    {
        RefreshButton.IsEnabled = false;
        try
        {
            var response = await GetStatusStartingServiceIfNeededAsync();
            PresentStatus(response);
        }
        catch (Exception error) when (
            error is IOException or TimeoutException or OperationCanceledException or
            BridgeProtocolException or BridgeRemoteException)
        {
            PresentDisconnected();
        }
        finally
        {
            RefreshButton.IsEnabled = true;
        }
    }

    private async void NavigationSelectionChanged(
        NavigationView sender,
        NavigationViewSelectionChangedEventArgs args)
    {
        var tag = args.IsSettingsSelected
            ? "settings"
            : (args.SelectedItemContainer?.Tag as string ?? "overview");
        SetSectionVisibility(tag);
        try
        {
            if (tag == "workbench")
            {
                await Workbench.ActivateAsync();
            }
            else
            {
                Workbench.Deactivate();
            }
            await LoadSectionAsync(tag);
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception error)
        {
            PresentError(error.Message);
        }
    }

    private void PresentStatus(ServiceStatusResponse response)
    {
        ConnectionIndicator.Fill = new SolidColorBrush(Colors.SeaGreen);
        ConnectionLabel.Text = "Service 已连接";
        McpState.Text = response.Status.McpState;
        McpEndpoint.Text = response.LocalMcpUrl ?? "未启动";
        CodexState.Text = response.Status.ExecutionState;
        CodexVersion.Text = response.Status.CodexVersion ?? "未发现";
        TunnelState.Text = response.Tunnel.Lifecycle;
        TunnelDetail.Text = response.Tunnel.Configured ? "已配置" : "未配置";
        ApprovalSummary.Text = response.Status.PendingApprovalCount == 0
            ? "没有待审批操作"
            : $"{response.Status.PendingApprovalCount} 个操作等待本机用户审批";
        Degradations.ItemsSource = response.Status.Degradations;
    }

    private void PresentDisconnected()
    {
        ConnectionIndicator.Fill = new SolidColorBrush(Colors.DarkOrange);
        ConnectionLabel.Text = "Service 未连接";
        McpState.Text = "不可用";
        CodexState.Text = "不可用";
        TunnelState.Text = "不可用";
        ApprovalSummary.Text = "启动 Codex Bridge Service 后重试。";
        Degradations.ItemsSource = null;
    }

    private void PresentError(string message)
    {
        ConnectionIndicator.Fill = new SolidColorBrush(Colors.DarkOrange);
        ConnectionLabel.Text = message;
    }

    private void SetSectionVisibility(string tag)
    {
        Overview.Visibility = tag == "overview" ? Visibility.Visible : Visibility.Collapsed;
        TasksView.Visibility = tag == "tasks" ? Visibility.Visible : Visibility.Collapsed;
        ProjectsView.Visibility = tag == "projects" ? Visibility.Visible : Visibility.Collapsed;
        ApprovalsView.Visibility = tag == "approvals" ? Visibility.Visible : Visibility.Collapsed;
        ConnectionsView.Visibility = tag == "connections" ? Visibility.Visible : Visibility.Collapsed;
        SettingsView.Visibility = tag == "settings" ? Visibility.Visible : Visibility.Collapsed;
    }

    private async Task LoadSectionAsync(string tag)
    {
        switch (tag)
        {
            case "tasks":
                TaskList.ItemsSource = (await _connection.SendAsync<TaskListResponse>(
                    "list_tasks",
                    new { projectId = (string?)null, limit = 100 },
                    _lifetime.Token)).Tasks;
                break;
            case "projects":
                ProjectList.ItemsSource = (await _connection.SendAsync<ProjectListResponse>(
                    "list_projects",
                    null,
                    _lifetime.Token)).Projects;
                break;
            case "approvals":
                await LoadApprovalsAsync();
                break;
            case "connections":
                McpClientList.ItemsSource = (await _connection.SendAsync<McpClientListResponse>(
                    "list_mcp_clients",
                    null,
                    _lifetime.Token)).Clients;
                break;
            case "settings":
                await PresentStartupTaskAsync();
                break;
        }
    }

    private async Task<ServiceStatusResponse> GetStatusStartingServiceIfNeededAsync()
    {
        try
        {
            return await _connection.GetStatusAsync(_lifetime.Token);
        }
        catch (IOException) when (WindowsServiceLauncher.TryStartOnce())
        {
            await Task.Delay(TimeSpan.FromMilliseconds(500), _lifetime.Token);
            return await _connection.GetStatusAsync(_lifetime.Token);
        }
    }

    private async Task LoadApprovalsAsync()
    {
        ApprovalList.ItemsSource = (await _connection.SendAsync<ApprovalListResponse>(
            "list_approvals",
            new { taskId = (string?)null },
            _lifetime.Token)).Approvals;
        DirectApprovalList.ItemsSource = (await _connection.SendAsync<DirectApprovalListResponse>(
            "list_direct_approvals",
            null,
            _lifetime.Token)).Approvals;
    }

    private async void ApproveCodexApprovalClick(object sender, RoutedEventArgs args)
    {
        await ResolveWithStatusAsync(() => ResolveCodexApprovalAsync(sender, "allow"));
    }

    private async void DenyCodexApprovalClick(object sender, RoutedEventArgs args)
    {
        await ResolveWithStatusAsync(() => ResolveCodexApprovalAsync(sender, "deny"));
    }

    private async Task ResolveCodexApprovalAsync(object sender, string decision)
    {
        if (sender is not Button { DataContext: ApprovalSummary approval })
        {
            return;
        }
        await _connection.SendAsync<JsonElement>(
            "resolve_approval",
            new { approval.TaskId, approval.ApprovalId, decision },
            _lifetime.Token);
        await LoadApprovalsAsync();
    }

    private async void ApproveDirectApprovalClick(object sender, RoutedEventArgs args)
    {
        await ResolveWithStatusAsync(
            () => ResolveDirectApprovalAsync(sender, "approve_direct_approval"));
    }

    private async void DenyDirectApprovalClick(object sender, RoutedEventArgs args)
    {
        await ResolveWithStatusAsync(
            () => ResolveDirectApprovalAsync(sender, "deny_direct_approval"));
    }

    private async Task ResolveDirectApprovalAsync(object sender, string operation)
    {
        if (sender is not Button { DataContext: DirectApprovalSummary approval })
        {
            return;
        }
        await _connection.SendAsync<JsonElement>(
            operation,
            new { approval.ApprovalId },
            _lifetime.Token);
        await LoadApprovalsAsync();
    }

    private async Task ResolveWithStatusAsync(Func<Task> operation)
    {
        try
        {
            await operation();
        }
        catch (Exception error)
        {
            PresentError(error.Message);
        }
    }

    private async void EnableStartupTaskClick(object sender, RoutedEventArgs args)
    {
        EnableStartupTaskButton.IsEnabled = false;
        try
        {
            PresentStartupTask(await StartupTaskController.RequestEnableAsync());
        }
        catch (Exception error)
        {
            PresentError(error.Message);
        }
    }

    private async Task PresentStartupTaskAsync()
    {
        PresentStartupTask(await StartupTaskController.ReadAsync());
    }

    private void PresentStartupTask(StartupTaskPresentation presentation)
    {
        StartupTaskStateLabel.Text = presentation.State;
        EnableStartupTaskButton.Visibility = presentation.CanRequestEnable
            ? Visibility.Visible
            : Visibility.Collapsed;
        EnableStartupTaskButton.IsEnabled = presentation.CanRequestEnable;
    }

    private async void WindowClosed(object sender, WindowEventArgs args)
    {
        _lifetime.Cancel();
        await _connection.DisposeAsync();
        _lifetime.Dispose();
    }

    private void SetWindowSize(int width, int height)
    {
        var handle = WindowNative.GetWindowHandle(this);
        var windowId = Win32Interop.GetWindowIdFromWindow(handle);
        AppWindow.GetFromWindowId(windowId).Resize(new Windows.Graphics.SizeInt32(width, height));
    }
}
