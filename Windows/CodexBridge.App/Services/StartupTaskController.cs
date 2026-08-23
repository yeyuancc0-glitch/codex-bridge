using Windows.ApplicationModel;

namespace CodexBridge.App.Services;

public sealed record StartupTaskPresentation(string State, bool CanRequestEnable);

public static class StartupTaskController
{
    public const string TaskId = "CodexBridgeServiceStartup";

    public static async Task<StartupTaskPresentation> ReadAsync()
    {
        try
        {
            var task = await StartupTask.GetAsync(TaskId);
            return Present(task.State);
        }
        catch
        {
            return new StartupTaskPresentation("当前开发构建未注册 StartupTask", false);
        }
    }

    public static async Task<StartupTaskPresentation> RequestEnableAsync()
    {
        var task = await StartupTask.GetAsync(TaskId);
        if (task.State == StartupTaskState.Disabled)
        {
            await task.RequestEnableAsync();
        }
        return Present(task.State);
    }

    private static StartupTaskPresentation Present(StartupTaskState state)
    {
        return state switch
        {
            StartupTaskState.Enabled => new StartupTaskPresentation("登录后自动启动已开启", false),
            StartupTaskState.Disabled => new StartupTaskPresentation("登录后自动启动未开启", true),
            StartupTaskState.DisabledByUser => new StartupTaskPresentation(
                "已被用户禁用；请在 Windows 启动应用设置中恢复",
                false),
            StartupTaskState.EnabledByPolicy => new StartupTaskPresentation("由系统策略开启", false),
            StartupTaskState.DisabledByPolicy => new StartupTaskPresentation("由系统策略禁用", false),
            _ => new StartupTaskPresentation(state.ToString(), false),
        };
    }
}
