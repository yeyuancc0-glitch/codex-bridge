using System.Text.Json;
using System.Text.Json.Serialization;

namespace CodexBridge.Ipc;

public static class BridgeServiceCodec
{
    public const int SchemaVersion = 3;

    private static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    public static JsonElement Request<T>(string operation, T? payload, string requestId)
    {
        ValidateIdentifier(operation, nameof(operation));
        ValidateIdentifier(requestId, nameof(requestId));
        string? encodedPayload = null;
        if (payload is not null)
        {
            var payloadBytes = JsonSerializer.SerializeToUtf8Bytes(payload, Options);
            encodedPayload = Convert.ToBase64String(payloadBytes);
        }

        return JsonSerializer.SerializeToElement(
            new ServiceRequest(SchemaVersion, requestId, operation, encodedPayload),
            Options);
    }

    public static string ResponseRequestId(JsonElement response)
    {
        EnsureSchema(response);
        if (!response.TryGetProperty("request_id", out var requestId) ||
            requestId.ValueKind != JsonValueKind.String)
        {
            throw new BridgeProtocolException("Response request_id is missing.");
        }
        var value = requestId.GetString()!;
        ValidateIdentifier(value, "request_id");
        return value;
    }

    public static T DecodePayload<T>(JsonElement response)
    {
        EnsureSchema(response);
        if (response.TryGetProperty("error", out var error))
        {
            throw new BridgeRemoteException(JsonSerializer.Deserialize<BridgeRemoteError>(error, Options));
        }
        if (!response.TryGetProperty("payload", out var payload) ||
            payload.ValueKind != JsonValueKind.String)
        {
            throw new BridgeProtocolException("Response payload is missing.");
        }
        try
        {
            var bytes = Convert.FromBase64String(payload.GetString()!);
            return JsonSerializer.Deserialize<T>(bytes, Options)
                ?? throw new BridgeProtocolException("Response payload is empty.");
        }
        catch (FormatException formatError)
        {
            throw new BridgeProtocolException("Response payload is not valid base64.", formatError);
        }
        catch (JsonException jsonError)
        {
            throw new BridgeProtocolException("Response payload JSON is invalid.", jsonError);
        }
    }

    public static T DecodeEvent<T>(JsonElement message)
    {
        if (message.ValueKind != JsonValueKind.Object)
        {
            throw new BridgeProtocolException("Event payload must be a JSON object.");
        }
        try
        {
            return JsonSerializer.Deserialize<T>(message, Options)
                ?? throw new BridgeProtocolException("Event payload is empty.");
        }
        catch (JsonException jsonError)
        {
            throw new BridgeProtocolException("Event payload JSON is invalid.", jsonError);
        }
    }

    private static void EnsureSchema(JsonElement message)
    {
        if (!message.TryGetProperty("schema_version", out var schema) ||
            schema.GetInt32() != SchemaVersion)
        {
            throw new BridgeProtocolException("Service schema version is unsupported.");
        }
    }

    private static void ValidateIdentifier(string value, string name)
    {
        if (string.IsNullOrWhiteSpace(value) || value.Length > 128 ||
            value != value.Trim() || value.Any(char.IsControl))
        {
            throw new ArgumentException("Identifier is invalid.", name);
        }
    }

    private sealed record ServiceRequest(
        int SchemaVersion,
        string RequestId,
        string Operation,
        string? Payload);
}

public sealed record BridgeRemoteError(
    string Code,
    string Message,
    bool Retryable,
    string? Owner,
    string? TaskId,
    string? OperationId,
    string? SessionId);

public sealed class BridgeRemoteException : Exception
{
    public BridgeRemoteError? RemoteError { get; }

    public BridgeRemoteException(BridgeRemoteError? error)
        : base(error?.Message ?? "The Bridge service returned an invalid error.")
    {
        RemoteError = error;
    }
}
