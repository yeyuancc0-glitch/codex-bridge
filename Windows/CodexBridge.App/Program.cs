#if DISABLE_XAML_GENERATED_MAIN
using CodexBridge.App.Services;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using System.Runtime.InteropServices;

namespace CodexBridge.App;

public static class Program
{
    [DllImport("Microsoft.WindowsAppRuntime.dll", ExactSpelling = true)]
    private static extern int WindowsAppRuntime_EnsureIsLoaded();

    [STAThread]
    public static int Main(string[] args)
    {
        StartupDiagnostics.Begin();
        StartupDiagnostics.Record("main-entered");
        AppDomain.CurrentDomain.UnhandledException += (_, eventArgs) =>
        {
            if (eventArgs.ExceptionObject is Exception error)
            {
                StartupDiagnostics.Record("appdomain-unhandled", error);
            }
        };
        TaskScheduler.UnobservedTaskException += (_, eventArgs) =>
            StartupDiagnostics.Record("task-unobserved", eventArgs.Exception);

        try
        {
            InitializeSelfContainedRuntime();
            WinRT.ComWrappersSupport.InitializeComWrappers();
            StartupDiagnostics.Record("com-wrappers-initialized");
            Application.Start(_initialization =>
            {
                StartupDiagnostics.Record("application-start-callback");
                var queue = DispatcherQueue.GetForCurrentThread();
                SynchronizationContext.SetSynchronizationContext(
                    new DispatcherQueueSynchronizationContext(queue));
                try
                {
                    new App();
                    StartupDiagnostics.Record("app-created");
                }
                catch (Exception error)
                {
                    StartupDiagnostics.Record("app-constructor-failed", error);
                    throw;
                }
            });
            StartupDiagnostics.Record("application-start-returned");
            return 0;
        }
        catch (Exception error)
        {
            StartupDiagnostics.Record("main-failed", error);
            return 1;
        }
    }

    private static void InitializeSelfContainedRuntime()
    {
        Environment.SetEnvironmentVariable(
            "MICROSOFT_WINDOWSAPPRUNTIME_BASE_DIRECTORY",
            AppContext.BaseDirectory);
        Environment.SetEnvironmentVariable(
            "MICROSOFT_WINDOWSAPPRUNTIME_BASE_DIRECTORY_PID",
            Environment.ProcessId.ToString(System.Globalization.CultureInfo.InvariantCulture));
        StartupDiagnostics.Record("windows-app-runtime-loading");
        Marshal.ThrowExceptionForHR(WindowsAppRuntime_EnsureIsLoaded());
        StartupDiagnostics.Record("windows-app-runtime-loaded");
    }
}
#endif
