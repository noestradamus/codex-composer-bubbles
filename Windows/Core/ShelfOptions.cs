using System.Text.Json;

namespace ComposerBubbles;

public enum ShelfOrientation { Horizontal, Vertical }
public enum BubbleStyle { ShortCaptions, Numbers }
public enum SaveStyle { BookmarkAndText, BookmarkOnly, TextOnly }

public sealed record ShelfOptions(
    ShelfOrientation Orientation = ShelfOrientation.Horizontal,
    BubbleStyle BubbleStyle = BubbleStyle.ShortCaptions,
    SaveStyle SaveStyle = SaveStyle.BookmarkAndText,
    double? Left = null,
    double? Top = null)
{
    public static ShelfOptions Load(string path)
    {
        try
        {
            var settings = JsonSerializer.Deserialize<ShelfOptions>(File.ReadAllText(path));
            return settings is not null && Enum.IsDefined(settings.Orientation) &&
                Enum.IsDefined(settings.BubbleStyle) && Enum.IsDefined(settings.SaveStyle)
                ? settings : new();
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException)
        {
            return new();
        }
    }

    public void Save(string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        var temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.WriteAllText(temp, JsonSerializer.Serialize(this));
            File.Move(temp, path, overwrite: true);
        }
        finally
        {
            File.Delete(temp);
        }
    }
}
