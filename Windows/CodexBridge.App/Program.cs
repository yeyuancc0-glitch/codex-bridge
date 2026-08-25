#if DISABLE_XAML_GENERATED_MAIN
using CodexBridge.App.Services;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace CodexBridge.App;

public static class Program
{
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
}
#endif
