using System.Text;
using global::Microsoft.Windows.ApplicationModel.Resources;

namespace CodexBridge.App.Services;

/// <summary>Temporary startup probes for the XamlParseException investigation; removed once resolved.</summary>
internal static class StartupProbes
{
    public static string Run()
    {
        var report = new StringBuilder();
        ProbePriFiles(report);
        ProbePriMap(report);
        ProbeCustomControls(report);
        ProbeThemeResources(report);
        ProbeNavigationSymbols(report);
        return report.ToString();
    }

    private static void ProbePriFiles(StringBuilder report)
    {
        foreach (var name in new[] { "resources.pri", "CodexBridge.App.pri" })
        {
            var path = Path.Combine(AppContext.BaseDirectory, name);
            var length = File.Exists(path) ? new FileInfo(path).Length : -1;
            report.AppendLine($"pri-file {name} exists={File.Exists(path)} bytes={length}");
        }
    }

    private static void ProbePriMap(StringBuilder report)
    {
        try
        {
            var map = new ResourceManager().MainResourceMap;
            foreach (var key in new[]
            {
                "Files/App.xbf",
                "Files/MainWindow.xbf",
                "Files/Views/WorkbenchHost.xbf",
                "Files/WorkbenchHost.xbf",
                "Files/Views/ProjectWorkspaceView.xbf",
                "Files/ProjectWorkspaceView.xbf",
                "Files/Views/WorkbenchHost.xaml",
                "Files/WorkbenchHost.xaml",
            })
            {
                try
                {
                    var candidate = map.GetValue(key);
                    report.AppendLine($"pri-probe {key} => {(candidate is null ? "missing" : $"kind={candidate.Kind}")}");
                }
                catch (Exception error)
                {
                    report.AppendLine($"pri-probe {key} => threw {error.GetType().Name}: {error.Message}");
                }
            }
        }
        catch (Exception error)
        {
            report.AppendLine($"pri-map-unavailable: {error.GetType().FullName}: {error.Message}");
        }
    }

    private static void ProbeCustomControls(StringBuilder report)
    {
        TryAppend(report, "workbench-host-ctor", () =>
        {
            _ = new Views.WorkbenchHost();
            return "ok";
        });
        TryAppend(report, "project-workspace-view-ctor", () =>
        {
            var project = new Models.ProjectSummary(
                "probe",
                "probe",
                new Models.ProjectCapabilities("denied", "denied", "denied"),
                null);
            _ = new Views.ProjectWorkspaceView(null!, project, default);
            return "ok";
        });
    }

    private static void ProbeThemeResources(StringBuilder report)
    {
        foreach (var key in new[]
        {
            "CardStrokeColorDefaultBrush",
            "SystemFillColorCautionBrush",
            "BodyStrongTextBlockStyle",
            "TitleTextBlockStyle",
            "SubtitleTextBlockStyle",
            "CaptionTextBlockStyle",
            "ApplicationPageBackgroundThemeBrush",
        })
        {
            var xaml =
                "<TextBlock xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' "
                + $"Style='{{ThemeResource {key}}}' />";
            TryAppend(report, $"theme-resource {key}", () =>
            {
                _ = global::Microsoft.UI.Xaml.Markup.XamlReader.Load(xaml);
                return "ok";
            });
        }
    }

    private static void ProbeNavigationSymbols(StringBuilder report)
    {
        foreach (var symbol in new[] { "Home", "AllApps", "Folder", "Important", "World", "Globe" })
        {
            var xaml =
                "<NavigationViewItem xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' "
                + $"Icon='{symbol}' />";
            TryAppend(report, $"symbol {symbol}", () =>
            {
                _ = global::Microsoft.UI.Xaml.Markup.XamlReader.Load(xaml);
                return "ok";
            });
        }
    }

    private static void TryAppend(StringBuilder report, string label, Func<string> action)
    {
        try
        {
            report.AppendLine($"{label} => {action()}");
        }
        catch (Exception error)
        {
            report.AppendLine(
                $"{label} => threw {error.GetType().FullName} 0x{error.HResult:x8}: {error.Message}");
        }
    }
}
