using CodexBridge.Ipc;

namespace BridgeIPC.Client.Tests;

public sealed class ConversationMergeTests
{
    [Fact]
    public void AppliesMatchingDeltaAndToolUpdates()
    {
        var accumulator = new BridgeConversationAccumulator(
        [
            new BridgeConversationMessage(
                1, "agent-1", "assistant", "tool_call", "abc",
                "exec", "running", null, false),
        ]);

        Assert.True(accumulator.Apply(new BridgeConversationPush(
            "task-1", "agent-1", "assistant", "tool_call", "def", 3, null, true,
            null, "completed", "{}")));

        var message = Assert.Single(accumulator.Snapshot());
        Assert.Equal("abcdef", message.Content);
        Assert.Equal("exec", message.ToolName);
        Assert.Equal("completed", message.ToolStatus);
        Assert.Equal("{}", message.ToolArguments);
        Assert.True(message.Final);
    }

    [Fact]
    public void RejectsMismatchedDeltaAndAcceptsFullReplacement()
    {
        var accumulator = new BridgeConversationAccumulator(
        [
            new BridgeConversationMessage(
                null, "agent-1", "assistant", "agent", "abc",
                null, null, null, false),
        ]);

        Assert.False(accumulator.Apply(new BridgeConversationPush(
            "task-1", "agent-1", "assistant", "agent", "bad", 2, null, false,
            null, null, null)));
        Assert.True(accumulator.Apply(new BridgeConversationPush(
            "task-1", "agent-1", "assistant", "agent", null, 0, "replacement", false,
            null, null, null)));
        Assert.Equal("replacement", Assert.Single(accumulator.Snapshot()).Content);
    }

    [Fact]
    public void NewEntryRequiresFullContentOrZeroBaseDelta()
    {
        var accumulator = new BridgeConversationAccumulator([]);

        Assert.False(accumulator.Apply(new BridgeConversationPush(
            "task-1", "agent-1", "assistant", "agent", "missing", 4, null, false,
            null, null, null)));
        Assert.True(accumulator.Apply(new BridgeConversationPush(
            "task-1", "agent-1", "assistant", "agent", "hello", 0, null, false,
            null, null, null)));
        Assert.Equal("hello", Assert.Single(accumulator.Snapshot()).Content);
    }

    [Fact]
    public void DeltaLengthUsesUnicodeTextElements()
    {
        var accumulator = new BridgeConversationAccumulator(
        [
            new BridgeConversationMessage(
                null, "agent-1", "assistant", "agent", "🙂",
                null, null, null, false),
        ]);

        Assert.True(accumulator.Apply(new BridgeConversationPush(
            "task-1", "agent-1", "assistant", "agent", "好", 1, null, false,
            null, null, null)));
        Assert.Equal("🙂好", Assert.Single(accumulator.Snapshot()).Content);
    }
}
