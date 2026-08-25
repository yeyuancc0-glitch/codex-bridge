namespace CodexBridge.App.Services;

internal static class StartupDiagnostics
{
    private static readonly object Gate = new();
    private static string? _logPath;

    public static void Begin()
    {
        if (_logPath is not null)
        {
            return;
        }
        try
        {
            var root = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "CodexBridge",
                "Logs");
            Directory.CreateDirectory(root);
            _logPath = Path.Combine(root, "app-startup.log");
            File.WriteAllText(_logPath, Format("process-started"));
        }
        catch
        {
            _logPath = null;
        }
    }

    public static void Record(string phase)
    {
        Write(Format(phase));
    }

    public static void Record(string phase, Exception error)
    {
        Write(Format($"{phase}: {error.GetType().FullName} 0x{error.HResult:x8} {error.Message}\n{error.StackTrace}"));
    }

    private static string Format(string message)
    {
        return $"{DateTimeOffset.UtcNow:O} pid={Environment.ProcessId} {message}{Environment.NewLine}";
    }

    private static void Write(string message)
    {
        var path = _logPath;
        if (path is null)
        {
            return;
        }
        try
        {
            lock (Gate)
            {
                File.AppendAllText(path, message);
            }
        }
        catch
        {
        }
    }
}
