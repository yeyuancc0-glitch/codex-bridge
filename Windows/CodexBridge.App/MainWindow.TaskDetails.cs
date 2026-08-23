using CodexBridge.App.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

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

        try
        {
            var conversation = await _connection.SendAsync<TaskConversationPage>(
                "get_task_conversation",
                new { task.TaskId, BeforeMessageId = (long?)null, Limit = 200 },
                _lifetime.Token);
            await PresentTaskDetailsAsync(task, conversation);
        }
        catch (Exception error)
        {
            PresentError(error.Message);
        }
    }

    private async Task PresentTaskDetailsAsync(
        TaskSummary task,
        TaskConversationPage conversation)
    {
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
        content.Children.Add(new TextBlock
        {
            Text = $"Conversation · {conversation.Messages.Count} 条快照消息",
            Style = Application.Current.Resources["BodyStrongTextBlockStyle"] as Style,
        });
        foreach (var message in conversation.Messages)
        {
            content.Children.Add(ConversationCard(message));
        }
        if (conversation.Messages.Count == 0)
        {
            content.Children.Add(new TextBlock
            {
                Text = "当前任务尚无 conversation 消息。",
                Opacity = 0.72,
            });
        }

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
        await dialog.ShowAsync();
    }

    private static FrameworkElement ConversationCard(TaskConversationMessage message)
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
}
