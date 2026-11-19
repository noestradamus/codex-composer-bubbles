namespace ComposerBubbles;

public static class CodexChatLink
{
    private const string LinkPrefix = "codex://threads/";
    private const string KeyPrefix = "thread:";

    public static bool TryParse(string? text, out Guid chat)
    {
        chat = default;
        var link = text?.Trim();
        if (link is null || !link.StartsWith(LinkPrefix, StringComparison.OrdinalIgnoreCase))
            return false;

        var target = link[LinkPrefix.Length..].Split('?', 2);
        if (target.Length == 2 && target[1].Split('&').Any(field =>
            field is not ("hostId=local" or "threadAccess=shared")))
            return false;

        return TryReadId(target[0], out chat);
    }

    internal static string Key(Guid chat) => KeyPrefix + chat.ToString("D");

    internal static bool TryReadKey(string? key, out Guid chat)
    {
        chat = default;
        return key is not null && key.StartsWith(KeyPrefix, StringComparison.Ordinal)
            && TryReadId(key.AsSpan(KeyPrefix.Length), out chat);
    }

    private static bool TryReadId(ReadOnlySpan<char> value, out Guid chat)
    {
        chat = default;
        return value.Length == 36 && Guid.TryParseExact(value, "D", out chat);
    }
}
