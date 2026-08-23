using System.Text.Json;

namespace CodexBridge.Ipc;

public enum BridgeWireMessageKind
{
    Request,
    Response,
    Event,
}

public sealed record BridgeWireMessage(BridgeWireMessageKind Kind, JsonElement Message);

public static class BridgeWireCodec
{
    public const int MaximumMessageBytes = 8 * 1024 * 1024;

    public static byte[] Encode(BridgeWireMessageKind kind, JsonElement message)
    {
        EnsureObject(message);
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream))
        {
            writer.WriteStartObject();
            writer.WritePropertyName("message");
            message.WriteTo(writer);
            writer.WriteString("type", WireName(kind));
            writer.WriteEndObject();
        }

        if (stream.Length > MaximumMessageBytes)
        {
            throw new BridgeProtocolException("Wire message exceeds the 8 MiB limit.");
        }
        return stream.ToArray();
    }

    public static BridgeWireMessage Decode(ReadOnlyMemory<byte> bytes)
    {
        if (bytes.IsEmpty || bytes.Length > MaximumMessageBytes)
        {
            throw new BridgeProtocolException("Wire message size is invalid.");
        }

        try
        {
            using var document = JsonDocument.Parse(bytes, new JsonDocumentOptions { MaxDepth = 64 });
            var root = document.RootElement;
            EnsureObject(root);
            if (root.EnumerateObject().Count() != 2 ||
                !root.TryGetProperty("type", out var type) ||
                type.ValueKind != JsonValueKind.String ||
                !root.TryGetProperty("message", out var message))
            {
                throw new BridgeProtocolException("Wire message shape is invalid.");
            }
            EnsureObject(message);
            return new BridgeWireMessage(ParseKind(type.GetString()), message.Clone());
        }
        catch (JsonException error)
        {
            throw new BridgeProtocolException("Wire message JSON is invalid.", error);
        }
    }

    private static void EnsureObject(JsonElement value)
    {
        if (value.ValueKind != JsonValueKind.Object)
        {
            throw new BridgeProtocolException("Wire message payload must be a JSON object.");
        }
    }

    private static string WireName(BridgeWireMessageKind kind) => kind switch
    {
        BridgeWireMessageKind.Request => "request",
        BridgeWireMessageKind.Response => "response",
        BridgeWireMessageKind.Event => "event",
        _ => throw new BridgeProtocolException("Wire message type is unsupported."),
    };

    private static BridgeWireMessageKind ParseKind(string? value) => value switch
    {
        "request" => BridgeWireMessageKind.Request,
        "response" => BridgeWireMessageKind.Response,
        "event" => BridgeWireMessageKind.Event,
        _ => throw new BridgeProtocolException("Wire message type is unsupported."),
    };
}

public sealed class BridgeProtocolException : Exception
{
    public BridgeProtocolException(string message) : base(message) { }

    public BridgeProtocolException(string message, Exception innerException)
        : base(message, innerException) { }
}
