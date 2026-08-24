using CodexBridge.App.Models;
using CodexBridge.Ipc;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using System.Text.Json;

namespace CodexBridge.App;

public sealed partial class MainWindow
{
    private const int MaximumPresentedMessageCharacters = 8_000;

    private async void TaskDetailsClick(object sender, RoutedEventArgs args)
    {
        if (sender is not Button { DataContext: TaskSummary task })
        {
            return;
        }

        var relay = new ConversationPushRelay(task.TaskId);
        TaskConversationSubscription? subscription = null;
        _connection.EventReceived += relay.Handle;
        try
        {
            subscription = await _connection.SendAsync<TaskConversationSubscription>(
                "subscribe_task_conversation",
                new { task.TaskId, BeforeMessageId = (long?)null, Limit = 200 },
                _lifetime.Token);
            await PresentTaskDetailsAsync(task, subscription, relay);
        }
        catch (Exception error)
        {
            PresentError(error.Message);
        }
        finally
        {
            relay.Stop();
            _connection.EventReceived -= relay.Handle;
            if (subscription is { SubscriptionId: >= 0 })
            {
                try
                {
                    await _connection.SendAsync<JsonElement>(
                        "unsubscribe_task_conversation",
                        new { task.TaskId, subscription.SubscriptionId },
                        _lifetime.Token);
                }
                catch (Exception error) when (
                    error is IOException or OperationCanceledException or BridgeProtocolException)
                {
                }
            }
        }
    }

    private async Task PresentTaskDetailsAsync(
        TaskSummary task,
        TaskConversationSubscription subscription,
        ConversationPushRelay relay)
    {
        var accumulator = new BridgeConversationAccumulator(
            subscription.Page.Messages.Select(ToBridgeMessage));
        var content = new StackPanel { Spacing = 14 };
        content.Children.Add(DetailText("任务", task.TaskId, true));
        content.Children.Add(DetailText("状态", task.Status));
        content.Children.Add(DetailText(
            "Supervisor",
            task.SupervisorSummary is null
                ? task.SupervisorStatus
                : $"{task.SupervisorStatus} · {task.SupervisorSummary}"));
        if (task.ResultSummary is not null)
        {
            content.Children.Add(DetailText("结果", task.ResultSummary));
        }
        if (task.FailureCode is not null)
        {
            content.Children.Add(DetailText("失败代码", task.FailureCode, true));
        }
        if (task.ChangedFiles.Count > 0)
        {
            content.Children.Add(DetailText(
                "变更文件",
                string.Join(Environment.NewLine, task.ChangedFiles),
                true));
        }
        var conversationHeading = new TextBlock
        {
            Style = Application.Current.Resources["BodyStrongTextBlockStyle"] as Style,
        };
        content.Children.Add(conversationHeading);
        var conversationContent = new StackPanel { Spacing = 8 };
        content.Children.Add(conversationContent);
        RenderConversation(conversationHeading, conversationContent, accumulator.Snapshot());

        var scroll = new ScrollViewer
        {
            Content = content,
            MaxWidth = 760,
            MaxHeight = 620,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        };
        var dialog = new ContentDialog
        {
            Title = "任务详情",
            Content = scroll,
            CloseButtonText = "关闭",
            XamlRoot = Content.XamlRoot,
        };
        relay.Start(push =>
        {
            if (!accumulator.Apply(push))
            {
                return;
            }
            DispatcherQueue.TryEnqueue(() => RenderConversation(
                conversationHeading,
                conversationContent,
                accumulator.Snapshot()));
        });
        await dialog.ShowAsync();
    }

    private static void RenderConversation(
        TextBlock heading,
        StackPanel content,
        IReadOnlyList<BridgeConversationMessage> messages)
    {
        heading.Text = $"Conversation · {messages.Count} 条消息";
        content.Children.Clear();
        foreach (var message in messages)
        {
            content.Children.Add(ConversationCard(message));
        }
        if (messages.Count == 0)
        {
            content.Children.Add(new TextBlock
            {
                Text = "当前任务尚无 conversation 消息。",
                Opacity = 0.72,
            });
        }
    }

    private static BridgeConversationMessage ToBridgeMessage(TaskConversationMessage message)
    {
        return new BridgeConversationMessage(
            message.MessageId,
            message.Key,
            message.Role,
            message.Kind,
            message.Content,
            message.ToolName,
            message.ToolStatus,
            message.ToolArguments,
            message.Final);
    }

    private static FrameworkElement ConversationCard(BridgeConversationMessage message)
    {
        var panel = new StackPanel { Spacing = 4 };
        var tool = message.ToolName is null
            ? string.Empty
            : $" · {message.ToolName} · {message.ToolStatus ?? "unknown"}";
        panel.Children.Add(new TextBlock
        {
            Text = $"{message.Role} · {message.Kind}{tool}",
            Opacity = 0.72,
        });
        if (message.Content.Length > 0)
        {
            panel.Children.Add(SelectableText(Bounded(message.Content), false));
        }
        if (!string.IsNullOrWhiteSpace(message.ToolArguments))
        {
            panel.Children.Add(SelectableText(Bounded(message.ToolArguments), true));
        }
        return new Border
        {
            BorderBrush = Application.Current.Resources["CardStrokeColorDefaultBrush"] as
                Microsoft.UI.Xaml.Media.Brush,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(4),
            Padding = new Thickness(12),
            Child = panel,
        };
    }

    private static FrameworkElement DetailText(string label, string value, bool monospace = false)
    {
        var panel = new StackPanel { Spacing = 3 };
        panel.Children.Add(new TextBlock { Text = label, Opacity = 0.72 });
        panel.Children.Add(SelectableText(Bounded(value), monospace));
        return panel;
    }

    private static TextBlock SelectableText(string text, bool monospace)
    {
        var block = new TextBlock
        {
            Text = text,
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
        };
        if (monospace)
        {
            block.FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Consolas");
        }
        return block;
    }

    private static string Bounded(string value)
    {
        return value.Length <= MaximumPresentedMessageCharacters
            ? value
            : value[..MaximumPresentedMessageCharacters] + "\n…（显示已截断）";
    }

    private sealed class ConversationPushRelay
    {
        private readonly object _gate = new();
        private readonly string _taskId;
        private readonly List<BridgeConversationPush> _pending = [];
        private Action<BridgeConversationPush>? _consumer;
        private bool _stopped;

        public ConversationPushRelay(string taskId)
        {
            _taskId = taskId;
        }

        public void Handle(object? sender, JsonElement message)
        {
            BridgeConversationPush push;
            try
            {
                push = BridgeServiceCodec.DecodeEvent<BridgeConversationPush>(message);
            }
            catch (BridgeProtocolException)
            {
                return;
            }
            if (push.TaskId != _taskId)
            {
                return;
            }

            Action<BridgeConversationPush>? consumer;
            lock (_gate)
            {
                if (_stopped)
                {
                    return;
                }
                consumer = _consumer;
                if (consumer is null)
                {
                    _pending.Add(push);
                    return;
                }
            }
            consumer(push);
        }

        public void Start(Action<BridgeConversationPush> consumer)
        {
            BridgeConversationPush[] pending;
            lock (_gate)
            {
                if (_stopped)
                {
                    return;
                }
                _consumer = consumer;
                pending = _pending.ToArray();
                _pending.Clear();
            }
            foreach (var push in pending)
            {
                consumer(push);
            }
        }

        public void Stop()
        {
            lock (_gate)
            {
                _stopped = true;
                _consumer = null;
                _pending.Clear();
            }
        }
    }
}
