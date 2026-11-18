# Composer Bubbles

Save a Codex composer prediction for later, right beside the composer. Each chat has its own shelf. Click a bubble to read the full prediction, or drag it into the composer and edit it before sending.

Composer Bubbles is an independent macOS companion for the Codex desktop app.

## Install on your Mac

Download the **universal DMG** from [GitHub Releases](https://github.com/noestradamus/codex-composer-bubbles/releases). The companion runs on macOS 13 or later and requires a compatible Codex desktop app.

1. Open the DMG and drag **Composer Bubbles** onto **Applications**. Eject the disk image. The **universal beta ZIP** contains the same app. If you use it, double-click the ZIP in Finder and move the extracted app into Applications.
2. Open **Composer Bubbles** from Applications. The beta app is signed with the project's own certificate and has not been notarized by Apple. If macOS blocks it and you trust the download, dismiss the alert, open **System Settings → Privacy & Security**, and scroll to **Security**. Look for **Composer Bubbles** and **Open Anyway**. This option is normally available for about an hour after the blocked launch. [Apple’s first-open instructions](https://support.apple.com/guide/mac-help/mh40617/mac)
3. Click the two-bubble icon in the macOS menu bar, choose **Enable Direct Draft Capture…**, then enable **Composer Bubbles** under **Privacy & Security → Accessibility**. Return to Codex.

## Update

Choose **View Releases on GitHub…** from the two-bubble menu. Your installed version appears at the top of that menu. To install a newer version, download its DMG, quit Composer Bubbles, drag the new copy into the same Applications folder, choose **Replace**, then reopen it.

The GitHub betas keep the same bundle ID and signing certificate so macOS can recognize the replacement and retain your Accessibility approval. Your saved bubbles and settings live outside the app. Switching from a separately signed source build, or later switching to an Apple Developer ID release, may require one new grant.

## Build from source

The app targets macOS 13 and later. To build from source, use Xcode 26 or newer, or its Command Line Tools. Run these commands from the repository directory.

```sh
./setup-local-signing.sh
./build.sh
open "Composer Bubbles.app"
```

The first command creates a dedicated signing identity in your user keychain and asks macOS to trust its certificate for code signing. Run it once on the Mac where you build. The second command builds for your Mac. Use `./build.sh --universal` to build for both Apple silicon and Intel.

For one-click capture and automatic chat detection, open the Composer Bubbles menu in the macOS menu bar, choose **Enable Direct Draft Capture…**, and turn on **Composer Bubbles** in **System Settings → Privacy & Security → Accessibility**.

To update a local build, quit Composer Bubbles, pull the latest source into the same checkout, run `./build.sh`, then reopen the app. The build script checks the new signature against the previous version. Keeping the same signing identity lets macOS recognize the update and retain the Accessibility grant.

## Save and restore a suggestion

1. In Codex, press **Tab** to accept a composer prediction into the draft.
2. Click **Save** on the floating shelf, or press **⌘⌥⇧B**. Composer Bubbles saves the text in this chat and clears the matching draft when Codex allows it. You can also drag selected text onto **Save**, or copy it and choose **Save Copied Text as Bubble** from the menu bar.
3. Click a bubble to preview the entire suggestion. Drag it out of the row into the composer to restore it as an editable draft. The bubble stays available for reuse.
4. If the row overflows, swipe with two fingers or drag sideways across a bubble or a gap. Hold **Option** to drag a bubble’s text in any direction.

If Codex hides the chat ID, the companion can ask you to link the chat. Follow the card and press **⌘⌥L** in Codex, or use your custom shortcut for **Copy chat deep link**. For help with chat detection, one-click capture, and recovering older bubbles, see the [usage guide](docs/usage.md).

## Appearance and placement

Right-click **Save** and choose **Settings…**. Choose short captions or per-chat numbers for the bubbles. The Save control can show a bookmark, text, or both. The shelf uses native clear glass on macOS 26 and later, and supports the system’s **Reduce transparency** setting.

While Codex is active, each visible Codex window has its own shelf. With a window on each display, both shelves stay visible. Each shows suggestions for the chat in its own window. Click **Save** on the window whose draft you want to keep. The keyboard shortcut uses the focused window.

Drag a shelf’s glass tab to move it. **Reset Bubble Position** returns the focused window’s shelf to its composer. In a chat with no saved suggestions, **Save** sits beside the tab.

## Local data

Suggestions are stored in `~/Library/Application Support/Composer Bubbles/bubbles.json`. The app uses Accessibility to locate the active Codex composer. When Codex hides its chat ID, the app can check a displayed chat title against Codex’s local catalog.

Choose **Remove** in a bubble’s preview to delete it. **Undo Remove Bubble** in the menu bar restores the most recent removal in that session.

## Tests

Run `./Tests/run.sh` on macOS to check shelf layout, chat isolation, stable numbering, migration of older shelves, and concurrent saves. The tests use synthetic displays and temporary directories.

Maintainers can find the DMG build and signing steps in the [release guide](docs/releases.md).
