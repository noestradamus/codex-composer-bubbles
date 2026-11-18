import AppKit

@MainActor
private enum PreviewFixture {
    static var active = true

    static func click(_ pill: BubblePill) {
        let window = pill.window!
        let position = pill.convert(NSPoint(x: pill.bounds.midX, y: pill.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: position, modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                               clickCount: 1, pressure: 1)!
        }
        pill.mouseDown(with: event(.leftMouseDown))
        pill.mouseUp(with: event(.leftMouseUp))
    }

    static func press(_ button: NSButton) {
        _ = NSApp.sendAction(button.action!, to: button.target, from: button)
    }

    static func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
}

@MainActor
private extension BubblePanelController {
    func verifyPreviewInteractions(on screen: CGRect) {
        let anchor = CGRect(x: screen.midX - 300, y: screen.midY - 180, width: 600, height: 80)
        func present(_ items: [SavedBubble]) {
            show(bubbles: items, anchor: anchor, screen: screen, hostFrame: screen)
        }
        verifyPreview = { _, approve in approve(true) }
        var items = (1...2).map { (number: Int) in
            SavedBubble(text: "Evaluate compatibility scenario \(number) in detail.", chatKey: "test", number: number)
        }
        present(items)
        PreviewFixture.click(pills[0])
        precondition(card.isVisible && selectedID == items.first?.id)
        items.append(SavedBubble(text: "Review the deployment plan.", chatKey: "test", number: 3))
        present(items)
        PreviewFixture.settle()
        precondition(!scroll.documentVisibleRect.intersects(pills[0].frame))
        precondition(scroll.documentVisibleRect.intersects(pills[2].frame))
        precondition(selectedID == nil && !card.isVisible, "A hidden bubble's preview is still actionable")
        var removed: UUID?
        onRemove = { removed = $0 }
        PreviewFixture.press(remove)
        precondition(removed == nil)
        PreviewFixture.click(pills[2])
        PreviewFixture.press(remove)
        precondition(removed == items[2].id)
        print("Passed automatic scroll and preview ownership checks.")

        let row = (1...48).map { (number: Int) in
            SavedBubble(text: "Review compatibility scenario \(number) in detail.", chatKey: "test", number: number)
        }
        setStyle(.numbers)
        present(row)
        document.scrollToVisible(pills[40].frame)
        PreviewFixture.click(pills[40])
        precondition(selectedID == row[40].id && card.isVisible)
        setStyle(.shortCaptions)
        precondition(selectedID == row[40].id && card.isVisible && !visibleSurface(of: pills[40]).isEmpty)

        // Simulate replacement of a still-open model with the same ID. The old
        // card must no longer be able to delete it, including UTF-8-only changes.
        var updated = row
        for text in ["Review café.", "Review cafe\u{0301}."] {
            updated[40] = SavedBubble(id: row[40].id, text: text, chatKey: "test", number: 41)
            removed = nil
            present(updated)
            precondition(selectedID == nil && !card.isVisible)
            PreviewFixture.press(remove)
            precondition(removed == nil)
            document.scrollToVisible(pills[40].frame)
            PreviewFixture.click(pills[40])
            precondition(selectedID == row[40].id && previewText.string.utf8.elementsEqual(text.utf8))
        }
        closePreview()
        print("Passed scrolled style switch and same-ID replacement checks.")

        let texts = ["\t\twidth\tmore words\n", "....", "花鳥風月について説明して",
                     "  let result = collections[active] as? [String : Value] ?? [:]\n", "🙂👨‍👩‍👧‍👦🌐"]
        for scroller in [NSScroller.Style.legacy, .overlay] {
            textScroll.scrollerStyle = scroller
            for sample in texts {
                let text = String(repeating: sample, count: 180) + "END"
                present([SavedBubble(text: text, chatKey: "test", number: 1)])
                PreviewFixture.click(pills[0])
                PreviewFixture.settle()
                let manager = previewText.layoutManager!, container = previewText.textContainer!
                manager.ensureLayout(for: container)
                let viewport = textScroll.contentView.bounds.width
                precondition(abs(previewText.frame.width - viewport) < 1)
                precondition(abs(container.size.width - viewport) < 1)
                // Spaces and tabs may end beyond a line's typographic bounds.
                for index in 0..<min(250, manager.numberOfGlyphs) {
                    let glyph = NSRange(location: index, length: 1)
                    let box = manager.boundingRect(forGlyphRange: glyph, in: container)
                    let range = manager.characterRange(forGlyphRange: glyph, actualGlyphRange: nil)
                    let character = (text as NSString).substring(with: range)
                    if !character.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        precondition(box.minX < viewport, "A complete glyph is clipped by the scrollbar")
                    }
                }
                let last = NSRange(location: (text as NSString).length - 1, length: 1)
                previewText.scrollRangeToVisible(last)
                PreviewFixture.settle()
                let lastGlyph = manager.glyphRange(forCharacterRange: last, actualCharacterRange: nil)
                precondition(textScroll.documentVisibleRect.intersects(manager.boundingRect(forGlyphRange: lastGlyph,
                                                                                           in: container)))
                closePreview()
            }
        }
        print("Passed inset and overlay preview text wrapping and final-glyph checks.")
        retire()
    }
}

@MainActor
private extension LinkedBubbleWindow {
    func verifyLinkedControls(id: UUID) {
        let pill = orbs[0]
        let original = convertToScreen(pill.convert(pill.bounds, to: nil))
        PreviewFixture.click(pill)
        let expanded = convertToScreen(pill.convert(pill.bounds, to: nil))
        precondition(selected === pill && !previewSurface.isHidden)
        precondition(abs(original.midY - expanded.midY) < 1 && abs(original.midX - expanded.midX) < 1)
        PreviewFixture.click(pill)
        precondition(previewSurface.isHidden && selected == nil)
        PreviewFixture.click(pill)

        PreviewFixture.active = false
        PreviewFixture.press(remove)
        precondition(items.count == 1 && selected != nil)
        PreviewFixture.active = true
        PreviewFixture.press(remove)
        precondition(items.isEmpty && selected == nil && undoID == id && !undo.isHidden)
        PreviewFixture.press(undo)
        precondition(items.map(\.id) == [id] && !list.isHidden && undoID == nil)
        PreviewFixture.click(orbs[0])
        precondition(!previewSurface.isHidden)
        close()
    }

    func verifyReopenedUndo(id: UUID) {
        precondition(items.isEmpty && !undo.isHidden && undoID == id)
        PreviewFixture.press(undo)
        precondition(items.map(\.id) == [id] && !list.isHidden && undo.isHidden)
        close()
    }
}

@main
@MainActor
private enum PreviewInteractionChecks {
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NSApp.finishLaunching()
        guard let area = NSScreen.main?.visibleFrame else {
            print("These AppKit checks need a macOS desktop session.")
            exit(2)
        }
        BubblePanelController().verifyPreviewInteractions(on: area)
        let item = SavedBubble(text: "Keep this for later.", chatKey: "test", number: 1)
        for offset in [0.0, 50.0, area.height / 2, area.height - 80] {
            let anchor = CGRect(x: area.midX, y: area.minY + offset, width: 70, height: 40)
            let window = LinkedBubbleWindow(items: [item], near: anchor, on: area, undoID: nil,
                onRemove: { $0 == item.id }, onUndo: { $0 == item.id ? item : nil })
            window.verifyLinkedControls(id: item.id)
        }
        LinkedBubbleWindow(items: [], near: .zero, on: area, undoID: item.id,
            onRemove: { _ in false }, onUndo: { $0 == item.id ? item : nil }).verifyReopenedUndo(id: item.id)
        print("Passed linked selection, stable click targets, scoped Remove and last-bubble Undo checks.")
        BubblePanelController().verifyIncrementalRows(on: area)
    }
}
