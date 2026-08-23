using CodexBridge.App.Models;
using Microsoft.UI.Xaml;
using System.Text.Json;

namespace CodexBridge.App;

public sealed partial class MainWindow
{
    private async Task LoadTunnelSettingsAsync()
    {
        var status = await _connection.GetStatusAsync(_lifetime.Token);
        PresentTunnelSettings(status.Tunnel);
    }

    private async void ConfigureTunnelClick(object sender, RoutedEventArgs args)
    {
        var tunnelId = TunnelIdBox.Text.Trim();
        var runtimeKey = TunnelRuntimeKeyBox.Password;
        TunnelRuntimeKeyBox.Password = string.Empty;
        if (tunnelId.Length == 0 || runtimeKey.Length == 0)
        {
            PresentError("Tunnel ID 与 Runtime Key 均不能为空。");
            return;
        }

        await ResolveTunnelActionAsync(async () =>
        {
            var status = await _connection.SendAsync<TunnelStatus>(
                "configure_tunnel",
                new { TunnelId = tunnelId, RuntimeKey = runtimeKey },
                _lifetime.Token);
            PresentTunnelSettings(status);
        });
    }

    private async void ConnectTunnelClick(object sender, RoutedEventArgs args)
    {
        await ResolveTunnelActionAsync(async () =>
        {
            var status = await _connection.SendAsync<TunnelStatus>(
                "connect_tunnel",
                null,
                _lifetime.Token);
            PresentTunnelSettings(status);
        });
    }

    private async void DisconnectTunnelClick(object sender, RoutedEventArgs args)
    {
        await ResolveTunnelActionAsync(async () =>
        {
            await _connection.SendAsync<JsonElement>(
                "disconnect_tunnel",
                null,
                _lifetime.Token);
            await LoadTunnelSettingsAsync();
        });
    }

    private async void ClearTunnelClick(object sender, RoutedEventArgs args)
    {
        if (!await ConfirmLocalActionAsync(
                "清除 Secure Tunnel 配置？",
                "这会断开 Tunnel，并从 Windows Secret Store 移除 Runtime Key。",
                "清除配置"))
        {
            return;
        }

        await ResolveTunnelActionAsync(async () =>
        {
            await _connection.SendAsync<JsonElement>(
                "clear_tunnel",
                null,
                _lifetime.Token);
            TunnelIdBox.Text = string.Empty;
            TunnelRuntimeKeyBox.Password = string.Empty;
            await LoadTunnelSettingsAsync();
        });
    }

    private async Task ResolveTunnelActionAsync(Func<Task> operation)
    {
        try
        {
            await operation();
        }
        catch (Exception error)
        {
            PresentError(error.Message);
            try
            {
                await LoadTunnelSettingsAsync();
            }
            catch (Exception refreshError)
            {
                TunnelSettingsStatus.Text = $"Tunnel 状态刷新失败：{refreshError.Message}";
            }
        }
    }

    private void PresentTunnelSettings(TunnelStatus tunnel)
    {
        if (string.IsNullOrWhiteSpace(TunnelIdBox.Text) && tunnel.TunnelId is not null)
        {
            TunnelIdBox.Text = tunnel.TunnelId;
        }
        ConfigureTunnelButton.IsEnabled = tunnel.HelperAvailable;
        ConnectTunnelButton.IsEnabled =
            tunnel.HelperAvailable && tunnel.Configured && !tunnel.Enabled;
        DisconnectTunnelButton.IsEnabled = tunnel.Enabled;
        ClearTunnelButton.IsEnabled = tunnel.Configured;
        TunnelSettingsStatus.Text = TunnelStatusDescription(tunnel);
    }

    private static string TunnelStatusDescription(TunnelStatus tunnel)
    {
        if (!tunnel.HelperAvailable)
        {
            return "Windows Tunnel helper 尚未打包；本机 MCP 可用，但远程 Tunnel 保持 fail-closed。";
        }
        if (!tunnel.Configured)
        {
            return "尚未配置 Tunnel。";
        }
        var acceptance = tunnel.AcceptsRemoteSubmissions ? "正在接收远程提交" : "未接收远程提交";
        var action = tunnel.ActionRequired ? "，需要检查凭证" : string.Empty;
        return $"状态：{tunnel.Lifecycle}；{acceptance}{action}。";
    }
}
