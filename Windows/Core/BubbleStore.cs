using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace ComposerBubbles;

public sealed record SavedBubble(Guid Id, string Text, string? ChatKey = null, long? Number = null);

/// Reads and writes the Mac app's version 1 shelf format.
public sealed class BubbleStore(string directory)
{
    private static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        RespectRequiredConstructorParameters = true,
    };
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);
    private string ShelfPath => Path.Combine(directory, "bubbles.json");

    private sealed class Shelf
    {
        public required int Version { get; init; }
        public required List<SavedBubble> Bubbles { get; init; }
        public Dictionary<string, long>? LastNumberByChat { get; set; }
    }

    public IReadOnlyList<SavedBubble> Visible(Guid chat) => Load().Bubbles
        .Where(bubble => BelongsTo(bubble, chat))
        .OrderBy(bubble => bubble.Number)
        .ToArray();

    public SavedBubble Save(Guid chat, string text)
    {
        if (string.IsNullOrWhiteSpace(text))
            throw new ArgumentException("Enter a draft to save.", nameof(text));
        StrictUtf8.GetByteCount(text);
        return Add(chat, new SavedBubble(Guid.NewGuid(), text, CodexChatLink.Key(chat), null));
    }

    public bool IsCurrent(Guid chat, SavedBubble bubble) => BelongsTo(bubble, chat) && Load().Bubbles.Contains(bubble);

    public SavedBubble? Remove(Guid chat, Guid id) => Remove(chat, id, null);

    public SavedBubble? RemoveMatching(Guid chat, SavedBubble expected) => Remove(chat, expected.Id, expected);

    private SavedBubble? Remove(Guid chat, Guid id, SavedBubble? expected) => Update<SavedBubble?>(shelf =>
    {
        var index = shelf.Bubbles.FindIndex(bubble => bubble.Id == id && BelongsTo(bubble, chat) &&
            (expected is null || bubble == expected));
        if (index < 0)
            return (null, false);
        var bubble = shelf.Bubbles[index];
        shelf.Bubbles.RemoveAt(index);
        return (bubble, true);
    });

    public SavedBubble Restore(Guid chat, SavedBubble bubble)
    {
        if (!BelongsTo(bubble, chat))
            throw new InvalidOperationException("This bubble belongs to a different chat.");
        return Add(chat, bubble);
    }

    private SavedBubble Add(Guid chat, SavedBubble bubble) => Update(shelf =>
    {
        if (shelf.Bubbles.Find(existing => existing.Id == bubble.Id) is { } sameId)
        {
            if (!BelongsTo(sameId, chat))
                throw new InvalidOperationException("This bubble belongs to a different chat.");
            return (sameId, false);
        }
        if (shelf.Bubbles.Find(existing =>
            BelongsTo(existing, chat) && string.Equals(existing.Text, bubble.Text, StringComparison.Ordinal)) is { } sameText)
            return (sameText, false);

        var key = CodexChatLink.Key(chat);
        var lastNumbers = shelf.LastNumberByChat!;
        var last = lastNumbers.GetValueOrDefault(key);
        var number = bubble.Number is > 0 && !shelf.Bubbles.Any(existing =>
            existing.Number == bubble.Number && BelongsTo(existing, chat))
            ? bubble.Number.Value
            : NextNumber(last);
        lastNumbers[key] = Math.Max(last, number);
        var added = bubble with { ChatKey = key, Number = number };
        shelf.Bubbles.Insert(0, added);
        return (added, true);
    });

    private static bool BelongsTo(SavedBubble bubble, Guid chat) =>
        CodexChatLink.TryReadKey(bubble.ChatKey, out var owner) && owner == chat;

    private static long NextNumber(long last) => last < long.MaxValue
        ? Math.Max(last, 0) + 1
        : throw new InvalidOperationException("This chat has reached its bubble number limit.");

    private Shelf Load()
    {
        Shelf shelf;
        try
        {
            using var source = new FileStream(ShelfPath, FileMode.Open, FileAccess.Read, FileShare.Read | FileShare.Delete);
            shelf = JsonSerializer.Deserialize<Shelf>(source, Json)
                ?? throw new InvalidDataException("The bubble file is empty.");
        }
        catch (FileNotFoundException) { return EmptyShelf(); }
        catch (DirectoryNotFoundException) { return EmptyShelf(); }
        catch (JsonException error) { throw new InvalidDataException("The bubble file could not be read.", error); }

        if (shelf.Version != 1 || shelf.Bubbles is null || shelf.Bubbles.Any(bubble => bubble?.Text is null) ||
            shelf.Bubbles.Select(bubble => bubble.Id).Distinct().Count() != shelf.Bubbles.Count)
            throw new InvalidDataException("The bubble file has an unsupported format.");

        FillMissingNumbers(shelf);
        return shelf;
    }

    private static Shelf EmptyShelf() => new() { Version = 1, Bubbles = [], LastNumberByChat = new() };

    private static void FillMissingNumbers(Shelf shelf)
    {
        var lastNumbers = shelf.LastNumberByChat ??= new();
        var used = new Dictionary<Guid, HashSet<long>>();
        var missing = new List<(int Index, string Key)>();
        // Version 1 files store the newest bubble first. Reserve assigned numbers,
        // then assign numbers to older bubbles in historical order.
        for (var index = shelf.Bubbles.Count - 1; index >= 0; index--)
        {
            var bubble = shelf.Bubbles[index];
            if (!CodexChatLink.TryReadKey(bubble.ChatKey, out var chat))
                continue;
            var key = CodexChatLink.Key(chat);
            if (!used.TryGetValue(chat, out var numbers))
                used[chat] = numbers = [];

            if (bubble.Number is > 0 and var number && numbers.Add(number))
                lastNumbers[key] = Math.Max(number, lastNumbers.GetValueOrDefault(key));
            else
                missing.Add((index, key));
        }
        foreach (var (index, key) in missing)
        {
            var number = NextNumber(lastNumbers.GetValueOrDefault(key));
            lastNumbers[key] = number;
            shelf.Bubbles[index] = shelf.Bubbles[index] with { ChatKey = key, Number = number };
        }
    }

    private T Update<T>(Func<Shelf, (T Result, bool Changed)> edit)
    {
        Directory.CreateDirectory(directory);
        using var exclusive = new FileStream(Path.Combine(directory, "shelf.lock"), FileMode.OpenOrCreate,
            FileAccess.ReadWrite, FileShare.None);
        var shelf = Load();
        var (result, changed) = edit(shelf);
        if (!changed)
            return result;

        var temporary = Path.Combine(directory, $"{Guid.NewGuid():N}.tmp");
        try
        {
            using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                JsonSerializer.Serialize(output, shelf, Json);
                output.Flush(flushToDisk: true);
            }
            File.Move(temporary, ShelfPath, overwrite: true);
        }
        finally
        {
            File.Delete(temporary);
        }
        return result;
    }
}
