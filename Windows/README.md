# Composer Bubbles for Windows

The Windows preview keeps saved Codex drafts in a shelf linked to an explicit chat. The data stays on your PC.

## Try the preview

1. Extract the entire ZIP and run **ComposerBubbles.exe**. Choose x64 for Intel or AMD PCs or Arm64 for Windows on Arm. The ZIP includes the .NET runtime.
2. In Codex, copy a draft or accept a composer prediction and copy its text. Paste it into **Draft to save** in Composer Bubbles.
3. In Codex, try **Ctrl+Alt+L** or use **Copy deeplink** to copy the chat link. Paste that link into Composer Bubbles, select **Open shelf**, then choose **Save**.
4. Use **Save → Switch to Vertical** from the right-click menu to try the upright shelf. The same menu offers numbered bubbles and three Save styles. Hover over a bubble for a short title, click to read the full draft, and click it again to close. The layout and appearance choices persist across restarts.
5. Wheel, swipe, or drag along the shelf to browse. Drag a bubble across the shelf toward the composer to restore editable text. Use **Alt** to start a text drag in any direction. **Copy** is available in the full preview.
6. Reopen a chat’s link to see its bubbles and the draft you left in the shelf during this session. Removing a bubble offers **Undo remove** in its own chat.

**Start with Codex** is available on the link screen. Enable it to run a small background watcher at Windows sign-in. It opens the shelf when the official Microsoft Store ChatGPT/Codex desktop window comes to the front. Extract the ZIP to a permanent folder before turning it on. Turn off the checkbox before moving the folder.

Without a Codex chat link, try two fixture links to exercise the shelf and verify separation:

- `codex://threads/11111111-1111-4111-8111-111111111111`
- `codex://threads/22222222-2222-4222-8222-222222222222`

Saved bubbles live in `%LOCALAPPDATA%\Composer Bubbles\bubbles.json`. Appearance and placement live in `settings.json` in the same folder.

## Platform validation

The preview cross-builds for x64 and Arm64. The Codex link shortcut, touchpad, drag-and-drop, positioning, and startup watcher need a live Windows check. The Windows shelf still asks for an explicit link after focus leaves it. To support automatic chat detection and one-click capture, verify how the Windows Codex composer and active chat appear in [Accessibility Insights Live Inspect](https://learn.microsoft.com/en-us/windows/apps/design/accessibility/accessibility-testing) before reading either automatically.

## Build

Use the .NET 10 SDK.

```text
dotnet run --project Windows/Tests/ComposerBubbles.Core.Checks.csproj
dotnet build Windows/App/ComposerBubbles.csproj -c Release
dotnet publish Windows/App/ComposerBubbles.csproj -c Release -r win-x64 --self-contained true -o dist/windows-x64
```

Use `win-arm64` for Arm64. Keep the whole publish folder together when running the portable preview.
