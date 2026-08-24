using CodexBridge.App.Models;
using CodexBridge.Ipc;
using System.Text.Json;

namespace CodexBridge.App.Services;

public sealed class BridgeConnection : IAsyncDisposable
{
    private readonly SemaphoreSlim _connectLock = new(1, 1);
    private NamedPipeBridgeClient? _client;

    public event EventHandler<JsonElement>? EventReceived;

    public bool IsConnected => _client?.IsConnected == true;

    public async Task<ServiceStatusResponse> GetStatusAsync(CancellationToken cancellationToken)
    {
        return await SendAsync<ServiceStatusResponse>("status", null, cancellationToken)
            .ConfigureAwait(false);
    }

    public async Task<T> SendAsync<T>(
        string operation,
        object? payload,
        CancellationToken cancellationToken)
    {
        var client = await ConnectedClientAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var response = await client.SendAsync(operation, payload, cancellationToken)
                .ConfigureAwait(false);
            return BridgeServiceCodec.DecodePayload<T>(response);
        }
        catch (Exception error) when (error is IOException or BridgeProtocolException)
        {
            await ResetClientAsync(client).ConfigureAwait(false);
            throw;
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (_client is not null)
        {
            _client.EventReceived -= ForwardEvent;
            await _client.DisposeAsync().ConfigureAwait(false);
            _client = null;
        }
        _connectLock.Dispose();
    }

    private async Task<NamedPipeBridgeClient> ConnectedClientAsync(
        CancellationToken cancellationToken)
    {
        await _connectLock.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (_client?.IsConnected == true)
            {
                return _client;
            }
            if (_client is not null)
            {
                _client.EventReceived -= ForwardEvent;
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
            client.EventReceived += ForwardEvent;
            _client = client;
            return client;
        }
        finally
        {
            _connectLock.Release();
        }
    }

    private async Task ResetClientAsync(NamedPipeBridgeClient failedClient)
    {
        await _connectLock.WaitAsync().ConfigureAwait(false);
        try
        {
            if (!ReferenceEquals(_client, failedClient))
            {
                return;
            }
            _client = null;
            failedClient.EventReceived -= ForwardEvent;
            await failedClient.DisposeAsync().ConfigureAwait(false);
        }
        finally
        {
            _connectLock.Release();
        }
    }

    private void ForwardEvent(object? sender, JsonElement message)
    {
        EventReceived?.Invoke(this, message);
    }
}
