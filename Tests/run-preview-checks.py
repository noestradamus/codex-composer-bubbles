#!/usr/bin/env python3
"""Run isolated AppKit shelf checks in a logged-in macOS desktop session."""
import subprocess
import tempfile
from pathlib import Path

tests = Path(__file__).resolve().parent
source = tests.parent / "Source"


def replace_once(text, needle, replacement):
    if text.count(needle) != 1:
        raise RuntimeError(f"Update the test adapter for {needle}")
    return text.replace(needle, replacement)


with tempfile.TemporaryDirectory(prefix="composer-bubbles-preview-") as folder:
    scratch = Path(folder)
    panel = (source / "BubblePanel.swift").read_text()
    # Exercise the real AppKit views while keeping windows off the user's desktop.
    declaration = "private final class FloatingBubblePanel: NSPanel {"
    panel = replace_once(panel, declaration, declaration + """
        private var fixtureVisible = false
        override var isVisible: Bool { fixtureVisible }
        override func orderFrontRegardless() { fixtureVisible = true }
        override func orderOut(_ sender: Any?) { fixtureVisible = false }
    """)
    # Only the isolated linked window's visibility/activation belongs to the fixture.
    panel = replace_once(panel, "!dismissed && isVisible && NSApp.isActive }",
                         "!dismissed && PreviewFixture.active }")
    unit = scratch / "PanelChecks.swift"
    unit.write_text("\n".join([panel, (tests / "PreviewInteractionChecks.swift").read_text(),
                               (tests / "IncrementalRowChecks.swift").read_text()]))
    support = ["BubbleGlass", "BubbleStyle", "BubbleStore", "GlassTabDrawing", "SaveButtonDrawing",
               "ShelfPlacement", "BubbleSettingsController"]
    binary = scratch / "checks"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-O", "-parse-as-library",
                    "-module-cache-path", str(scratch / "modules"),
                    *(source / (name + ".swift") for name in support), unit, "-o", binary], check=True)
    subprocess.run([binary], check=True)
