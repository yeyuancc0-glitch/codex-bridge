using CodexBridge.App.Services;
using Microsoft.UI.Xaml;

namespace CodexBridge.App;

public partial class App : Application
{
    private Window? _window;

    public App()
    {
        StartupDiagnostics.Begin();
        StartupDiagnostics.Record("app-constructor");
        UnhandledException += (_, args) =>
            StartupDiagnostics.Record("application-unhandled", args.Exception);
        try
        {
            InitializeComponent();
            StartupDiagnostics.Record("app-xaml-initialized");
        }
        catch (Exception error)
        {
            StartupDiagnostics.Record("app-xaml-failed", error);
            throw;
        }
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        StartupDiagnostics.Record("app-launched");
        StartupDiagnostics.Record("startup-probes:\n" + StartupProbes.Run());
        try
        {
            _window = new MainWindow();
            StartupDiagnostics.Record("main-window-created");
            _window.Activate();
            StartupDiagnostics.Record("main-window-activated");
        }
        catch (Exception error)
        {
            StartupDiagnostics.Record("main-window-failed", error);
            throw;
        }
    }
}
