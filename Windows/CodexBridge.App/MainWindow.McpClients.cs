using CodexBridge.App.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using System.Text.Json;
using Windows.ApplicationModel.DataTransfer;

namespace CodexBridge.App;

public sealed partial class MainWindow
{
    private async void ToggleMcpClientEnabledClick(object sender, RoutedEventArgs args)
    {
        if (sender is not Button { DataContext: McpClientStatus client } ||
            !client.CanToggleEnabled)
        {
            return;
        }

        await ResolveMcpClientActionAsync(async () =>
        {
            await _connection.SendAsync<JsonElement>(
                "set_mcp_client_enabled",
                new { client.ClientId, Enabled = !client.Enabled },
                _lifetime.Token);
            McpClientActionStatus.Text = client.Enabled
                ? "Qwen Studio 已停用；现有会话已撤销。"
                : "Qwen Studio 已启用；请导出新的 JSON 配置。";
        });
    }

    private async void ToggleMcpClientExposureClick(object sender, RoutedEventArgs args)
    {
        if (sender is not Button { DataContext: McpClientStatus client } ||
            !client.CanChangeExposure)
        {
            return;
        }

        var nextMode = client.ExposureMode == "full" ? "read-only" : "full";
        if (nextMode == "full" && !await ConfirmMcpClientActionAsync(
                $"允许 {client.DisplayName} 使用完整工具？",
                "项目权限、workspace gate、网络限制和本机审批仍然生效，但该客户端将能看到任务提交与 Direct 工具。",
                "允许完整工具"))
        {
            return;
        }

        await ResolveMcpClientActionAsync(async () =>
        {
            await _connection.SendAsync<JsonElement>(
                "set_mcp_client_exposure_mode",
                new { client.ClientId, ExposureMode = nextMode },
                _lifetime.Token);
            McpClientActionStatus.Text = $"{client.DisplayName} 已切换为 {nextMode} 模式。";
        });
    }

    private async void ExportMcpClientConfigurationClick(object sender, RoutedEventArgs args)
    {
        if (sender is not Button { DataContext: McpClientStatus client } ||
            !client.CanManageCredential)
        {
            return;
        }

        await ResolveMcpClientActionAsync(async () =>
        {
            var export = await _connection.SendAsync<McpClientConfigurationExport>(
                "export_mcp_client_configuration",
                new { client.ClientId },
                _lifetime.Token);
            var package = new DataPackage { RequestedOperation = DataPackageOperation.Copy };
            package.SetText(export.ConfigurationJson);
            Clipboard.SetContent(package);
            McpClientActionStatus.Text =
                "Qwen JSON 配置已复制；内容含本机凭证，粘贴完成后请清空剪贴板。";
        });
    }

    private async void RotateMcpClientCredentialClick(object sender, RoutedEventArgs args)
    {
        if (sender is not Button { DataContext: McpClientStatus client } ||
            !client.CanManageCredential)
        {
            return;
        }
        if (!await ConfirmMcpClientActionAsync(
                "重新生成 Qwen Studio 凭证？",
                "现有 Qwen 会话与旧 JSON 配置将立即失效。重新连接前需要再次复制配置。",
                "重新生成"))
        {
            return;
        }

        await ResolveMcpClientActionAsync(async () =>
        {
            await _connection.SendAsync<JsonElement>(
                "rotate_mcp_client_credential",
                new { client.ClientId },
                _lifetime.Token);
            McpClientActionStatus.Text = "Qwen Studio 凭证已重新生成；请复制新的 JSON 配置。";
        });
    }

    private async Task ResolveMcpClientActionAsync(Func<Task> operation)
    {
        try
        {
            await operation();
            await LoadSectionAsync("connections");
        }
        catch (Exception error)
        {
            PresentError(error.Message);
        }
    }

    private async Task<bool> ConfirmMcpClientActionAsync(
        string title,
        string message,
        string primaryButtonText)
    {
        var dialog = new ContentDialog
        {
            Title = title,
            Content = message,
            PrimaryButtonText = primaryButtonText,
            CloseButtonText = "取消",
            DefaultButton = ContentDialogButton.Close,
            XamlRoot = Content.XamlRoot,
        };
        return await dialog.ShowAsync() == ContentDialogResult.Primary;
    }
}
