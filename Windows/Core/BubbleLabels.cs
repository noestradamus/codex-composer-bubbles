using System.Globalization;
using System.Text.RegularExpressions;

namespace ComposerBubbles;

public static partial class BubbleLabels
{
    private static readonly HashSet<string> PhraseEnds = new(StringComparer.OrdinalIgnoreCase)
    {
        "about", "after", "and", "at", "before", "by", "for", "from", "in", "into",
        "of", "on", "or", "that", "to", "when", "with", "without",
    };

    private static readonly HashSet<string> BroadWords = new(StringComparer.OrdinalIgnoreCase)
    {
        "a", "an", "can", "could", "do", "i", "it", "its", "me", "my", "our", "please",
        "some", "the", "their", "these", "this", "those", "we", "would", "you", "your",
        "add", "check", "explain", "find", "fix", "give", "help", "look", "make",
        "review", "run", "show", "write",
        "issue", "issues", "problem", "problems", "thing", "things",
        "briefly", "carefully", "quickly", "again", "next",
    };

    [GeneratedRegex(@"[\p{L}\p{N}][\p{L}\p{M}\p{N}]*(?:[-'’][\p{L}\p{M}\p{N}]+)*")]
    private static partial Regex Words();

    public static string ShortTitle(string text)
    {
        // The tooltip needs only the first nonempty line, even for a long saved draft.
        var line = text.TrimStart().AsSpan();
        var lineEnd = line.IndexOfAny('\r', '\n');
        if (lineEnd >= 0)
            line = line[..lineEnd];
        var clipped = line.Length > 256;
        if (clipped)
        {
            var end = char.IsHighSurrogate(line[255]) ? 255 : 256;
            line = line[..end];
        }
        var words = line.ToString().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        var excerpt = new StringInfo(string.Join(" ", words.Take(9)));
        if (excerpt.LengthInTextElements > 72)
            return excerpt.SubstringByTextElements(0, 72).TrimEnd() + "…";
        return excerpt.String + (words.Length > 9 || clipped ? "…" : "");
    }

    public static string PortraitWord(string title)
    {
        string? subject = null;
        string? first = null;
        foreach (Match match in Words().Matches(title))
        {
            var word = match.Value;
            first ??= word;
            if (PhraseEnds.Contains(word))
            {
                if (subject is not null)
                    break;
                continue;
            }
            if (!BroadWords.Contains(word))
                subject = word;
        }
        var result = subject ?? first ?? title.Split(' ', 2)[0];
        if (result.Length == 0)
            return "";
        var initial = StringInfo.GetNextTextElement(result);
        return initial.ToUpperInvariant() + result[initial.Length..];
    }

    public static string Stacked(string text, int limit)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(limit, 1);
        var elements = new StringInfo(text);
        var clipped = elements.LengthInTextElements > limit;
        var prefix = clipped ? elements.SubstringByTextElements(0, limit - 1) + "…" : text;
        var letters = StringInfo.GetTextElementEnumerator(prefix);
        var rows = new List<string>();
        while (letters.MoveNext())
            rows.Add(letters.GetTextElement());
        return string.Join('\n', rows);
    }
}
