using System.ComponentModel;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Security;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using BookmarkPath = System.Windows.Shapes.Path;

namespace ComposerBubbles;

public partial class ShelfWindow : Window
{
    internal static readonly string DataDirectory = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Composer Bubbles");
    private readonly BubbleStore store = new(DataDirectory);
    private readonly ShelfDraft draft = new();
    private readonly Dictionary<Guid, Button> buttons = new();
    private readonly string optionsPath = Path.Combine(DataDirectory, "settings.json");
    private ShelfOptions options;
    private SavedBubble? selection;
    private (Guid Chat, SavedBubble Bubble)? pendingUndo;
    private (Button Button, Point Origin, double Offset)? pressedBubble;
    private (Point Origin, double Offset)? gapPress;
    private HwndSource? windowSource;
    private SolidColorBrush? bookmarkFill;
    private bool browsing;
    private bool dragging;
    private bool leftDuringDrag;
    private bool vertical => options.Orientation == ShelfOrientation.Vertical;
    private double rowHeight => vertical ? (options.BubbleStyle == BubbleStyle.Numbers ? 78 : 108) : 40;
    private double scrollLength => vertical ? BubbleScroll.ScrollableHeight : BubbleScroll.ScrollableWidth;
    private double scrollOffset => vertical ? BubbleScroll.VerticalOffset : BubbleScroll.HorizontalOffset;
    private static readonly Geometry BookmarkShape = Geometry.Parse("M1,1 L11,1 11,15 6,11 1,15 Z");

    public ShelfWindow()
    {
        options = ShelfOptions.Load(optionsPath);
        InitializeComponent();
        RunShelfAction(() => LaunchWithCodex.IsChecked = CodexStartup.IsEnabled());
        ApplyLayout(0);
        RestorePosition();
        Loaded += (_, _) =>
        {
            if (IsActive)
                ChatLink.Focus();
        };
        SourceInitialized += (_, _) =>
        {
            windowSource = (HwndSource)PresentationSource.FromVisual(this);
            windowSource.AddHook(HandleWindowMessage);
        };
        Closed += (_, _) =>
        {
            windowSource?.RemoveHook(HandleWindowMessage);
        };
        BubbleScroll.ScrollChanged += (_, _) => CloseOffscreenPreview();
        BubbleScroll.MouseLeftButtonDown += BeginGapPan;
        BubbleScroll.MouseMove += MoveGapPan;
        BubbleScroll.MouseLeftButtonUp += EndGapPan;
        BubbleScroll.LostMouseCapture += (_, _) => gapPress = null;
        SaveButton.ContextMenu.Closed += (_, _) =>
        {
            if (!IsActive && !dragging)
                SuspendChat();
        };
    }

    private void OpenShelf(object sender, RoutedEventArgs args) => OpenShelf();

    private void LinkKeyDown(object sender, KeyEventArgs args)
    {
        if (args.Key != Key.Enter)
            return;
        args.Handled = true;
        OpenShelf();
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
            draft.Link(chat);
            Draft.Text = draft.Text;
            ChatLabel.Text = $"Linked chat · {chat.ToString("N")[^8..]}";
            LinkArea.Visibility = Visibility.Collapsed;
            ShelfArea.Visibility = Visibility.Visible;
            RenderBubbles(items);
            ScrollTo(0);
            UpdateSaveButton();
            SetStatus(items.Count == 0 ? "Paste a draft and click Save." : "Click a bubble to read it. Drag it to use it.");
            Draft.Focus();
        });
    }

    private void SuspendChat()
    {
        Topmost = IsActive;
        if (!draft.Chat.HasValue)
            return;
        draft.Suspend();
        Draft.Clear();
        pressedBubble = null;
        gapPress = null;
        if (BubbleScroll.IsMouseCaptured)
            BubbleScroll.ReleaseMouseCapture();
        browsing = false;
        SetSelection(null);
        buttons.Clear();
        BubbleRow.Children.Clear();
        ChatLink.Clear();
        ShelfArea.Visibility = Visibility.Collapsed;
        LinkArea.Visibility = Visibility.Visible;
        UpdateSaveButton();
        SetStatus("Paste the link to the Codex chat you want to use.");
    }

    private void ChangeChat(object sender, RoutedEventArgs args)
    {
        SuspendChat();
        ChatLink.Focus();
    }

    private void WindowActivated(object? sender, EventArgs args) => Topmost = true;

    private void WindowDeactivated(object? sender, EventArgs args)
    {
        if (dragging)
            leftDuringDrag = true;
        else if (SaveButton.ContextMenu?.IsOpen != true)
            SuspendChat();
    }

    private void WindowKeyDown(object sender, KeyEventArgs args)
    {
        if (args.Key != Key.Escape)
            return;
        if (selection is not null)
            SetSelection(null);
        else if (draft.Chat.HasValue)
            ChangeChat(sender, args);
        else
            return;
        args.Handled = true;
    }

    private void DraftChanged(object sender, TextChangedEventArgs args)
    {
        draft.Text = ((TextBox)sender).Text;
        UpdateSaveButton();
    }

    private void UpdateSaveButton()
    {
        if (SaveButton is not null)
            SaveButton.IsEnabled = draft.Chat.HasValue && !string.IsNullOrWhiteSpace(draft.Text);
    }

    private void SaveDraft(object sender, RoutedEventArgs args)
    {
        if (!IsActive || draft.Chat is not { } chat)
            return;
        RunShelfAction(() =>
        {
            var bubble = store.Save(chat, draft.Text);
            RenderBubbles(store.Visible(chat), bubble.Id);
            ConfirmSave();
            SetStatus("Saved a copy of the draft.");
        });
    }

    private void ApplyLayout(int count)
    {
        var hasBubbles = count > 0;
        RailColumn.Width = vertical ? GridLength.Auto : new GridLength(1, GridUnitType.Star);
        PreviewColumn.Width = vertical ? new GridLength(1, GridUnitType.Star) : new GridLength(0);
        BubbleColumn.Width = vertical || !hasBubbles ? GridLength.Auto : new GridLength(1, GridUnitType.Star);
        Grid.SetRow(BubbleScroll, vertical ? 1 : 0);
        Grid.SetColumn(SaveButton, vertical || !hasBubbles ? 0 : 1);
        Grid.SetRow(Preview, vertical ? 0 : 1);
        Grid.SetColumn(Preview, vertical ? 1 : 0);
        Preview.Margin = vertical ? new Thickness(12, 4, 0, 4) : new Thickness(0, 9, 0, 0);
        BubbleRow.Orientation = vertical ? Orientation.Vertical : Orientation.Horizontal;
        BubbleScroll.HorizontalScrollBarVisibility = vertical ? ScrollBarVisibility.Disabled : ScrollBarVisibility.Hidden;
        BubbleScroll.VerticalScrollBarVisibility = vertical ? ScrollBarVisibility.Hidden : ScrollBarVisibility.Disabled;
        BubbleScroll.PanningMode = vertical ? PanningMode.VerticalOnly : PanningMode.HorizontalOnly;
        BubbleScroll.MaxHeight = vertical ? Math.Min((rowHeight + 7) * 5, Math.Max(rowHeight + 7, SystemParameters.WorkArea.Height - 280)) : 40;
        BubbleScroll.Margin = vertical && hasBubbles ? new Thickness(0, 5, 0, 0) : new Thickness(0);
        BubbleScroll.Visibility = hasBubbles ? Visibility.Visible : Visibility.Collapsed;

        SaveButton.Height = rowHeight;
        SaveButton.Width = vertical ? 40 : double.NaN;
        SaveButton.Margin = vertical ? new Thickness(0, 3.5, 0, 3.5) : new Thickness(hasBubbles ? 8 : 0, 0, 0, 0);
        var saveContent = new StackPanel { Orientation = vertical ? Orientation.Vertical : Orientation.Horizontal };
        bookmarkFill = null;
        if (options.SaveStyle != SaveStyle.TextOnly)
        {
            bookmarkFill = new SolidColorBrush(Colors.Transparent);
            var mark = new BookmarkPath
            {
                Data = BookmarkShape, Width = 12, Height = 16, StrokeThickness = 1.35, Stretch = Stretch.Uniform,
                Fill = bookmarkFill, HorizontalAlignment = HorizontalAlignment.Center,
            };
            mark.SetResourceReference(BookmarkPath.StrokeProperty, SystemColors.WindowTextBrushKey);
            saveContent.Children.Add(mark);
        }
        if (options.SaveStyle != SaveStyle.BookmarkOnly)
        {
            var label = BubbleText(vertical ? BubbleLabels.Stacked("Save", 4) : "Save");
            if (options.SaveStyle == SaveStyle.BookmarkAndText)
                label.Margin = vertical ? new Thickness(0, 3, 0, 0) : new Thickness(4, 0, 0, 0);
            saveContent.Children.Add(label);
        }
        SaveButton.Content = saveContent;
    }

    private void RenderBubbles(IReadOnlyList<SavedBubble> items, Guid? reveal = null)
    {
        var keep = selection is null ? null : items.FirstOrDefault(bubble => bubble == selection);
        SetSelection(keep);
        pressedBubble = null;
        browsing = false;
        BubbleRow.Children.Clear();
        buttons.Clear();
        ApplyLayout(items.Count);
        UndoButton.Visibility = pendingUndo is { } undo && undo.Chat == draft.Chat
            ? Visibility.Visible : Visibility.Collapsed;

        foreach (var bubble in items)
        {
            var title = BubbleLabels.ShortTitle(bubble.Text);
            var display = options.BubbleStyle == BubbleStyle.Numbers
                ? bubble.Number?.ToString(CultureInfo.CurrentCulture) ?? ""
                : vertical ? BubbleLabels.Stacked(BubbleLabels.PortraitWord(title), 7) : title;
            var button = new Button
            {
                Content = BubbleText(display),
                Style = (Style)FindResource("BubbleButton"),
                Width = vertical ? 40 : double.NaN, Height = rowHeight,
                Margin = vertical ? new Thickness(0, 3.5, 0, 3.5) : new Thickness(0, 0, 6, 0),
                Tag = bubble.Id == selection?.Id ? "preview" : null,
                ToolTip = bubble.Id == selection?.Id ? null : title,
            };
            AutomationProperties.SetName(button, options.BubbleStyle == BubbleStyle.Numbers && bubble.Number.HasValue
                ? $"Bubble {bubble.Number}. {title}" : title);
            button.Click += (_, _) => RunShelfAction(() =>
            {
                if (selection?.Id == bubble.Id)
                    SetSelection(null);
                else if (CanUse(bubble))
                    SetSelection(bubble);
            });
            button.PreviewMouseLeftButtonDown += (_, args) =>
            {
                pressedBubble = (button, args.GetPosition(this), scrollOffset);
                browsing = false;
            };
            button.PreviewMouseMove += (_, args) => MoveBubble(button, bubble, args);
            button.PreviewMouseLeftButtonUp += (_, args) =>
            {
                if (browsing)
                {
                    button.ReleaseMouseCapture();
                    args.Handled = true;
                }
                pressedBubble = null;
                browsing = false;
            };
            button.LostMouseCapture += (_, _) =>
            {
                if (pressedBubble?.Button != button)
                    return;
                pressedBubble = null;
                browsing = false;
            };
            buttons.Add(bubble.Id, button);
            BubbleRow.Children.Add(button);
        }

        if ((reveal ?? keep?.Id) is { } id && buttons.TryGetValue(id, out var revealed))
            Dispatcher.InvokeAsync(() =>
            {
                if (revealed.IsDescendantOf(BubbleRow))
                    revealed.BringIntoView();
            }, DispatcherPriority.Loaded);
    }

    private static TextBlock BubbleText(string text) => new()
    {
        Text = text, TextAlignment = TextAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis,
        FontSize = 12, FontWeight = FontWeights.Medium, LineHeight = 12,
        LineStackingStrategy = LineStackingStrategy.BlockLineHeight,
    };

    private void SetSelection(SavedBubble? bubble)
    {
        if (selection == bubble)
            return;
        if (selection is { } old && buttons.TryGetValue(old.Id, out var previous))
        {
            previous.Tag = null;
            previous.ToolTip = BubbleLabels.ShortTitle(old.Text);
        }
        selection = bubble;
        PreviewText.Text = bubble?.Text ?? "";
        Preview.Visibility = bubble is null ? Visibility.Collapsed : Visibility.Visible;
        if (bubble is not null && buttons.TryGetValue(bubble.Id, out var selected))
        {
            selected.Tag = "preview";
            selected.ToolTip = null;
        }
    }

    private void CloseOffscreenPreview()
    {
        if (selection is not { } bubble || !buttons.TryGetValue(bubble.Id, out var button) ||
            !BubbleScroll.IsVisible || !button.IsArrangeValid || !BubbleScroll.IsArrangeValid)
            return;
        var viewport = new Rect(0, 0, BubbleScroll.ViewportWidth, BubbleScroll.ViewportHeight);
        if (viewport.Width <= 0 || viewport.Height <= 0)
            return;
        var face = button.TransformToAncestor(BubbleScroll).TransformBounds(new Rect(button.RenderSize));
        face.Intersect(viewport);
        if (face.IsEmpty || face.Width <= 0 || face.Height <= 0)
            SetSelection(null);
    }

    private void ScrollTo(double offset)
    {
        if (vertical)
            BubbleScroll.ScrollToVerticalOffset(Math.Clamp(offset, 0, scrollLength));
        else
            BubbleScroll.ScrollToHorizontalOffset(Math.Clamp(offset, 0, scrollLength));
    }

    private void ScrollBubbles(object sender, MouseWheelEventArgs args)
    {
        if (scrollLength <= 0)
            return;
        ScrollTo(scrollOffset - args.Delta);
        args.Handled = true;
    }

    private IntPtr HandleWindowMessage(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        const int MouseHorizontalWheel = 0x020E;
        const int PointerHorizontalWheel = 0x024F;
        if (message is not (MouseHorizontalWheel or PointerHorizontalWheel) || vertical || scrollLength <= 0 ||
            !BubbleScroll.IsMouseOver)
            return IntPtr.Zero;
        var delta = unchecked((short)(wParam.ToInt64() >> 16));
        ScrollTo(scrollOffset + delta);
        handled = true;
        return IntPtr.Zero;
    }

    private void BeginGapPan(object sender, MouseButtonEventArgs args)
    {
        if (scrollLength <= 0 || !BubbleScroll.CaptureMouse())
            return;
        gapPress = (args.GetPosition(this), scrollOffset);
        args.Handled = true;
    }

    private void MoveGapPan(object sender, MouseEventArgs args)
    {
        if (gapPress is not { } press || args.LeftButton != MouseButtonState.Pressed)
            return;
        var movement = args.GetPosition(this) - press.Origin;
        ScrollTo(press.Offset - (vertical ? movement.Y : movement.X));
        args.Handled = true;
    }

    private void EndGapPan(object sender, MouseButtonEventArgs args)
    {
        if (gapPress is null)
            return;
        gapPress = null;
        BubbleScroll.ReleaseMouseCapture();
        args.Handled = true;
    }

    private void MoveBubble(Button button, SavedBubble bubble, MouseEventArgs args)
    {
        if (!IsActive || !draft.Chat.HasValue || dragging || pressedBubble is not { } press || press.Button != button ||
            args.LeftButton != MouseButtonState.Pressed)
            return;
        var movement = args.GetPosition(this) - press.Origin;
        if (!browsing && Math.Abs(movement.X) < SystemParameters.MinimumHorizontalDragDistance &&
            Math.Abs(movement.Y) < SystemParameters.MinimumVerticalDragDistance)
            return;
        var along = vertical ? movement.Y : movement.X;
        var across = vertical ? movement.X : movement.Y;
        var point = args.GetPosition(BubbleScroll);
        var crossedEdge = vertical ? point.X < -8 || point.X > BubbleScroll.ActualWidth + 8
            : point.Y < -8 || point.Y > BubbleScroll.ActualHeight + 8;
        if (scrollLength > 0 && !crossedEdge && !Keyboard.Modifiers.HasFlag(ModifierKeys.Alt))
        {
            if (browsing || Math.Abs(along) >= 1.25 * Math.Abs(across))
            {
                browsing = true;
                ScrollTo(press.Offset - along);
                args.Handled = true;
                return;
            }
            if (Math.Abs(across) < 1.25 * Math.Abs(along) && movement.Length < 9)
                return;
        }
        args.Handled = true;
        pressedBubble = null;
        browsing = false;
        button.ReleaseMouseCapture();
        RunShelfAction(() => ExportBubble(button, bubble));
    }

    private void ExportBubble(Button button, SavedBubble bubble)
    {
        if (!CanUse(bubble))
            return;
        dragging = true;
        leftDuringDrag = false;
        try
        {
            DragDrop.DoDragDrop(button, new DataObject(DataFormats.UnicodeText, bubble.Text), DragDropEffects.Copy);
        }
        catch (ExternalException)
        {
            SetStatus("Drag couldn’t start. Open the bubble and use Copy.");
        }
        finally
        {
            dragging = false;
            if (leftDuringDrag || !IsActive)
                SuspendChat();
        }
    }

    private bool CanUse(SavedBubble bubble)
    {
        if (!IsActive || draft.Chat is not { } chat)
            return false;
        if (store.IsCurrent(chat, bubble))
            return true;
        RenderBubbles(store.Visible(chat));
        SetStatus("This bubble changed. Choose it again.");
        return false;
    }

    private void CopySelected(object sender, RoutedEventArgs args)
    {
        if (selection is not { } bubble)
            return;
        RunShelfAction(() =>
        {
            if (!CanUse(bubble))
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
        });
    }

    private void RemoveSelected(object sender, RoutedEventArgs args)
    {
        if (!IsActive || draft.Chat is not { } chat || selection is not { } bubble)
            return;
        RunShelfAction(() =>
        {
            var removed = store.RemoveMatching(chat, bubble);
            if (removed is not null)
                pendingUndo = (chat, removed);
            SetSelection(null);
            RenderBubbles(store.Visible(chat));
            SetStatus(removed is null ? "This bubble changed. Choose it again." : "Bubble removed.");
        });
    }

    private void UndoRemove(object sender, RoutedEventArgs args)
    {
        if (!IsActive || draft.Chat is not { } chat || pendingUndo is not { } undo || undo.Chat != chat)
            return;
        RunShelfAction(() =>
        {
            var bubble = store.Restore(chat, undo.Bubble);
            pendingUndo = null;
            RenderBubbles(store.Visible(chat), bubble.Id);
            SetStatus("Bubble restored.");
        });
    }

    private void ConfirmSave()
    {
        if (bookmarkFill is null || SystemParameters.HighContrast)
            return;
        var ribbon = Color.FromRgb(35, 83, 250);
        var animation = new ColorAnimationUsingKeyFrames();
        animation.KeyFrames.Add(new DiscreteColorKeyFrame(ribbon, KeyTime.FromTimeSpan(TimeSpan.Zero)));
        animation.KeyFrames.Add(new DiscreteColorKeyFrame(ribbon, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(0.65))));
        var end = KeyTime.FromTimeSpan(TimeSpan.FromSeconds(SystemParameters.ClientAreaAnimation ? 1 : 0.66));
        animation.KeyFrames.Add(SystemParameters.ClientAreaAnimation
            ? new LinearColorKeyFrame(Colors.Transparent, end)
            : new DiscreteColorKeyFrame(Colors.Transparent, end));
        bookmarkFill.BeginAnimation(SolidColorBrush.ColorProperty, animation);
    }

    private void SaveMenuOpening(object sender, ContextMenuEventArgs args)
    {
        SwitchLayout.Header = vertical ? "Switch to Horizontal" : "Switch to Vertical";
        ShowCaptions.IsChecked = options.BubbleStyle == BubbleStyle.ShortCaptions;
        ShowNumbers.IsChecked = options.BubbleStyle == BubbleStyle.Numbers;
        ShowBookmarkAndText.IsChecked = options.SaveStyle == SaveStyle.BookmarkAndText;
        ShowBookmark.IsChecked = options.SaveStyle == SaveStyle.BookmarkOnly;
        ShowText.IsChecked = options.SaveStyle == SaveStyle.TextOnly;
    }

    private void ToggleAutoLaunch(object sender, RoutedEventArgs args)
    {
        var enabled = LaunchWithCodex.IsChecked == true;
        try
        {
            CodexStartup.SetEnabled(enabled);
            SetStatus(enabled ? "The shelf will open with Codex." : "Automatic launch is off.");
        }
        catch (Exception error) when (error is Win32Exception or IOException or UnauthorizedAccessException or
            InvalidOperationException or SecurityException)
        {
            LaunchWithCodex.IsChecked = !enabled;
            SetStatus("Couldn’t change automatic launch. Check Windows Startup apps.");
        }
    }

    private void ToggleOrientation(object sender, RoutedEventArgs args) =>
        ChangeOptions(options with { Orientation = vertical ? ShelfOrientation.Horizontal : ShelfOrientation.Vertical });
    private void ChooseCaptions(object sender, RoutedEventArgs args) =>
        ChangeOptions(options with { BubbleStyle = BubbleStyle.ShortCaptions });
    private void ChooseNumbers(object sender, RoutedEventArgs args) =>
        ChangeOptions(options with { BubbleStyle = BubbleStyle.Numbers });
    private void ChooseBookmarkAndText(object sender, RoutedEventArgs args) =>
        ChangeOptions(options with { SaveStyle = SaveStyle.BookmarkAndText });
    private void ChooseBookmark(object sender, RoutedEventArgs args) =>
        ChangeOptions(options with { SaveStyle = SaveStyle.BookmarkOnly });
    private void ChooseText(object sender, RoutedEventArgs args) =>
        ChangeOptions(options with { SaveStyle = SaveStyle.TextOnly });

    private void ChangeOptions(ShelfOptions next)
    {
        if (options == next || draft.Chat is not { } chat)
            return;
        RunShelfAction(() =>
        {
            var items = store.Visible(chat);
            next.Save(optionsPath);
            var orientationChanged = options.Orientation != next.Orientation;
            options = next;
            if (orientationChanged)
            {
                BubbleScroll.ScrollToHorizontalOffset(0);
                BubbleScroll.ScrollToVerticalOffset(0);
            }
            RenderBubbles(items);
        });
    }

    private void RestorePosition()
    {
        if (options.Left is not { } x || options.Top is not { } y ||
            !double.IsFinite(x) || !double.IsFinite(y))
            return;
        var desktop = new Rect(SystemParameters.VirtualScreenLeft, SystemParameters.VirtualScreenTop,
                               SystemParameters.VirtualScreenWidth, SystemParameters.VirtualScreenHeight);
        if (desktop.Contains(new Point(x + 60, y + 20)))
        {
            WindowStartupLocation = WindowStartupLocation.Manual;
            Left = x;
            Top = y;
        }
    }

    protected override void OnClosing(CancelEventArgs args)
    {
        base.OnClosing(args);
        if (args.Cancel)
            return;
        RunShelfAction(() =>
        {
            var bounds = RestoreBounds;
            if (!bounds.IsEmpty && double.IsFinite(bounds.Left) && double.IsFinite(bounds.Top))
                (options with { Left = bounds.Left, Top = bounds.Top }).Save(optionsPath);
        });
    }

    private void RunShelfAction(Action work)
    {
        try { work(); }
        catch (Exception error) when (error is InvalidDataException or IOException or UnauthorizedAccessException or
            InvalidOperationException or ArgumentException or SecurityException)
        {
            SetStatus(error is InvalidDataException or InvalidOperationException
                ? error.Message : "Couldn’t use the local bubble file, settings, or draft. Try again.");
        }
    }

    private void SetStatus(string message)
    {
        Status.Text = message;
        UIElementAutomationPeer.FromElement(Status)?.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
    }
}
