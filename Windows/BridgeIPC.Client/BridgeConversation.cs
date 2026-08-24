namespace CodexBridge.Ipc;

using System.Globalization;

public sealed record BridgeConversationMessage(
    long? MessageId,
    string Key,
    string Role,
    string Kind,
    string Content,
    string? ToolName,
    string? ToolStatus,
    string? ToolArguments,
    bool Final);

public sealed record BridgeConversationPush(
    string TaskId,
    string Key,
    string Role,
    string Kind,
    string? Delta,
    int BaseContentLength,
    string? FullContent,
    bool Final,
    string? ToolName,
    string? ToolStatus,
    string? ToolArguments);

public sealed class BridgeConversationAccumulator
{
    private readonly object _gate = new();
    private readonly List<BridgeConversationMessage> _messages;
    private readonly Dictionary<string, int> _index;

    public BridgeConversationAccumulator(IEnumerable<BridgeConversationMessage> messages)
    {
        _messages = messages.ToList();
        _index = new Dictionary<string, int>(StringComparer.Ordinal);
        for (var position = 0; position < _messages.Count; position++)
        {
            _index[_messages[position].Key] = position;
        }
    }

    public IReadOnlyList<BridgeConversationMessage> Snapshot()
    {
        lock (_gate)
        {
            return _messages.ToArray();
        }
    }

    public bool Apply(BridgeConversationPush push)
    {
        lock (_gate)
        {
            if (_index.TryGetValue(push.Key, out var position))
            {
                var current = _messages[position];
                var content = ResolveContent(current.Content, push, allowMissing: true);
                if (content is null)
                {
                    return false;
                }
                _messages[position] = current with
                {
                    Content = content,
                    ToolName = push.ToolName ?? current.ToolName,
                    ToolStatus = push.ToolStatus ?? current.ToolStatus,
                    ToolArguments = push.ToolArguments ?? current.ToolArguments,
                    Final = current.Final || push.Final,
                };
                return true;
            }

            var initial = ResolveContent(string.Empty, push, allowMissing: false);
            if (initial is null)
            {
                return false;
            }
            _index[push.Key] = _messages.Count;
            _messages.Add(new BridgeConversationMessage(
                null,
                push.Key,
                push.Role,
                push.Kind,
                initial,
                push.ToolName,
                push.ToolStatus,
                push.ToolArguments,
                push.Final));
            return true;
        }
    }

    private static string? ResolveContent(
        string current,
        BridgeConversationPush push,
        bool allowMissing)
    {
        if (push.FullContent is not null)
        {
            return push.FullContent;
        }
        if (push.Delta is not null && TextElementCount(current) == push.BaseContentLength)
        {
            return current + push.Delta;
        }
        return allowMissing && push.Delta is null ? current : null;
    }

    private static int TextElementCount(string value)
    {
        return StringInfo.ParseCombiningCharacters(value).Length;
    }
}
