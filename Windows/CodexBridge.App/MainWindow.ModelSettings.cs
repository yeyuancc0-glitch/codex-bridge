using CodexBridge.App.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using System.Text.Json;

namespace CodexBridge.App;

public sealed partial class MainWindow
{
    private static readonly IReadOnlyList<SelectionOption> AccessModes =
    [
        new("request-approval", "请求批准（推荐）"),
        new("auto-review", "自动评审"),
        new("full-access", "完全访问权限"),
    ];

    private bool _loadingModelSettings;
    private ModelCatalogResponse? _modelCatalog;

    private async Task LoadModelSettingsAsync()
    {
        _loadingModelSettings = true;
        try
        {
            var catalog = await _connection.SendAsync<ModelCatalogResponse>(
                "get_model_catalog",
                null,
                _lifetime.Token);
            _modelCatalog = catalog;
            ExecutionModelBox.ItemsSource = catalog.Models;
            SupervisorModelBox.ItemsSource = catalog.Models;
            AccessModeBox.ItemsSource = AccessModes;
            ExecutionModelBox.SelectedItem = FindModel(catalog.Preferences.ExecutionModel);
            SupervisorModelBox.SelectedItem = FindModel(catalog.Preferences.SupervisorModel);
            PresentEfforts(
                ExecutionEffortBox,
                ExecutionModelBox.SelectedItem as ModelSummary,
                catalog.Preferences.ExecutionEffort);
            PresentEfforts(
                SupervisorEffortBox,
                SupervisorModelBox.SelectedItem as ModelSummary,
                catalog.Preferences.SupervisorEffort);
            AccessModeBox.SelectedItem = AccessModes.FirstOrDefault(
                item => item.Value == catalog.Preferences.AccessMode);
            SupervisorEnabledSwitch.IsOn = catalog.Preferences.SupervisorEnabled;
            FastModeSwitch.IsOn = catalog.Preferences.FastModeEnabled;
            PresentFastModeAvailability();
            ModelSettingsStatus.Text = catalog.Models.Count == 0
                ? "Codex app-server 未返回可用模型。"
                : "已从 Service 读取当前偏好。";
        }
        finally
        {
            _loadingModelSettings = false;
        }
    }

    private void ExecutionModelSelectionChanged(
        object sender,
        SelectionChangedEventArgs args)
    {
        if (_loadingModelSettings)
        {
            return;
        }
        PresentEfforts(
            ExecutionEffortBox,
            ExecutionModelBox.SelectedItem as ModelSummary,
            null);
        PresentFastModeAvailability();
    }

    private void SupervisorModelSelectionChanged(
        object sender,
        SelectionChangedEventArgs args)
    {
        if (_loadingModelSettings)
        {
            return;
        }
        PresentEfforts(
            SupervisorEffortBox,
            SupervisorModelBox.SelectedItem as ModelSummary,
            null);
    }

    private async void SaveModelPreferencesClick(object sender, RoutedEventArgs args)
    {
        if (!TryReadModelPreferences(out var preferences))
        {
            PresentError("请选择有效的执行与 Supervisor 模型及推理强度。");
            return;
        }
        var previous = _modelCatalog?.Preferences;
        if (preferences.AccessMode == "full-access" && previous?.AccessMode != "full-access" &&
            !await ConfirmLocalActionAsync(
                "启用完全访问权限？",
                "新任务可不受限制地访问互联网和已授权目录。Codex 与 Direct 的危险操作审批边界不会因此替你自动批准。",
                "启用完全访问"))
        {
            return;
        }

        await ResolveWithStatusAsync(async () =>
        {
            await _connection.SendAsync<JsonElement>(
                "set_model_preferences",
                preferences,
                _lifetime.Token);
            if (previous?.SupervisorEnabled != preferences.SupervisorEnabled)
            {
                await _connection.SendAsync<JsonElement>(
                    "set_supervisor_enabled",
                    new { Enabled = preferences.SupervisorEnabled },
                    _lifetime.Token);
            }
            await LoadModelSettingsAsync();
            ModelSettingsStatus.Text = "模型偏好已保存到 Service。";
        });
    }

    private bool TryReadModelPreferences(out ModelPreferences preferences)
    {
        var execution = ExecutionModelBox.SelectedItem as ModelSummary;
        var supervisor = SupervisorModelBox.SelectedItem as ModelSummary;
        var executionEffort = ExecutionEffortBox.SelectedItem as string;
        var supervisorEffort = SupervisorEffortBox.SelectedItem as string;
        var access = AccessModeBox.SelectedItem as SelectionOption;
        if (execution is null || supervisor is null || executionEffort is null ||
            supervisorEffort is null || access is null)
        {
            preferences = null!;
            return false;
        }
        preferences = new ModelPreferences(
            execution.ModelId,
            executionEffort,
            supervisor.ModelId,
            supervisorEffort,
            SupervisorEnabledSwitch.IsOn,
            access.Value,
            FastModeSwitch.IsOn && execution.SupportsFastMode);
        return true;
    }

    private ModelSummary? FindModel(string modelId) =>
        _modelCatalog?.Models.FirstOrDefault(model => model.ModelId == modelId);

    private static void PresentEfforts(
        ComboBox box,
        ModelSummary? model,
        string? selected)
    {
        IReadOnlyList<string> efforts = model?.ReasoningEfforts ?? Array.Empty<string>();
        box.ItemsSource = efforts;
        var selectedEffort = efforts.FirstOrDefault(effort => effort == selected);
        var defaultEffort = efforts.FirstOrDefault(
            effort => effort == model?.DefaultReasoningEffort);
        box.SelectedItem = selectedEffort ?? defaultEffort ?? efforts.FirstOrDefault();
    }

    private void PresentFastModeAvailability()
    {
        var supported = (ExecutionModelBox.SelectedItem as ModelSummary)?.SupportsFastMode == true;
        FastModeSwitch.IsEnabled = supported;
        if (!supported)
        {
            FastModeSwitch.IsOn = false;
        }
    }
}
