using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Input;

namespace ComposerBubbles;

public partial class ShelfWindow : Window
{
    private readonly BubbleStore store = new(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Composer Bubbles"));
    private Guid? activeChat;
    private SavedBubble? selection;
    private (Guid Chat, SavedBubble Bubble)? pendingUndo;
    private Button? pressedBubble;
    private Point pressPosition;
    private bool dragging;
    private bool leftDuringDrag;

    public ShelfWindow()
    {
        InitializeComponent();
        Loaded += (_, _) => ChatLink.Focus();
    }

    private void OpenShelf(object sender, RoutedEventArgs args) => OpenShelf();

    private void LinkKeyDown(object sender, KeyEventArgs args)
    {
        if (args.Key == Key.Enter)
        {
            args.Handled = true;
            OpenShelf();
        }
    }

    private void OpenShelf()
    {
        if (!CodexChatLink.TryParse(ChatLink.Text, out var chat))
        {
            SetStatus("Paste a local Codex chat link.");
            return;
        }

        RunShelfAction(() =>
        {
            var items = store.Visible(chat);
            activeChat = chat;
            ChatLabel.Text = $"Linked chat · {chat.ToString("N")[^8..]}";
            LinkArea.Visibility = Visibility.Collapsed;
            ShelfArea.Visibility = Visibility.Visible;
            RenderBubbles(items);
            UpdateSaveButton();
            SetStatus(items.Count == 0 ? "Paste a draft and click Save." : "Click a bubble to read it. Drag it to use it.");
            Draft.Focus();
        });
    }

    private void ClearChat()
    {
        activeChat = null;
        pressedBubble = null;
        ChatLink.Clear();
        ChatLabel.Text = "";
        BubbleRow.Children.Clear();
        SetSelection(null);
        ShelfArea.Visibility = Visibility.Collapsed;
        LinkArea.Visibility = Visibility.Visible;
        UpdateSaveButton();
        SetStatus("Paste the link to the Codex chat you want to use.");
    }

    private void ChangeChat(object sender, RoutedEventArgs args)
    {
        ClearChat();
        ChatLink.Focus();
    }

    private void WindowActivated(object? sender, EventArgs args) => Topmost = true;

    private void WindowDeactivated(object? sender, EventArgs args)
    {
        if (dragging)
        {
            leftDuringDrag = true;
            return;
        }
        Topmost = false;
        ClearChat();
    }

    private void WindowKeyDown(object sender, KeyEventArgs args)
    {
        if (args.Key != Key.Escape)
            return;
        if (selection is not null)
            SetSelection(null);
        else if (activeChat.HasValue)
            ChangeChat(sender, args);
        else
            return;
        args.Handled = true;
    }

    private void DraftChanged(object sender, TextChangedEventArgs args) => UpdateSaveButton();

    private void UpdateSaveButton()
    {
        if (SaveButton is not null)
            SaveButton.IsEnabled = activeChat.HasValue && !string.IsNullOrWhiteSpace(Draft.Text);
    }

    private void SaveDraft(object sender, RoutedEventArgs args)
    {
        if (activeChat is not { } chat)
            return;
        RunShelfAction(() =>
        {
            var bubble = store.Save(chat, Draft.Text);
            RenderBubbles(store.Visible(chat), bubble.Id);
            SetStatus("Saved a copy of the draft.");
        });
    }

    private void RenderBubbles(IReadOnlyList<SavedBubble> items, Guid? reveal = null)
    {
        var keep = selection is null ? null : items.FirstOrDefault(bubble => bubble == selection);
        SetSelection(keep);
        BubbleRow.Children.Clear();
        EmptyShelf.Visibility = items.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        UndoButton.Visibility = pendingUndo is { } undo && undo.Chat == activeChat
            ? Visibility.Visible : Visibility.Collapsed;

        foreach (var bubble in items)
        {
            var caption = new TextBlock { Text = Caption(bubble.Text), TextTrimming = TextTrimming.CharacterEllipsis };
            var button = new Button { Content = caption, Style = (Style)FindResource("BubbleButton") };
            AutomationProperties.SetName(button, caption.Text);
            button.Click += (_, _) => SetSelection(selection?.Id == bubble.Id ? null : bubble);
            button.PreviewMouseLeftButtonDown += (_, args) =>
            {
                pressedBubble = button;
                pressPosition = args.GetPosition(this);
            };
            button.PreviewMouseMove += (_, args) => BeginBubbleDrag(button, bubble, args);
            button.PreviewMouseLeftButtonUp += (_, _) => pressedBubble = null;
            BubbleRow.Children.Add(button);
            if (bubble.Id == reveal)
                button.BringIntoView();
        }
    }

    private static string Caption(string text)
    {
        var line = text.TrimStart().Split(['\r', '\n'], 2)[0].Replace('\t', ' ');
        var elements = new StringInfo(line);
        return elements.LengthInTextElements > 34 ? elements.SubstringByTextElements(0, 34) + "…" : line;
    }

    private void SetSelection(SavedBubble? bubble)
    {
        selection = bubble;
        PreviewText.Text = bubble?.Text ?? "";
        Preview.Visibility = bubble is null ? Visibility.Collapsed : Visibility.Visible;
    }

    private void ScrollBubbles(object sender, MouseWheelEventArgs args)
    {
        if (BubbleScroll.ScrollableWidth <= 0)
            return;
        BubbleScroll.ScrollToHorizontalOffset(BubbleScroll.HorizontalOffset - args.Delta);
        args.Handled = true;
    }

    private void BeginBubbleDrag(Button button, SavedBubble bubble, MouseEventArgs args)
    {
        if (!IsActive || !activeChat.HasValue || dragging || pressedBubble != button || args.LeftButton != MouseButtonState.Pressed)
            return;
        var movement = args.GetPosition(this) - pressPosition;
        if (Math.Abs(movement.X) < SystemParameters.MinimumHorizontalDragDistance &&
            Math.Abs(movement.Y) < SystemParameters.MinimumVerticalDragDistance)
            return;

        pressedBubble = null;
        dragging = true;
        leftDuringDrag = false;
        args.Handled = true;
        button.ReleaseMouseCapture();
        try
        {
            var data = new DataObject(DataFormats.UnicodeText, bubble.Text);
            DragDrop.DoDragDrop(button, data, DragDropEffects.Copy);
        }
        catch (ExternalException)
        {
            SetStatus("Drag couldn’t start. Open the bubble and use Copy.");
        }
        finally
        {
            dragging = false;
            if (leftDuringDrag || !IsActive)
            {
                Topmost = IsActive;
                ClearChat();
            }
        }
    }

    private void CopySelected(object sender, RoutedEventArgs args)
    {
        if (!activeChat.HasValue || selection is not { } bubble)
            return;
        try
        {
            Clipboard.SetText(bubble.Text, TextDataFormat.UnicodeText);
            SetStatus("Copied. Paste into the Codex composer when you’re ready.");
        }
        catch (ExternalException)
        {
            SetStatus("The clipboard is busy. Try Copy again.");
        }
    }

    private void RemoveSelected(object sender, RoutedEventArgs args)
    {
        if (activeChat is not { } chat || selection is not { } bubble)
            return;
        RunShelfAction(() =>
        {
            if (store.Remove(chat, bubble.Id) is { } removed)
                pendingUndo = (chat, removed);
            SetSelection(null);
            RenderBubbles(store.Visible(chat));
            SetStatus("Bubble removed.");
        });
    }

    private void UndoRemove(object sender, RoutedEventArgs args)
    {
        if (activeChat is not { } chat || pendingUndo is not { } undo || undo.Chat != chat)
            return;
        RunShelfAction(() =>
        {
            var bubble = store.Restore(chat, undo.Bubble);
            pendingUndo = null;
            RenderBubbles(store.Visible(chat), bubble.Id);
            SetStatus("Bubble restored.");
        });
    }

    private void RunShelfAction(Action work)
    {
        try { work(); }
        catch (Exception error) when (error is InvalidDataException or IOException or UnauthorizedAccessException or InvalidOperationException or ArgumentException)
        {
            SetStatus(error is InvalidDataException or InvalidOperationException
                ? error.Message : "Couldn’t use the local bubble file or draft. Try again.");
        }
    }

    private void SetStatus(string message)
    {
        Status.Text = message;
        UIElementAutomationPeer.FromElement(Status)?.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
    }
}
