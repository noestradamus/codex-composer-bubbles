namespace ComposerBubbles;

/// Links typed text to the chat it was entered for. Unlinked text can be
/// explicitly assigned when the user opens a link.
public sealed class ShelfDraft
{
    private readonly Dictionary<Guid, string> drafts = new();
    public Guid? Chat { get; private set; }
    public string Text { get; set; } = "";

    public void Link(Guid chat)
    {
        if (Chat == chat)
            return;
        Suspend();
        if (string.IsNullOrWhiteSpace(Text))
            Text = drafts.GetValueOrDefault(chat, "");
        Chat = chat;
    }

    public void Suspend()
    {
        if (Chat is not { } chat)
            return;
        if (Text.Length == 0)
            drafts.Remove(chat);
        else
            drafts[chat] = Text;
        Chat = null;
        Text = "";
    }
}
