using System.Runtime.Versioning;
using System.Text.Json;
using System.Security.Principal;
using CodexBridge.Ipc;

namespace BridgeIPC.Client.Tests;

public sealed class ProtocolValidationTests
{
    [Fact]
    [SupportedOSPlatform("windows")]
    public void PipeNameIsScopedToCurrentWindowsUser()
    {
        Assert.True(OperatingSystem.IsWindows());
        var sid = WindowsIdentity.GetCurrent().User!.Value;
        Assert.Equal($"org.codexbridge.service.{sid}", NamedPipeBridgeClient.PipeName);
    }

    [Theory]
    [InlineData("{\"type\":\"unknown\",\"message\":{}}")]
    [InlineData("{\"type\":\"response\",\"message\":[]}")]
    [InlineData("{\"type\":\"response\",\"message\":{},\"extra\":true}")]
    public void WireCodecRejectsInvalidEnvelopes(string json)
    {
        Assert.Throws<BridgeProtocolException>(() => BridgeWireCodec.Decode(
            System.Text.Encoding.UTF8.GetBytes(json)));
    }

    [Fact]
    public void WireCodecRejectsOversizeBeforeParsing()
    {
        var hostile = new byte[BridgeWireCodec.MaximumMessageBytes + 1];
        Assert.Throws<BridgeProtocolException>(() => BridgeWireCodec.Decode(hostile));
    }

    [Fact]
    public void ResponseDecoderRejectsMalformedBase64()
    {
        using var document = JsonDocument.Parse(
            "{\"schema_version\":3,\"request_id\":\"request-1\",\"payload\":\"%%%\"}");
        Assert.Throws<BridgeProtocolException>(() =>
            BridgeServiceCodec.DecodePayload<object>(document.RootElement));
    }

    [Fact]
    public void ResponseDecoderPreservesStructuredRemoteError()
    {
        using var document = JsonDocument.Parse("""
            {
              "schema_version": 3,
              "request_id": "request-1",
              "error": {
                "code": "path_denied",
                "message": "Denied.",
                "retryable": false
              }
            }
            """);
        var error = Assert.Throws<BridgeRemoteException>(() =>
            BridgeServiceCodec.DecodePayload<object>(document.RootElement));
        Assert.NotNull(error.RemoteError);
        Assert.Equal("path_denied", error.RemoteError.Code);
        Assert.False(error.RemoteError.Retryable);
    }
}
