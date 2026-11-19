# Composer Bubbles for Windows

This first preview is a small Windows shelf linked explicitly to one Codex chat. It stores drafts locally, shows full previews, and drags or copies a saved bubble as text. Leaving the shelf clears the link and hides its bubbles. You can reopen that chat by pasting its link again.

## Try it on Windows

1. Extract the preview ZIP and open **ComposerBubbles.exe**. Choose the x64 ZIP for a 64-bit Intel or AMD PC or the Arm64 ZIP for a Windows on Arm PC. The ZIP includes the .NET runtime.
2. In Codex, copy a draft or accept a composer prediction and copy its text. Paste it into **Draft to save** in Composer Bubbles. Return to that Codex chat and try **Ctrl+Alt+L** to copy its chat deep link, or look for **Copy deeplink** in Codex.
3. Paste the link into **Codex chat link** in Composer Bubbles, click **Open shelf**, then **Save**. The draft in Codex stays editable.
4. Click a bubble to read it. Drag it onto an empty Codex composer, or choose **Copy** and paste it there. Edit the restored text before sending.
5. Copy a second chat’s link and open its shelf. The first chat’s bubbles should appear again only when you reopen the first link. You can remove the last bubble, reopen that chat, and choose **Undo remove** while the app is still running.

The Codex link and drag-and-drop steps need a live Windows check. You can exercise the shelf itself with two sample links if your build of Codex doesn’t expose a chat link:

- `codex://threads/11111111-1111-4111-8111-111111111111`
- `codex://threads/22222222-2222-4222-8222-222222222222`

Preview data lives in `%LOCALAPPDATA%\Composer Bubbles\bubbles.json`.

## What carries over

| Reuse from macOS | Build for Windows |
| --- | --- |
| Version 1 shelf JSON, Codex thread IDs, exact text comparison, per-chat numbering, Remove and Undo rules | C# persistence and locking with the Windows local data directory |
| App icon and save → preview → restore workflow | WPF windows, controls, preview text and Unicode drag-and-drop |
| The rule that unknown chats get no bubbles, plus the Mac regression scenarios | UI Automation discovery of the composer and chat identity, then Win32 window ownership, monitor/DPI placement and focus handling |
| Release checklist and local-data expectations | Windows tray and hotkey integration, signed packaging and update flow |

The macOS Accessibility tree and AppKit code use platform-specific interfaces. Before wiring up one-click capture, inspect the actual Windows Codex composer and the selected chat with Microsoft’s [Accessibility Insights Live Inspect](https://learn.microsoft.com/en-us/windows/apps/design/accessibility/accessibility-testing). Check whether chat IDs are available through chat switches and whether the composer exposes readable text. Automatic Save can then copy a verified draft while leaving the composer alone.

## Build and verify

Use the .NET 10 SDK. The WPF project can cross-build on macOS. Test the desktop interaction and build public release packages on Windows.

```text
dotnet run --project Windows/Tests/ComposerBubbles.Core.Checks.csproj
dotnet build Windows/App/ComposerBubbles.csproj -c Release
dotnet publish Windows/App/ComposerBubbles.csproj -c Release -r win-x64 --self-contained true -o dist/windows-x64
```

Use `win-arm64` for Arm64. Keep the whole publish folder together when running the portable preview.
