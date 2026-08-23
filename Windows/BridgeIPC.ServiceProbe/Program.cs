using System.Text.Json;
using CodexBridge.Ipc;

await using var client = new NamedPipeBridgeClient();
using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(15));
await client.ConnectAsync(TimeSpan.FromSeconds(10), deadline.Token);
var response = await client.SendAsync("status", null, deadline.Token);
var payload = BridgeServiceCodec.DecodePayload<JsonElement>(response);

var status = RequiredObject(payload, "status");
RequiredString(status, "app_version");
RequiredString(status, "mcp_state");
RequiredString(status, "execution_state");

var localMcpUrl = RequiredString(payload, "local_mcp_url");
if (!Uri.TryCreate(localMcpUrl, UriKind.Absolute, out var endpoint) ||
    endpoint.Scheme != Uri.UriSchemeHttp ||
    endpoint.Host != "127.0.0.1" ||
    endpoint.Port <= 0)
{
    throw new InvalidDataException("The service returned an invalid loopback MCP endpoint.");
}

var tunnel = RequiredObject(payload, "tunnel");
RequiredString(tunnel, "lifecycle");
Console.WriteLine("Bridge Service IPC status probe passed.");

static JsonElement RequiredObject(JsonElement parent, string name)
{
    if (!parent.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.Object)
    {
        throw new InvalidDataException($"The service response is missing object '{name}'.");
    }
    return value;
}

static string RequiredString(JsonElement parent, string name)
{
    if (!parent.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.String)
    {
        throw new InvalidDataException($"The service response is missing string '{name}'.");
    }
    return value.GetString()!;
}
