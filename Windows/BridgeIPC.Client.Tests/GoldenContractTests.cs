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

    [Fact]
    public void McpClientMutationUsesSwiftFieldAndModeValues()
    {
        var request = BridgeServiceCodec.Request(
            "set_mcp_client_exposure_mode",
            new { ClientId = "qwen.studio", ExposureMode = "read-only" },
            "request-mcp-client");
        var base64 = request.GetProperty("payload").GetString();
        var payload = JsonDocument.Parse(Convert.FromBase64String(base64!)).RootElement;
        Assert.Equal("qwen.studio", payload.GetProperty("client_id").GetString());
        Assert.Equal("read-only", payload.GetProperty("exposure_mode").GetString());
    }

    [Fact]
    public void ModelPreferencesUseSwiftFieldValues()
    {
        var request = BridgeServiceCodec.Request(
            "set_model_preferences",
            new
            {
                ExecutionModel = "gpt-5.6-sol",
                ExecutionEffort = "high",
                SupervisorModel = "gpt-5.6-luna",
                SupervisorEffort = "medium",
                SupervisorEnabled = true,
                AccessMode = "request-approval",
                FastModeEnabled = false,
            },
            "request-model-preferences");
        var base64 = request.GetProperty("payload").GetString();
        var payload = JsonDocument.Parse(Convert.FromBase64String(base64!)).RootElement;
        Assert.Equal("gpt-5.6-sol", payload.GetProperty("execution_model").GetString());
        Assert.Equal("gpt-5.6-luna", payload.GetProperty("supervisor_model").GetString());
        Assert.Equal("request-approval", payload.GetProperty("access_mode").GetString());
        Assert.False(payload.GetProperty("fast_mode_enabled").GetBoolean());
    }

    [Fact]
    public void TunnelConfigurationUsesSwiftSecretFieldNames()
    {
        var request = BridgeServiceCodec.Request(
            "configure_tunnel",
            new { TunnelId = "tunnel-fixture", RuntimeKey = "runtime-key-fixture" },
            "request-tunnel-configuration");
        var base64 = request.GetProperty("payload").GetString();
        var payload = JsonDocument.Parse(Convert.FromBase64String(base64!)).RootElement;
        Assert.Equal("tunnel-fixture", payload.GetProperty("tunnel_id").GetString());
        Assert.Equal("runtime-key-fixture", payload.GetProperty("runtime_key").GetString());
    }

    [Fact]
    public void ProjectPolicyUsesSwiftPermissionFieldNames()
    {
        var request = BridgeServiceCodec.Request(
            "update_project_policy",
            new
            {
                ProjectId = "project-fixture",
                ReadPermission = "allowed",
                WritePermission = "requiresLocalApproval",
                NetworkPermission = "denied",
            },
            "request-project-policy");
        var base64 = request.GetProperty("payload").GetString();
        var payload = JsonDocument.Parse(Convert.FromBase64String(base64!)).RootElement;
        Assert.Equal("project-fixture", payload.GetProperty("project_id").GetString());
        Assert.Equal("allowed", payload.GetProperty("read_permission").GetString());
        Assert.Equal(
            "requiresLocalApproval",
            payload.GetProperty("write_permission").GetString());
        Assert.Equal("denied", payload.GetProperty("network_permission").GetString());
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
