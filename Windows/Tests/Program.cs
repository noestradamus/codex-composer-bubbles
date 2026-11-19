using System.Text.Json;
using ComposerBubbles;

var chatA = Guid.Parse("11111111-1111-4111-8111-111111111111");
var chatB = Guid.Parse("22222222-2222-4222-8222-222222222222");
var firstLink = $"codex://threads/{chatA:D}";
Check(CodexChatLink.TryParse(firstLink, out var parsed) && parsed == chatA, "local link");
Check(CodexChatLink.TryParse($" {firstLink}?threadAccess=shared&hostId=local\r\n", out parsed)
    && parsed == chatA, "copied link flags");
foreach (var bad in new[]
{
    $"https://threads/{chatA:D}", $"codex://elsewhere/{chatA:D}", $"{firstLink}/extra",
    $"{firstLink}#private", $"{firstLink}?hostId=remote", $"{firstLink}?hostId=local&hostId=remote",
    "codex://threads/new", $"codex://threads/{chatA:N}", $"codex://user@threads/{chatA:D}",
    $"codex://threads/other/../{chatA:D}",
})
    Check(!CodexChatLink.TryParse(bad, out _), $"reject {bad}");

var temp = Directory.CreateTempSubdirectory("composer-bubbles-windows-");
try
{
    var store = new BubbleStore(temp.FullName);
    var otherInstance = new BubbleStore(temp.FullName);
    var composed = "  keep café\r\n\t次の手順 👩‍💻  ";
    var decomposed = composed.Replace("é", "e\u0301");
    var a1 = store.Save(chatA, composed);
    Check(store.Save(chatA, composed) == a1, "duplicate coalesces");
    var a2 = otherInstance.Save(chatA, decomposed);
    var b1 = store.Save(chatB, composed);
    Check(a1.Number == 1 && a2.Number == 2 && b1.Number == 1 && a1.Id != a2.Id, "stable per-chat numbers");
    Check(otherInstance.Visible(chatA).SequenceEqual([a1, a2]), "exact Unicode, spaces and line breaks on reload");
    Check(otherInstance.Visible(chatB).SequenceEqual([b1]), "other chat gets its own bubble");
    Check(store.Remove(chatB, a1.Id) is null, "wrong chat cannot remove");
    var removed = store.Remove(chatB, b1.Id);
    Check(removed == b1 && store.Visible(chatB).Count == 0, "remove last bubble");
    Expect<InvalidOperationException>(() => store.Restore(chatA, b1), "wrong chat cannot restore");
    Check(store.Restore(chatB, removed!) == b1, "restore original ID and number");
    store.Remove(chatB, b1.Id);
    Check(store.Save(chatB, "new").Number == 2, "last number survives empty shelf");

    var file = Path.Combine(temp.FullName, "bubbles.json");
    var macFixture = """
        {"version":1,"bubbles":[
          {"id":"6C62671E-552C-4CAB-8115-19554A9E2D07","text":"newest","chatKey":"thread:11111111-1111-4111-8111-111111111111"},
          {"id":"CD8A2A29-9578-4E88-97CA-6832310ABFD3","text":"older","chatKey":"thread:11111111-1111-4111-8111-111111111111"},
          {"id":"007AA607-D818-4F2D-AD1D-5CE8D1A4CCA8","text":"earlier unassigned","chatKey":"shared"},
          {"id":"2F06CE35-77BA-49FB-9267-4CA19C30BE5A","text":"hidden","chatKey":null}]}
        """;
    File.WriteAllText(file, macFixture);
    var imported = store.Visible(chatA);
    Check(imported.Count == 2 && imported[0].Text == "older" && imported[0].Number == 1 &&
        imported[1].Text == "newest" && imported[1].Number == 2 && store.Visible(chatB).Count == 0,
        "Mac v1 migration keeps unassigned suggestions off both shelves");
    var added = store.Save(chatA, "Windows draft");
    using (var document = JsonDocument.Parse(File.ReadAllText(file)))
    {
        var root = document.RootElement;
        Check(root.GetProperty("version").GetInt32() == 1 &&
            root.GetProperty("bubbles").GetArrayLength() == 5 && added.Number == 3 &&
            root.GetProperty("lastNumberByChat").GetProperty($"thread:{chatA:D}").GetInt64() == 3,
            "Mac JSON shape and legacy records preserved");
    }

    const string futureFile = """{"version":2,"bubbles":[]}""";
    File.WriteAllText(file, futureFile);
    Expect<InvalidDataException>(() => store.Save(chatA, "test"), "reject unknown file version");
    Check(File.ReadAllText(file) == futureFile, "file survives invalid write");
    Console.WriteLine("Passed Codex links, chat isolation, exact text, numbering, Remove/Undo and Mac v1 data.");
}
finally
{
    temp.Delete(recursive: true);
}

static void Check(bool condition, string failure)
{
    if (!condition)
        throw new InvalidOperationException(failure);
}

static void Expect<T>(Action action, string failure) where T : Exception
{
    try { action(); }
    catch (T) { return; }
    throw new InvalidOperationException(failure);
}
