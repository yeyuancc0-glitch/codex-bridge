using global::Microsoft.Windows.ApplicationModel.Resources;

namespace CodexBridge.App.Services;

/// <summary>Temporary startup probes for the XamlParseException investigation; removed once resolved.</summary>
internal static class StartupProbes
{
    public static void Run(Action<string> record)
    {
        ProbePriFiles(record);
        ProbePriMap(record);
        ProbeThemeResources(record);
        ProbeCustomControls(record);
    }

    private static void ProbePriFiles(Action<string> record)
    {
        foreach (var name in new[] { "resources.pri", "CodexBridge.App.pri" })
        {
            var path = Path.Combine(AppContext.BaseDirectory, name);
            var length = File.Exists(path) ? new FileInfo(path).Length : -1;
            record($"pri-file {name} exists={File.Exists(path)} bytes={length}");
        }
        foreach (var pri in Directory.GetFiles(AppContext.BaseDirectory, "*.pri"))
        {
            record($"pri-file {Path.GetFileName(pri)} bytes={new FileInfo(pri).Length}");
        }
    }

    private static void ProbePriMap(Action<string> record)
    {
        ResourceMap map;
        try
        {
            map = new ResourceManager().MainResourceMap;
        }
        catch (Exception error)
        {
            record($"pri-map-unavailable: {error.GetType().FullName}: {error.Message}");
            return;
        }

        foreach (var key in new[]
        {
            "Files/App.xbf",
            "Files/MainWindow.xbf",
            "Files/Views/WorkbenchHost.xbf",
            "Files/WorkbenchHost.xbf",
            "Files/Views/ProjectWorkspaceView.xbf",
            "Files/ProjectWorkspaceView.xbf",
            "Files/Microsoft.UI.Xaml/Themes/generic.xaml",
            "Microsoft.UI.Xaml/Themes/generic.xaml",
        })
        {
            try
            {
                var candidate = map.GetValue(key);
                record($"pri-probe {key} => {(candidate is null ? "missing" : Describe(candidate))}");
            }
            catch (Exception error)
            {
                record($"pri-probe {key} => threw {error.GetType().Name}: {error.Message}");
            }
        }
    }

    private static string Describe(ResourceCandidate candidate)
    {
        var description = $"kind={candidate.Kind}";
        try
        {
            var value = candidate.ValueAsString();
            description += $" value={value}";
        }
        catch
        {
            description += " value=<non-string>";
        }
        return description;
    }

    private static void ProbeThemeResources(Action<string> record)
    {
        foreach (var key in new[]
        {
            "CardStrokeColorDefaultBrush",
            "SystemFillColorCautionBrush",
            "BodyStrongTextBlockStyle",
            "TitleTextBlockStyle",
        })
        {
            var xaml =
                "<TextBlock xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' "
                + $"Style='{{ThemeResource {key}}}' />";
            TryAppend(record, $"theme-resource {key}", () =>
            {
                _ = global::Microsoft.UI.Xaml.Markup.XamlReader.Load(xaml);
                return "ok";
            });
        }
    }

    private static void ProbeCustomControls(Action<string> record)
    {
        TryAppend(record, "workbench-host-ctor", () =>
        {
            _ = new Views.WorkbenchHost();
            return "ok";
        });
    }

    private static void TryAppend(Action<string> record, string label, Func<string> action)
    {
        try
        {
            record($"{label} => {action()}");
        }
        catch (Exception error)
        {
            record($"{label} => threw {error.GetType().FullName} 0x{error.HResult:x8}: {error.Message}");
        }
    }
}
