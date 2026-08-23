using CodexBridge.App.Models;
using CodexBridge.Ipc;

namespace CodexBridge.App.Services;

public sealed class BridgeConnection : IAsyncDisposable
{
    private NamedPipeBridgeClient? _client;

    public bool IsConnected => _client?.IsConnected == true;

    public async Task<ServiceStatusResponse> GetStatusAsync(CancellationToken cancellationToken)
    {
        var client = await ConnectedClientAsync(cancellationToken).ConfigureAwait(false);
        var response = await client.SendAsync("status", null, cancellationToken).ConfigureAwait(false);
        return BridgeServiceCodec.DecodePayload<ServiceStatusResponse>(response);
    }

    public async ValueTask DisposeAsync()
    {
        if (_client is not null)
        {
            await _client.DisposeAsync().ConfigureAwait(false);
            _client = null;
        }
    }

    private async Task<NamedPipeBridgeClient> ConnectedClientAsync(
        CancellationToken cancellationToken)
    {
        if (_client?.IsConnected == true)
        {
            return _client;
        }

        if (_client is not null)
        {
            await _client.DisposeAsync().ConfigureAwait(false);
        }

        var client = new NamedPipeBridgeClient();
        try
        {
            await client.ConnectAsync(TimeSpan.FromSeconds(2), cancellationToken)
                .ConfigureAwait(false);
        }
        catch
        {
            await client.DisposeAsync().ConfigureAwait(false);
            throw;
        }
        _client = client;
        return client;
    }
}
