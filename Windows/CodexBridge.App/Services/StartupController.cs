using Microsoft.Win32;

namespace CodexBridge.App.Services;

public sealed record StartupPresentation(
    string State,
    bool CanRequestEnable,
    bool CanRequestDisable);

public static class StartupController
{
    private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string RunValueName = "CodexBridgeService";

    public static StartupPresentation Read()
    {
        var command = WindowsServiceExecutable.StartupCommand();
        if (command is null)
        {
            return new StartupPresentation("后台 Service 安装不完整", false, false);
        }

        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: false);
            var configured = key?.GetValue(RunValueName) as string;
            return string.Equals(configured, command, StringComparison.OrdinalIgnoreCase)
                ? new StartupPresentation("登录后自动启动已开启", false, true)
                : new StartupPresentation("登录后自动启动未开启", true, false);
        }
        catch (Exception error) when (
            error is IOException or UnauthorizedAccessException or System.Security.SecurityException)
        {
            return new StartupPresentation("无法读取自动启动设置", false, false);
        }
    }

    public static StartupPresentation Enable()
    {
        var command = WindowsServiceExecutable.StartupCommand();
        if (command is null)
        {
            throw new InvalidOperationException("后台 Service 安装不完整，无法启用自动启动。");
        }

        using var key = Registry.CurrentUser.CreateSubKey(RunKeyPath, writable: true) ??
            throw new InvalidOperationException("无法打开当前用户的自动启动设置。");
        key.SetValue(RunValueName, command, RegistryValueKind.String);
        return new StartupPresentation("登录后自动启动已开启", false, true);
    }

    public static StartupPresentation Disable()
    {
        var command = WindowsServiceExecutable.StartupCommand();
        using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: true);
        var configured = key?.GetValue(RunValueName) as string;
        if (key is not null && command is not null &&
            string.Equals(configured, command, StringComparison.OrdinalIgnoreCase))
        {
            key.DeleteValue(RunValueName, throwOnMissingValue: false);
        }

        return new StartupPresentation("登录后自动启动未开启", true, false);
    }
}
