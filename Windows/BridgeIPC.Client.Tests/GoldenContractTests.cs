using System.Text.Json;
using CodexBridge.Ipc;

namespace BridgeIPC.Client.Tests;

public sealed class GoldenContractTests
{
    [Theory]
    [InlineData("request-status", BridgeWireMessageKind.Request)]
    [InlineData("response-success", BridgeWireMessageKind.Response)]
    [InlineData("event-conversation-push", BridgeWireMessageKind.Event)]
    public void SwiftFixturesRoundTripInCSharp(string name, BridgeWireMessageKind kind)
    {
        var fixture = File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Fixtures", $"{name}.json"));
        var decoded = BridgeWireCodec.Decode(fixture);
        Assert.Equal(kind, decoded.Kind);
        var encoded = BridgeWireCodec.Encode(decoded.Kind, decoded.Message);
        AssertJsonEqual(Parse(fixture), Parse(encoded));
    }

    [Fact]
    public void ResponsePayloadUsesSwiftDataBase64Contract()
    {
        var fixture = File.ReadAllBytes(Path.Combine(
            AppContext.BaseDirectory,
            "Fixtures",
            "response-success.json"));
        var response = BridgeWireCodec.Decode(fixture);
        var payload = BridgeServiceCodec.DecodePayload<MutationResponse>(response.Message);
        Assert.True(payload.Accepted);
    }

    [Fact]
    public void RequestPayloadUsesSwiftDataBase64Contract()
    {
        var request = BridgeServiceCodec.Request(
            "get_task_conversation",
            new { task_id = "task-1", limit = 200 },
            "request-1");
        var base64 = request.GetProperty("payload").GetString();
        var payload = JsonDocument.Parse(Convert.FromBase64String(base64!)).RootElement;
        Assert.Equal("task-1", payload.GetProperty("task_id").GetString());
        Assert.Equal(200, payload.GetProperty("limit").GetInt32());
    }

    private static JsonElement Parse(byte[] data) => JsonDocument.Parse(data).RootElement.Clone();

    private static void AssertJsonEqual(JsonElement expected, JsonElement actual)
    {
        Assert.Equal(expected.ValueKind, actual.ValueKind);
        switch (expected.ValueKind)
        {
            case JsonValueKind.Object:
                var expectedProperties = expected.EnumerateObject().ToDictionary(
                    property => property.Name,
                    property => property.Value);
                var actualProperties = actual.EnumerateObject().ToDictionary(
                    property => property.Name,
                    property => property.Value);
                Assert.Equal(
                    expectedProperties.Keys.OrderBy(name => name),
                    actualProperties.Keys.OrderBy(name => name));
                foreach (var property in expectedProperties)
                {
                    AssertJsonEqual(property.Value, actualProperties[property.Key]);
                }
                break;
            case JsonValueKind.Array:
                var expectedItems = expected.EnumerateArray().ToArray();
                var actualItems = actual.EnumerateArray().ToArray();
                Assert.Equal(expectedItems.Length, actualItems.Length);
                for (var index = 0; index < expectedItems.Length; index++)
                {
                    AssertJsonEqual(expectedItems[index], actualItems[index]);
                }
                break;
            case JsonValueKind.String:
                Assert.Equal(expected.GetString(), actual.GetString());
                break;
            case JsonValueKind.Number:
                Assert.Equal(expected.GetRawText(), actual.GetRawText());
                break;
            case JsonValueKind.True:
            case JsonValueKind.False:
                Assert.Equal(expected.GetBoolean(), actual.GetBoolean());
                break;
            case JsonValueKind.Null:
                break;
            default:
                throw new Xunit.Sdk.XunitException("Unsupported JSON value kind.");
        }
    }

    private sealed record MutationResponse(bool Accepted);
}
