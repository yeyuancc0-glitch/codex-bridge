using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32;
using Windows.ApplicationModel;

namespace CodexBridge.App.Services;

public sealed record StartupTaskPresentation(
    string State,
    bool CanRequestEnable,
    bool CanRequestDisable);

public static class StartupTaskController
{
    public const string TaskId = "CodexBridgeServiceStartup";
    private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string RunValueName = "CodexBridgeService";
    private const int ErrorSuccess = 0;
    private const int ErrorInsufficientBuffer = 122;
    private const int AppModelErrorNoPackage = 15700;

    private enum PackageIdentityState
    {
        Present,
        Absent,
        Unknown,
    }

    public static async Task<StartupTaskPresentation> ReadAsync()
    {
        var identity = ReadPackageIdentity();
        if (identity == PackageIdentityState.Absent)
        {
            return ReadUnpackagedStartup();
        }
        if (identity == PackageIdentityState.Unknown)
        {
            return new StartupTaskPresentation("无法确认应用安装身份", false, false);
        }
        try
        {
            var task = await StartupTask.GetAsync(TaskId);
            return Present(task.State);
        }
        catch
        {
            return new StartupTaskPresentation("当前开发构建未注册 StartupTask", false, false);
        }
    }

    public static async Task<StartupTaskPresentation> RequestEnableAsync()
    {
        var identity = ReadPackageIdentity();
        if (identity == PackageIdentityState.Absent)
        {
            return EnableUnpackagedStartup();
        }
        if (identity == PackageIdentityState.Unknown)
        {
            throw new InvalidOperationException("无法确认应用安装身份，未修改自动启动设置。");
        }
        var task = await StartupTask.GetAsync(TaskId);
        if (task.State == StartupTaskState.Disabled)
        {
            await task.RequestEnableAsync();
        }
        return Present(task.State);
    }

    public static async Task<StartupTaskPresentation> RequestDisableAsync()
    {
        var identity = ReadPackageIdentity();
        if (identity == PackageIdentityState.Absent)
        {
            return DisableUnpackagedStartup();
        }
        if (identity == PackageIdentityState.Unknown)
        {
            throw new InvalidOperationException("无法确认应用安装身份，未修改自动启动设置。");
        }
        var task = await StartupTask.GetAsync(TaskId);
        if (task.State == StartupTaskState.Enabled)
        {
            task.Disable();
        }
        return Present(task.State);
    }

    private static StartupTaskPresentation Present(StartupTaskState state)
    {
        return state switch
        {
            StartupTaskState.Enabled => new StartupTaskPresentation("登录后自动启动已开启", false, true),
            StartupTaskState.Disabled => new StartupTaskPresentation("登录后自动启动未开启", true, false),
            StartupTaskState.DisabledByUser => new StartupTaskPresentation(
                "已被用户禁用；请在 Windows 启动应用设置中恢复",
                false,
                false),
            StartupTaskState.EnabledByPolicy => new StartupTaskPresentation("由系统策略开启", false, false),
            StartupTaskState.DisabledByPolicy => new StartupTaskPresentation("由系统策略禁用", false, false),
            _ => new StartupTaskPresentation(state.ToString(), false, false),
        };
    }

    private static PackageIdentityState ReadPackageIdentity()
    {
        uint length = 0;
        var result = GetCurrentPackageFullName(ref length, null);
        return result switch
        {
            ErrorSuccess or ErrorInsufficientBuffer => PackageIdentityState.Present,
            AppModelErrorNoPackage => PackageIdentityState.Absent,
            _ => PackageIdentityState.Unknown,
        };
    }

    private static StartupTaskPresentation ReadUnpackagedStartup()
    {
        var command = WindowsServiceExecutable.StartupCommand();
        if (command is null)
        {
            return new StartupTaskPresentation("后台 Service 安装不完整", false, false);
        }
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: false);
            var configured = key?.GetValue(RunValueName) as string;
            if (string.Equals(configured, command, StringComparison.OrdinalIgnoreCase))
            {
                return new StartupTaskPresentation("登录后自动启动已开启", false, true);
            }
            return new StartupTaskPresentation("登录后自动启动未开启", true, false);
        }
        catch (Exception error) when (
            error is IOException or UnauthorizedAccessException or System.Security.SecurityException)
        {
            return new StartupTaskPresentation("无法读取自动启动设置", false, false);
        }
    }

    private static StartupTaskPresentation EnableUnpackagedStartup()
    {
        var command = WindowsServiceExecutable.StartupCommand();
        if (command is null)
        {
            throw new InvalidOperationException("后台 Service 安装不完整，无法启用自动启动。");
        }
        using var key = Registry.CurrentUser.CreateSubKey(RunKeyPath, writable: true) ??
            throw new InvalidOperationException("无法打开当前用户的自动启动设置。");
        key.SetValue(RunValueName, command, RegistryValueKind.String);
        return new StartupTaskPresentation("登录后自动启动已开启", false, true);
    }

    private static StartupTaskPresentation DisableUnpackagedStartup()
    {
        var command = WindowsServiceExecutable.StartupCommand();
        using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: true);
        var configured = key?.GetValue(RunValueName) as string;
        if (key is not null && command is not null &&
            string.Equals(configured, command, StringComparison.OrdinalIgnoreCase))
        {
            key.DeleteValue(RunValueName, throwOnMissingValue: false);
        }
        return new StartupTaskPresentation("登录后自动启动未开启", true, false);
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetCurrentPackageFullName(
        ref uint packageFullNameLength,
        StringBuilder? packageFullName);
}
