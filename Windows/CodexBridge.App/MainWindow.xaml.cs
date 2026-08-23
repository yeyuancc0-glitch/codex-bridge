using CodexBridge.App.Models;
using CodexBridge.App.Services;
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
            var response = await _connection.GetStatusAsync(_lifetime.Token);
            PresentStatus(response);
        }
        catch (Exception error) when (error is IOException or TimeoutException or OperationCanceledException)
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
        Overview.Visibility = tag == "overview" ? Visibility.Visible : Visibility.Collapsed;
        Placeholder.Visibility = tag is not ("overview" or "workbench")
            ? Visibility.Visible
            : Visibility.Collapsed;
        if (tag == "workbench")
        {
            await Workbench.ActivateAsync();
        }
        else
        {
            Workbench.Deactivate();
        }
        PlaceholderTitle.Text = tag switch
        {
            "tasks" => "任务",
            "projects" => "项目",
            "approvals" => "审批",
            "connections" => "连接",
            "settings" => "设置",
            _ => string.Empty,
        };
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
