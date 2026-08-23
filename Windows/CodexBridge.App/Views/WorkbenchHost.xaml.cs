using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Web.WebView2.Core;

namespace CodexBridge.App.Views;

public sealed partial class WorkbenchHost : UserControl
{
    private static readonly Uri WorkbenchUri = new("https://chatgpt.com/");
    private readonly DispatcherTimer _releaseTimer = new() { Interval = TimeSpan.FromMinutes(3) };
    private WebView2? _webView;

    public WorkbenchHost()
    {
        InitializeComponent();
        _releaseTimer.Tick += ReleaseTimerTick;
    }

    public async Task ActivateAsync()
    {
        _releaseTimer.Stop();
        if (_webView is null)
        {
            await CreateWebViewAsync();
        }
        Visibility = Visibility.Visible;
    }

    public void Deactivate()
    {
        Visibility = Visibility.Collapsed;
        _releaseTimer.Start();
    }

    private async Task CreateWebViewAsync()
    {
        var userDataFolder = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "CodexBridge",
            "WebView2");
        Directory.CreateDirectory(userDataFolder);
        var environment = await CoreWebView2Environment.CreateWithOptionsAsync(
            null,
            userDataFolder,
            null);
        var webView = new WebView2();
        BrowserRoot.Children.Add(webView);
        await webView.EnsureCoreWebView2Async(environment);
        webView.CoreWebView2.NavigationStarting += NavigationStarting;
        webView.CoreWebView2.NewWindowRequested += NewWindowRequested;
        webView.Source = WorkbenchUri;
        _webView = webView;
    }

    private static void NavigationStarting(
        object? sender,
        CoreWebView2NavigationStartingEventArgs args)
    {
        if (!Uri.TryCreate(args.Uri, UriKind.Absolute, out var uri) ||
            (uri.Scheme != Uri.UriSchemeHttp && uri.Scheme != Uri.UriSchemeHttps))
        {
            args.Cancel = true;
        }
    }

    private void NewWindowRequested(
        object? sender,
        CoreWebView2NewWindowRequestedEventArgs args)
    {
        if (Uri.TryCreate(args.Uri, UriKind.Absolute, out var uri) &&
            (uri.Scheme == Uri.UriSchemeHttp || uri.Scheme == Uri.UriSchemeHttps))
        {
            _webView?.CoreWebView2?.Navigate(uri.AbsoluteUri);
        }
        args.Handled = true;
    }

    private void ReleaseTimerTick(object? sender, object e)
    {
        _releaseTimer.Stop();
        if (_webView is null)
        {
            return;
        }
        _webView.Close();
        BrowserRoot.Children.Clear();
        _webView = null;
    }
}
