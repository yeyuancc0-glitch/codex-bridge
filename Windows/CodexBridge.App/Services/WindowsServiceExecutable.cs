using System.ComponentModel;

namespace CodexBridge.App.Services;

internal static class WindowsServiceExecutable
{
    private const int MaximumRunCommandLength = 260;

    public static FileInfo? Resolve()
    {
        try
        {
            var file = new FileInfo(Path.Combine(
                AppContext.BaseDirectory,
                "codex-bridge-service.exe"));
            if (!file.Exists || file.LinkTarget is not null ||
                !file.Extension.Equals(".exe", StringComparison.OrdinalIgnoreCase) ||
                file.FullName.Contains('"'))
            {
                return null;
            }
            return file;
        }
        catch (Exception error) when (
            error is IOException or UnauthorizedAccessException or Win32Exception or
            System.Security.SecurityException)
        {
            return null;
        }
    }

    public static string? StartupCommand()
    {
        var file = Resolve();
        if (file is null)
        {
            return null;
        }
        var command = $"\"{file.FullName}\"";
        return command.Length <= MaximumRunCommandLength ? command : null;
    }
}
