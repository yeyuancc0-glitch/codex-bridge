using CodexBridge.App.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using System.Text.Json;

namespace CodexBridge.App;

public sealed partial class MainWindow
{
    private static readonly IReadOnlyList<SelectionOption> ReadPermissions =
    [
        new("denied", "拒绝"),
        new("allowed", "允许"),
    ];

    private static readonly IReadOnlyList<SelectionOption> MutablePermissions =
    [
        new("denied", "拒绝"),
        new("requiresLocalApproval", "需要本机批准"),
        new("allowed", "允许"),
    ];

    private async void EditProjectPolicyClick(object sender, RoutedEventArgs args)
    {
        if (sender is not Button { DataContext: ProjectSummary project })
        {
            return;
        }

        var read = PermissionBox("读取权限", ReadPermissions, project.Capabilities.Read);
        var write = PermissionBox("写入权限", MutablePermissions, project.Capabilities.Write);
        var network = PermissionBox("网络权限", MutablePermissions, project.Capabilities.Network);
        var content = new StackPanel { Spacing = 12 };
        content.Children.Add(read);
        content.Children.Add(write);
        content.Children.Add(network);
        content.Children.Add(new TextBlock
        {
            Text = "本机审批不能由 MCP 客户端或 Supervisor 代替；Windows Direct 网络隔离未完成时会保持 fail-closed。",
            TextWrapping = TextWrapping.Wrap,
            Opacity = 0.72,
        });

        var dialog = new ContentDialog
        {
            Title = $"编辑“{project.Name}”权限",
            Content = content,
            PrimaryButtonText = "保存",
            CloseButtonText = "取消",
            DefaultButton = ContentDialogButton.Close,
            XamlRoot = Content.XamlRoot,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary ||
            !TryReadPermission(read, out var readValue) ||
            !TryReadPermission(write, out var writeValue) ||
            !TryReadPermission(network, out var networkValue))
        {
            return;
        }
        if (Broadens(project.Capabilities, readValue, writeValue, networkValue) &&
            !await ConfirmLocalActionAsync(
                "扩大项目权限？",
                "新权限会立即影响所有已启用的 MCP 客户端和后续 Codex 任务；危险操作的本机审批边界仍然保留。",
                "扩大权限"))
        {
            return;
        }

        await ResolveWithStatusAsync(async () =>
        {
            await _connection.SendAsync<JsonElement>(
                "update_project_policy",
                new
                {
                    project.ProjectId,
                    ReadPermission = readValue,
                    WritePermission = writeValue,
                    NetworkPermission = networkValue,
                },
                _lifetime.Token);
            await LoadSectionAsync("projects");
        });
    }

    private static ComboBox PermissionBox(
        string header,
        IReadOnlyList<SelectionOption> options,
        string selected)
    {
        IReadOnlyList<SelectionOption> presented = options.Any(option => option.Value == selected)
            ? options
            : options.Append(new SelectionOption(selected, $"当前设置 · {selected}")).ToArray();
        return new ComboBox
        {
            Header = header,
            ItemsSource = presented,
            DisplayMemberPath = nameof(SelectionOption.Label),
            SelectedItem = presented.First(option => option.Value == selected),
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };
    }

    private static bool TryReadPermission(ComboBox box, out string value)
    {
        if (box.SelectedItem is SelectionOption option)
        {
            value = option.Value;
            return true;
        }
        value = string.Empty;
        return false;
    }

    private static bool Broadens(
        ProjectCapabilities current,
        string read,
        string write,
        string network)
    {
        return PermissionRank(read) > PermissionRank(current.Read) ||
            PermissionRank(write) > PermissionRank(current.Write) ||
            PermissionRank(network) > PermissionRank(current.Network);
    }

    private static int PermissionRank(string permission) => permission switch
    {
        "allowed" => 2,
        "requiresLocalApproval" => 1,
        _ => 0,
    };
}
