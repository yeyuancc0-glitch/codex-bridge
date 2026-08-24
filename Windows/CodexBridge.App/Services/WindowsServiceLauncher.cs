using System.ComponentModel;
using System.Diagnostics;

namespace CodexBridge.App.Services;

public static class WindowsServiceLauncher
{
    private static int _launchAttempted;

    public static bool TryStartOnce()
    {
        if (Interlocked.Exchange(ref _launchAttempted, 1) != 0)
        {
            return false;
        }

        var file = WindowsServiceExecutable.Resolve();
        if (file is null)
        {
            return false;
        }

        try
        {
            var process = Process.Start(new ProcessStartInfo
            {
                FileName = file.FullName,
                WorkingDirectory = AppContext.BaseDirectory,
                UseShellExecute = false,
                CreateNoWindow = true,
            });
            process?.Dispose();
            return process is not null;
        }
        catch (Exception error) when (
            error is IOException or UnauthorizedAccessException or Win32Exception)
        {
            return false;
        }
    }
}
