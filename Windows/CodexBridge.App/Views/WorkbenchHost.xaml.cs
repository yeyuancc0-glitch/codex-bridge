using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Web.WebView2.Core;
using System.Diagnostics;
using System.Text.Json;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace CodexBridge.App.Views;

public sealed partial class WorkbenchHost : UserControl
{
    private static readonly Uri WorkbenchUri = new("https://chatgpt.com/");
    private static readonly Uri WebViewRuntimeUri = new(
        "https://developer.microsoft.com/en-us/microsoft-edge/webview2/consumer/");
    private const string FixedRuntimeVersion = "151.0.4129.101";
    private const string ResumeUrlSetting = "workbench.resume-url";
    private const string UnpackagedDataRoot = "CodexBridge";
    private const string UnpackagedAppDirectory = "App";
    private const string UnpackagedSettingsFile = "settings.json";
    private readonly DispatcherTimer _releaseTimer = new() { Interval = TimeSpan.FromMinutes(3) };
    private WebView2? _webView;
    private nint _ownerWindow;

    public WorkbenchHost()
    {
        InitializeComponent();
        _releaseTimer.Tick += ReleaseTimerTick;
    }

    public void SetOwnerWindow(Window window)
    {
        _ownerWindow = WindowNative.GetWindowHandle(window);
    }

    public async Task ActivateAsync()
    {
        _releaseTimer.Stop();
        Visibility = Visibility.Visible;
        if (_webView is null)
        {
            await CreateWebViewAsync();
        }
    }

    public void Deactivate()
    {
        Visibility = Visibility.Collapsed;
        _releaseTimer.Start();
    }

    private async Task CreateWebViewAsync()
    {
        LoadingIndicator.IsActive = true;
        FailurePanel.Visibility = Visibility.Collapsed;
        try
        {
            var environment = await CoreWebView2Environment.CreateWithOptionsAsync(
                FixedRuntimeFolder(),
                PrepareUserDataFolder(),
                null);
            var webView = new WebView2
            {
                HorizontalAlignment = HorizontalAlignment.Stretch,
                VerticalAlignment = VerticalAlignment.Stretch,
            };
            AutomationProperties.SetName(webView, "ChatGPT 工作台");
            BrowserSurface.Children.Add(webView);
            await webView.EnsureCoreWebView2Async(environment);
            Configure(webView);
            _webView = webView;
            webView.Source = ReadResumeUri();
            PresentBrowserState();
        }
        catch (Exception error)
        {
            ReleaseWebView();
            PresentFailure($"WebView2 初始化失败：{error.Message}");
        }
        finally
        {
            LoadingIndicator.IsActive = false;
        }
    }

    private void Configure(WebView2 webView)
    {
        var core = webView.CoreWebView2;
        core.NavigationStarting += NavigationStarting;
        core.NavigationCompleted += NavigationCompleted;
        core.NewWindowRequested += NewWindowRequested;
        core.HistoryChanged += HistoryChanged;
        core.SourceChanged += SourceChanged;
        core.ProcessFailed += ProcessFailed;
        core.DownloadStarting += DownloadStarting;
        core.Settings.AreDevToolsEnabled = false;
        core.Settings.AreDefaultContextMenusEnabled = true;
        core.Settings.IsStatusBarEnabled = true;
    }

    private static void NavigationStarting(
        object? sender,
        CoreWebView2NavigationStartingEventArgs args)
    {
        if (!IsWebUri(args.Uri))
        {
            args.Cancel = true;
        }
    }

    private void NavigationCompleted(
        object? sender,
        CoreWebView2NavigationCompletedEventArgs args)
    {
        LoadingIndicator.IsActive = false;
        if (!args.IsSuccess)
        {
            PresentStatus($"页面加载失败：{args.WebErrorStatus}", InfoBarSeverity.Error);
        }
        else
        {
            WorkbenchStatus.IsOpen = false;
            SaveResumeUri();
        }
        PresentBrowserState();
    }

    private void NewWindowRequested(
        object? sender,
        CoreWebView2NewWindowRequestedEventArgs args)
    {
        if (IsWebUri(args.Uri))
        {
            _webView?.CoreWebView2.Navigate(args.Uri);
        }
        args.Handled = true;
    }

    private void HistoryChanged(object? sender, object args)
    {
        PresentBrowserState();
    }

    private void SourceChanged(object? sender, CoreWebView2SourceChangedEventArgs args)
    {
        LoadingIndicator.IsActive = true;
        PresentBrowserState();
    }

    private void ProcessFailed(object? sender, CoreWebView2ProcessFailedEventArgs args)
    {
        PresentFailure($"WebView2 进程异常退出：{args.ProcessFailedKind}");
        ReleaseWebView();
    }

    private async void DownloadStarting(
        object? sender,
        CoreWebView2DownloadStartingEventArgs args)
    {
        var deferral = args.GetDeferral();
        args.Handled = true;
        try
        {
            if (_ownerWindow == 0)
            {
                args.Cancel = true;
                PresentStatus("无法确定下载窗口。", InfoBarSeverity.Error);
                return;
            }

            var suggestedName = SafeFilename(Path.GetFileName(args.ResultFilePath));
            var picker = new FileSavePicker { SuggestedFileName = suggestedName };
            var extension = Path.GetExtension(suggestedName);
            picker.FileTypeChoices.Add(
                "下载文件",
                [string.IsNullOrEmpty(extension) ? ".download" : extension]);
            InitializeWithWindow.Initialize(picker, _ownerWindow);
            var destination = await picker.PickSaveFileAsync();
            if (destination is null || !TryValidatedDownloadPath(destination.Path, out var finalPath))
            {
                args.Cancel = true;
                return;
            }

            var directory = Path.GetDirectoryName(finalPath)!;
            var temporaryPath = Path.Combine(
                directory,
                $".codexbridge-download-{Guid.NewGuid():N}.tmp");
            args.ResultFilePath = temporaryPath;
            args.Cancel = false;
            TrackDownload(args.DownloadOperation, temporaryPath, finalPath);
            PresentStatus($"正在下载 {Path.GetFileName(finalPath)}", InfoBarSeverity.Informational);
        }
        catch (Exception error)
        {
            args.Cancel = true;
            PresentStatus($"下载未开始：{error.Message}", InfoBarSeverity.Error);
        }
        finally
        {
            deferral.Complete();
        }
    }

    private void TrackDownload(
        CoreWebView2DownloadOperation operation,
        string temporaryPath,
        string finalPath)
    {
        void StateChanged(object? sender, object args)
        {
            if (operation.State == CoreWebView2DownloadState.InProgress)
            {
                return;
            }
            operation.StateChanged -= StateChanged;
            try
            {
                if (operation.State == CoreWebView2DownloadState.Completed)
                {
                    File.Move(temporaryPath, finalPath, true);
                    DispatcherQueue.TryEnqueue(() => PresentStatus(
                        $"下载完成：{Path.GetFileName(finalPath)}",
                        InfoBarSeverity.Success));
                }
                else
                {
                    File.Delete(temporaryPath);
                    DispatcherQueue.TryEnqueue(() => PresentStatus(
                        $"下载中断：{operation.InterruptReason}",
                        InfoBarSeverity.Error));
                }
            }
            catch (Exception error)
            {
                try { File.Delete(temporaryPath); } catch { }
                DispatcherQueue.TryEnqueue(() => PresentStatus(
                    $"保存下载失败：{error.Message}",
                    InfoBarSeverity.Error));
            }
        }
        operation.StateChanged += StateChanged;
    }

    private void BackClick(object sender, RoutedEventArgs args)
    {
        if (_webView?.CanGoBack == true) { _webView.GoBack(); }
    }

    private void ForwardClick(object sender, RoutedEventArgs args)
    {
        if (_webView?.CanGoForward == true) { _webView.GoForward(); }
    }

    private void ReloadClick(object sender, RoutedEventArgs args)
    {
        _webView?.Reload();
    }

    private void OpenExternalClick(object sender, RoutedEventArgs args)
    {
        OpenExternal(CurrentWebUri() ?? WorkbenchUri);
    }

    private async void RetryClick(object sender, RoutedEventArgs args)
    {
        if (_webView is null)
        {
            await CreateWebViewAsync();
        }
    }

    private void InstallRuntimeClick(object sender, RoutedEventArgs args)
    {
        OpenExternal(WebViewRuntimeUri);
    }

    private void ReleaseTimerTick(object? sender, object args)
    {
        _releaseTimer.Stop();
        SaveResumeUri();
        ReleaseWebView();
    }

    private void ReleaseWebView()
    {
        if (_webView is not null)
        {
            _webView.Close();
        }
        BrowserSurface.Children.Clear();
        _webView = null;
        PresentBrowserState();
    }

    private void PresentBrowserState()
    {
        var core = _webView?.CoreWebView2;
        BackButton.IsEnabled = _webView?.CanGoBack == true;
        ForwardButton.IsEnabled = _webView?.CanGoForward == true;
        ReloadButton.IsEnabled = core is not null;
        ExternalBrowserButton.IsEnabled = CurrentWebUri() is not null;
        AddressLabel.Text = CurrentWebUri()?.AbsoluteUri ?? WorkbenchUri.AbsoluteUri;
    }

    private void PresentFailure(string message)
    {
        FailureMessage.Text = message;
        FailurePanel.Visibility = Visibility.Visible;
        PresentStatus(message, InfoBarSeverity.Error);
        PresentBrowserState();
    }

    private void PresentStatus(string message, InfoBarSeverity severity)
    {
        WorkbenchStatus.Message = message;
        WorkbenchStatus.Severity = severity;
        WorkbenchStatus.IsOpen = true;
    }

    private Uri? CurrentWebUri()
    {
        var source = _webView?.Source;
        return source is not null && IsWebUri(source.AbsoluteUri) ? source : null;
    }

    private void SaveResumeUri()
    {
        var uri = CurrentWebUri();
        if (uri is not null && IsSafeResumeUri(uri))
        {
            SaveUnpackagedSetting(ResumeUrlSetting, uri.AbsoluteUri);
        }
    }

    private static Uri ReadResumeUri()
    {
        var value = ReadUnpackagedSetting(ResumeUrlSetting);
        return Uri.TryCreate(value, UriKind.Absolute, out var uri) && IsSafeResumeUri(uri)
            ? uri
            : WorkbenchUri;
    }

    private static bool IsSafeResumeUri(Uri uri)
    {
        return uri.Scheme == Uri.UriSchemeHttps &&
            (uri.Host.Equals("chatgpt.com", StringComparison.OrdinalIgnoreCase) ||
             uri.Host.EndsWith(".chatgpt.com", StringComparison.OrdinalIgnoreCase));
    }

    private static bool IsWebUri(string value)
    {
        return Uri.TryCreate(value, UriKind.Absolute, out var uri) &&
            (uri.Scheme == Uri.UriSchemeHttp || uri.Scheme == Uri.UriSchemeHttps);
    }

    private static string PrepareUserDataFolder()
    {
        var folder = Path.Combine(GetUnpackagedAppDirectory(), "WebView2");
        EnsureDirectory(folder, "WebView2 数据目录不能是重解析点。");
        return folder;
    }

    private static string ReadUnpackagedSetting(string key)
    {
        var path = Path.Combine(GetUnpackagedAppDirectory(), UnpackagedSettingsFile);
        if (!File.Exists(path) || IsReparsePoint(path))
        {
            return string.Empty;
        }

        try
        {
            var values = JsonSerializer.Deserialize<Dictionary<string, string>>(
                File.ReadAllText(path));
            return values is not null && values.TryGetValue(key, out var value) ? value : string.Empty;
        }
        catch (JsonException)
        {
            return string.Empty;
        }
        catch (IOException)
        {
            return string.Empty;
        }
        catch (UnauthorizedAccessException)
        {
            return string.Empty;
        }
    }

    private static void SaveUnpackagedSetting(string key, string value)
    {
        var directory = GetUnpackagedAppDirectory();
        var path = Path.Combine(directory, UnpackagedSettingsFile);
        if (File.Exists(path) && IsReparsePoint(path))
        {
            throw new IOException("Codex Bridge 设置文件不能是重解析点。");
        }
        var values = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            [key] = value,
        };
        var temporaryPath = Path.Combine(directory, $".{UnpackagedSettingsFile}.{Guid.NewGuid():N}.tmp");
        try
        {
            File.WriteAllText(temporaryPath, JsonSerializer.Serialize(values));
            File.Move(temporaryPath, path, true);
        }
        finally
        {
            try { File.Delete(temporaryPath); } catch { }
        }
    }

    private static string GetUnpackagedAppDirectory()
    {
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (string.IsNullOrWhiteSpace(localAppData))
        {
            throw new InvalidOperationException("无法确定本机应用数据目录。");
        }

        var root = Path.Combine(localAppData, UnpackagedDataRoot);
        EnsureDirectory(root, "Codex Bridge 数据目录不能是重解析点。");
        var appDirectory = Path.Combine(root, UnpackagedAppDirectory);
        EnsureDirectory(appDirectory, "Codex Bridge App 数据目录不能是重解析点。");
        return appDirectory;
    }

    private static void EnsureDirectory(string path, string reparseMessage)
    {
        if (Directory.Exists(path) && IsReparsePoint(path))
        {
            throw new IOException(reparseMessage);
        }
        Directory.CreateDirectory(path);
    }

    private static bool IsReparsePoint(string path)
    {
        return (File.GetAttributes(path) & System.IO.FileAttributes.ReparsePoint) != 0;
    }

    private static string? FixedRuntimeFolder()
    {
        var folder = Path.Combine(AppContext.BaseDirectory, "FixedRuntime", FixedRuntimeVersion);
        return File.Exists(Path.Combine(folder, "msedgewebview2.exe")) ? folder : null;
    }

    private static bool TryValidatedDownloadPath(string value, out string path)
    {
        path = string.Empty;
        if (string.IsNullOrWhiteSpace(value) || value.StartsWith("\\\\", StringComparison.Ordinal))
        {
            return false;
        }
        var fullPath = Path.GetFullPath(value);
        var directory = Path.GetDirectoryName(fullPath);
        if (directory is null || !Directory.Exists(directory) || HasReparseAncestor(directory))
        {
            return false;
        }
        path = fullPath;
        return true;
    }

    private static bool HasReparseAncestor(string directory)
    {
        for (var current = new DirectoryInfo(directory); current is not null; current = current.Parent)
        {
            if ((current.Attributes & System.IO.FileAttributes.ReparsePoint) != 0)
            {
                return true;
            }
        }
        return false;
    }

    private static string SafeFilename(string value)
    {
        var invalid = Path.GetInvalidFileNameChars().ToHashSet();
        var cleaned = new string(value.Select(character =>
            invalid.Contains(character) || char.IsControl(character) ? '_' : character).ToArray())
            .Trim()
            .TrimEnd('.', ' ');
        if (cleaned.Length == 0)
        {
            return "download";
        }
        if (cleaned.Length > 128)
        {
            var extension = Path.GetExtension(cleaned);
            var nameLength = Math.Max(1, 128 - extension.Length);
            cleaned = cleaned[..nameLength] + extension;
        }
        var stem = Path.GetFileNameWithoutExtension(cleaned);
        if (ReservedNames.Contains(stem))
        {
            cleaned = "_" + cleaned;
        }
        return cleaned;
    }

    private static readonly HashSet<string> ReservedNames = new(
        new[] { "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5",
            "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5",
            "LPT6", "LPT7", "LPT8", "LPT9" },
        StringComparer.OrdinalIgnoreCase);

    private static void OpenExternal(Uri uri)
    {
        Process.Start(new ProcessStartInfo(uri.AbsoluteUri) { UseShellExecute = true });
    }
}
