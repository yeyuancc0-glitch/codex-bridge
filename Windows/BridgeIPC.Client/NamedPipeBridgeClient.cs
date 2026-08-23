using System.Buffers.Binary;
using System.Collections.Concurrent;
using System.IO.Pipes;
using System.Security.Principal;
using System.Text.Json;

namespace CodexBridge.Ipc;

public sealed class NamedPipeBridgeClient : IAsyncDisposable
{
    public static string PipeName { get; } = CurrentUserPipeName();

    private readonly ConcurrentDictionary<string, TaskCompletionSource<JsonElement>> _pending = new();
    private readonly SemaphoreSlim _writeLock = new(1, 1);
    private readonly CancellationTokenSource _lifetime = new();
    private NamedPipeClientStream? _pipe;
    private Task? _reader;

    public event EventHandler<JsonElement>? EventReceived;

    public bool IsConnected => _pipe?.IsConnected == true;

    public async Task ConnectAsync(TimeSpan timeout, CancellationToken cancellationToken = default)
    {
        if (_pipe is not null)
        {
            throw new InvalidOperationException("The client has already been started.");
        }
        var pipe = new NamedPipeClientStream(
            ".",
            PipeName,
            PipeDirection.InOut,
            PipeOptions.Asynchronous);
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(
            cancellationToken,
            _lifetime.Token);
        deadline.CancelAfter(timeout);
        try
        {
            await pipe.ConnectAsync(deadline.Token).ConfigureAwait(false);
        }
        catch
        {
            await pipe.DisposeAsync().ConfigureAwait(false);
            throw;
        }
        _pipe = pipe;
        _reader = ReadLoopAsync(pipe, _lifetime.Token);
    }

    public async Task<JsonElement> SendAsync(
        string operation,
        object? payload,
        CancellationToken cancellationToken = default)
    {
        var pipe = _pipe;
        if (pipe?.IsConnected != true)
        {
            throw new IOException("The Bridge service pipe is not connected.");
        }
        var requestId = Guid.NewGuid().ToString("D").ToLowerInvariant();
        var request = BridgeServiceCodec.Request(operation, payload, requestId);
        var wire = BridgeWireCodec.Encode(BridgeWireMessageKind.Request, request);
        var completion = new TaskCompletionSource<JsonElement>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        if (!_pending.TryAdd(requestId, completion))
        {
            throw new InvalidOperationException("Duplicate request identifier.");
        }

        try
        {
            await WriteFrameAsync(pipe, wire, cancellationToken).ConfigureAwait(false);
            return await completion.Task.WaitAsync(cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _pending.TryRemove(requestId, out _);
        }
    }

    public async ValueTask DisposeAsync()
    {
        _lifetime.Cancel();
        if (_pipe is not null)
        {
            await _pipe.DisposeAsync().ConfigureAwait(false);
        }
        if (_reader is not null)
        {
            try { await _reader.ConfigureAwait(false); }
            catch (OperationCanceledException) { }
            catch (IOException) { }
        }
        FailPending(new IOException("The Bridge service pipe disconnected."));
        _writeLock.Dispose();
        _lifetime.Dispose();
    }

    private async Task ReadLoopAsync(Stream pipe, CancellationToken cancellationToken)
    {
        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                var frame = await ReadFrameAsync(pipe, cancellationToken).ConfigureAwait(false);
                var wire = BridgeWireCodec.Decode(frame);
                Dispatch(wire);
            }
        }
        catch (Exception error) when (error is IOException or OperationCanceledException or BridgeProtocolException)
        {
            FailPending(error);
            if (error is not OperationCanceledException) { throw; }
        }
    }

    private void Dispatch(BridgeWireMessage wire)
    {
        switch (wire.Kind)
        {
            case BridgeWireMessageKind.Response:
                var requestId = BridgeServiceCodec.ResponseRequestId(wire.Message);
                if (_pending.TryRemove(requestId, out var completion))
                {
                    completion.TrySetResult(wire.Message);
                }
                break;
            case BridgeWireMessageKind.Event:
                EventReceived?.Invoke(this, wire.Message);
                break;
            default:
                throw new BridgeProtocolException("The service sent a request to the client.");
        }
    }

    private async Task WriteFrameAsync(Stream pipe, byte[] message, CancellationToken cancellationToken)
    {
        if (message.Length > BridgeWireCodec.MaximumMessageBytes)
        {
            throw new BridgeProtocolException("Wire message exceeds the 8 MiB limit.");
        }
        var header = new byte[sizeof(uint)];
        BinaryPrimitives.WriteUInt32LittleEndian(header, checked((uint)message.Length));
        await _writeLock.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await pipe.WriteAsync(header, cancellationToken).ConfigureAwait(false);
            await pipe.WriteAsync(message, cancellationToken).ConfigureAwait(false);
            await pipe.FlushAsync(cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _writeLock.Release();
        }
    }

    private static async Task<byte[]> ReadFrameAsync(Stream pipe, CancellationToken cancellationToken)
    {
        var header = new byte[sizeof(uint)];
        await pipe.ReadExactlyAsync(header, cancellationToken).ConfigureAwait(false);
        var length = BinaryPrimitives.ReadUInt32LittleEndian(header);
        if (length == 0 || length > BridgeWireCodec.MaximumMessageBytes)
        {
            throw new BridgeProtocolException("Frame length is invalid.");
        }
        var body = GC.AllocateUninitializedArray<byte>(checked((int)length));
        await pipe.ReadExactlyAsync(body, cancellationToken).ConfigureAwait(false);
        return body;
    }

    private void FailPending(Exception error)
    {
        foreach (var entry in _pending.ToArray())
        {
            if (_pending.TryRemove(entry.Key, out var completion))
            {
                completion.TrySetException(error);
            }
        }
    }

    private static string CurrentUserPipeName()
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("Bridge Named Pipe IPC requires Windows.");
        }
        var sid = WindowsIdentity.GetCurrent().User?.Value;
        if (string.IsNullOrEmpty(sid) || !sid.StartsWith("S-1-", StringComparison.Ordinal) ||
            sid.Length > 184 || sid.Any(character =>
                !char.IsAsciiLetterOrDigit(character) && character != '-'))
        {
            throw new InvalidOperationException("The current Windows user SID is unavailable.");
        }
        return $"org.codexbridge.service.{sid}";
    }
}
