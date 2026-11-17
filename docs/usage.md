# Composer Bubbles for Mac

Requires macOS 13 or later and the Codex desktop app.

Open **Composer Bubbles.app**, then return to your Codex window. The floating **Save** button first appears beside the prompt field. Drag the narrow glass tab with the single groove to position the shelf. The handle stays there as you type, switch chats, resize Codex, or reopen the companion.

Your spot is saved on the display you chose. If you unplug that display, the shelf uses the main display temporarily and returns when you reconnect it. Choose **Reset Bubble Position** from the companion’s menu to place it near the composer again.

## Appearance settings

Right-click **Save** beside the Codex composer and choose **Settings…**. You can also open **Settings…** from the Composer Bubbles icon in the macOS menu bar. Choose a style to see a preview. The choice applies to every chat on this Mac and is remembered when you reopen the app.

- **Short captions** shows a few words from each suggestion inside a clear glass rectangle shaped like the composer. This is the default. People who previously used Completely clear start here.
- **Numbers** shows **1**, **2**, **3**, and so on inside the bubbles. Each chat starts at **1**. A bubble keeps its number as you add or remove others.

Both styles use untinted Clear glass. On macOS 26 and later, bubbles use the native glass material. Earlier versions and drag previews use a transparent face with a thin highlighted edge. Bubbles use a solid surface when **Reduce transparency** is enabled in macOS Accessibility settings.

Under **Save button**, choose **Bookmark + Save** (the default), **Bookmark only**, or **Text only**. Each uses the same clear glass as the saved bubbles. The preview shows both settings together. You can click, drop text onto, or right-click the Save control in any style.

## Save and reuse a suggestion

1. Open the destination chat in Codex. When Codex suggests a follow-up, press **Tab** to put it in the draft.
2. Click **Save** to keep it in this chat. If a little card asks you to link the chat, press **⌘⌥L** (Command–Option–L) in Codex. You can also drag selected text onto **Save** or copy it and choose **Save Copied Text as Bubble**.
3. Click the new bubble to read the full text. Click the bubble again or use **×** to close it.
4. When the row fills up, swipe with two fingers or click and drag sideways across the bubbles to browse. The glass tab moves the entire shelf.
5. Pull a bubble out of the row toward the composer to restore its text as an editable draft. Hold **Option** to start a text drag in any direction. The bubble stays on the shelf until you remove it.

If your original text is still in the composer after saving, replace it with your next prompt. To test restoring into an empty draft, clear the original after the bubble appears.

## One-click capture

For faster saving, choose **Enable Direct Draft Capture…** from the menu-bar bubble icon. Allow **Composer Bubbles** in **System Settings → Privacy & Security → Accessibility**. If macOS asks you to relaunch, quit the companion from its menu and reopen it.

Updates built with the same signing identity can reuse your approval. When moving from an older ad hoc build (1.10 or earlier), grant Accessibility to the signed copy once. If macOS still shows the old entry enabled, remove it, add the new **Composer Bubbles.app**, and turn it on.

Then press **Tab** on a suggestion and click **Save**, or press **⌘⌥⇧B** while Codex is active. The companion saves the draft first. It clears the matching text when the editor allows it. If your Codex version or language exposes the field differently, use drag or **Save Copied Text as Bubble**.

## Where bubbles go

Bubbles stay on this Mac across relaunches. Each bubble belongs to one Codex chat. Switching chats shows the destination chat’s bubbles, and switching back restores the first set. The companion uses the chat ID, so two chats with the same title have separate shelves.

The sidebar can stay closed. The companion looks for the active chat ID in the composer or the selected chat tab. When Codex shows a temporary ID, the companion looks up its matching local chat ID in Codex’s settings.

The shelf can stay visible when focus leaves the composer or Codex redraws the input field. During those updates the companion checks the active window and chat before showing its bubbles. Saving or dragging performs a fresh check.

When you return to a chat, Codex can recreate the composer and its buttons. If the new view hides the ID, the companion checks the chat’s displayed title against Codex’s local catalog. An exact, unique match to a chat with saved bubbles restores its shelf automatically. If two chats have the same title and Codex hides their IDs, use the link shortcut below to open the correct shelf.

If the view still needs a link, click **Save**, then press **⌘⌥L** in Codex. If you customized that shortcut, use your binding for **Copy chat deep link**. The link stays on your clipboard. A changed draft cancels a pending direct save.

When Codex provides no reliable way to recognize the chat again, a **Bubbles for This Chat** window opens beside the composer. Click a bubble to read it, or drag it straight into Codex. Returning to Codex closes the window. To reopen it, click **Save** with an empty composer and follow the link prompt, or use **Link This Chat…** from the menu bar.

To place an older shared bubble, open its intended chat, click the menu-bar bubble icon and choose **Move Earlier Bubble to This Chat**, then select the suggestion. Earlier bubbles stay off the shelf until you assign them.

The shelf is stored in `~/Library/Application Support/Composer Bubbles/bubbles.json`. To remove a bubble, open its preview and click **Remove**. The menu bar offers **Undo Remove Bubble** for the most recent removal during that session.

## Build

For builds on your own Mac, run `./setup-local-signing.sh` once. It creates a dedicated key in your user keychain. macOS may ask you to authorize that certificate for code signing. If you downloaded a DMG, follow the [installation and update instructions](../README.md#install-on-your-mac).

With Xcode Command Line Tools installed, run `./build.sh` for your Mac’s architecture or `./build.sh --universal` for Intel and Apple silicon. Use Xcode 26 or later for native glass. Quit the companion before replacing a running build. The script stages and verifies the signed bundle before replacing the output. It checks that future updates satisfy the installed version's signing requirement.

For the GitHub beta and Apple-notarized packaging commands, see the [release guide](releases.md).
