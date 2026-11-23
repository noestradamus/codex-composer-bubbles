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

    static func checkText(_ text: NSTextView, in scroll: NSScrollView, matches original: String) {
        precondition(text.string.utf8.elementsEqual(original.utf8))
        let manager = text.textLayoutManager!
        manager.textViewportLayoutController.layoutViewport()
        let viewport = scroll.contentView.bounds.width
        precondition(abs(text.frame.width - viewport) < 1)
        precondition(abs(text.textContainer!.size.width - viewport) < 1)
        let first = manager.textLayoutFragment(for: manager.documentRange.location)!
        precondition(first.textLineFragments.count > 0)
        for line in first.textLineFragments.prefix(8) {
            precondition(line.typographicBounds.minX < viewport)
        }

        let last = NSRange(location: (original as NSString).length - 1, length: 1)
        text.scrollRangeToVisible(last)
        manager.textViewportLayoutController.layoutViewport()
        let lastLocation = manager.location(manager.documentRange.endLocation, offsetBy: -1)!
        let fragment = manager.textLayoutFragment(for: lastLocation)!
        let line = fragment.textLineFragments.last!
        let lineY = fragment.layoutFragmentFrame.minY + line.typographicBounds.midY
        precondition(lineY >= scroll.documentVisibleRect.minY - 1 && lineY < scroll.documentVisibleRect.maxY + 1,
                     "The final text line is outside the viewport")
    }
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
                PreviewFixture.checkText(previewText, in: textScroll, matches: text)
                closePreview()
            }
        }
        print("Passed inset and overlay preview text wrapping and final-line checks.")

        let trace = "18:04:23.822 [WARN] expected a completed staging artifact, retrying after 250 ms {step=load_manifest; path=/artifacts/checks/window-ownership.json}\n"
        let longText = "Check the build log.\n" + String(repeating: trace, count: 1450) + "Final entry."
        present([SavedBubble(text: longText, chatKey: "test", number: 1)])
        let start = ProcessInfo.processInfo.systemUptime
        PreviewFixture.click(pills[0])
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        precondition(elapsed < 2.0, "Preview opening laid out the full build log")
        PreviewFixture.checkText(previewText, in: textScroll, matches: longText)
        closePreview()
        let short = "Start here."
        present([SavedBubble(text: short, chatKey: "test", number: 1)])
        PreviewFixture.click(pills[0])
        precondition(textScroll.documentVisibleRect.minY < 1)
        PreviewFixture.checkText(previewText, in: textScroll, matches: short)
        print("Passed a \(longText.utf8.count)-byte preview in \(Int(elapsed * 1000)) ms and return to a short preview.")
        retire()
    }

    func verifyInterruptedMove(on screen: CGRect) {
        let anchor = CGRect(x: screen.midX - 200, y: screen.minY + 135, width: 450, height: 55)
        let items = [SavedBubble(text: "Keep this in its chat.", chatKey: "test", number: 1)]
        func present() { show(bubbles: items, anchor: anchor, screen: screen, hostFrame: screen) }
        func mouse(_ kind: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: kind, location: .zero, modifierFlags: [], timestamp: 0,
                               windowNumber: panel.windowNumber, context: nil, eventNumber: 1,
                               clickCount: 1, pressure: 1)!
        }
        present()
        let original = panel.frame
        move.mouseDown(with: mouse(.leftMouseDown))
        move.onMoveBy?(CGPoint(x: -80, y: 15))
        precondition(panel.frame != original && dragStart != nil)
        hide()
        precondition(!panel.isVisible && dragStart == nil && !didMove)
        move.mouseUp(with: mouse(.leftMouseUp))
        present()
        precondition(panel.frame == original)
        move.mouseDown(with: mouse(.leftMouseDown))
        move.onMoveBy?(CGPoint(x: -80, y: 15))
        let relocated = panel.frame
        move.mouseUp(with: mouse(.leftMouseUp))
        hide()
        present()
        precondition(relocated != original && panel.frame == relocated)
        retire()
        print("Passed interrupted shelf move, original pin recovery and subsequent normal move.")
    }

    func verifyVerticalShelf(on screen: CGRect) {
        let anchor = CGRect(x: screen.midX - 155, y: screen.midY - 110, width: 460, height: 55)
        let items = (1...14).map { (number: Int) in
            SavedBubble(text: "Review test \(number) and check the exact text. 修正 👩🏽‍💻", chatKey: "test", number: number)
        }
        func present(_ items: [SavedBubble]) {
            show(bubbles: items, anchor: anchor, screen: screen, hostFrame: screen)
        }
        func pressEvent(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                               windowNumber: panel.windowNumber, context: nil, eventNumber: 1,
                               clickCount: 1, pressure: 1)!
        }
        present(items)
        let tab = panel.convertToScreen(move.frame)
        onOrientationChange = { [weak self] in self?.setOrientation($0) }
        let point = save.convert(NSPoint(x: save.bounds.midX, y: save.bounds.midY), to: nil)
        let menu = save.menu(for: pressEvent(.rightMouseDown, at: point))!
        let switchLayout = menu.item(withTitle: "Switch to Vertical")!
        precondition(menu.item(withTitle: "Settings…") != nil)
        precondition(NSApp.sendAction(switchLayout.action!, to: switchLayout.target, from: switchLayout))
        precondition(switchLayout.title == "Switch to Horizontal")
        present(items)
        precondition(!scroll.horizontal && scroll.canPan && panel.convertToScreen(move.frame) == tab)
        precondition(pills[1].frame.minY > pills[0].frame.minY && pills[1].frame.midX == pills[0].frame.midX)
        PreviewFixture.click(pills[0])
        precondition(card.isVisible && selectedID == items[0].id && !panel.frame.intersects(card.frame))

        let p = pills[0].convert(NSPoint(x: pills[0].bounds.midX, y: pills[0].bounds.midY), to: nil)
        let next = NSPoint(x: p.x, y: p.y + 160)
        pills[0].mouseDown(with: pressEvent(.leftMouseDown, at: p))
        pills[0].mouseDragged(with: pressEvent(.leftMouseDragged, at: next))
        pills[0].mouseUp(with: pressEvent(.leftMouseUp, at: next))
        precondition(scroll.browseOffset > 100 && selectedID == nil && !card.isVisible)

        let before = scroll.browseOffset
        let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                            wheelCount: 1, wheel1: -76, wheel2: 0, wheel3: 0)!
        scroll.scrollWheel(with: NSEvent(cgEvent: wheel)!)
        PreviewFixture.settle()
        precondition(scroll.browseOffset > before, "Wheel did not move the vertical viewport")

        document.scrollToVisible(pills[8].frame)
        let pill = pills[8]
        var triedExport = false
        pill.canUse = { triedExport = true; return false }
        let at = pill.convert(NSPoint(x: pill.bounds.midX, y: pill.bounds.midY), to: nil)
        let sideways = NSPoint(x: at.x + 30, y: at.y)
        pill.mouseDown(with: pressEvent(.leftMouseDown, at: at))
        pill.mouseDragged(with: pressEvent(.leftMouseDragged, at: sideways))
        pill.mouseUp(with: pressEvent(.leftMouseUp, at: sideways))
        precondition(triedExport)
        let pasted = (bubbleDragItem(items[8].text).item as? NSPasteboardItem)?.string(forType: .string)
        precondition(pasted?.utf8.elementsEqual(items[8].text.utf8) == true)

        let added = SavedBubble(text: "A new draft.", chatKey: "test", number: 15)
        present([added] + items)
        precondition(!scroll.visibleSurface(of: pills.last!).isEmpty)
        precondition(NSApp.sendAction(switchLayout.action!, to: switchLayout.target, from: switchLayout))
        precondition(switchLayout.title == "Switch to Vertical")
        present([added] + items)
        precondition(scroll.horizontal && panel.convertToScreen(move.frame) == tab)
        retire()
        print("Passed Save menu layout switching, vertical wheel, mouse pan, sideways export, preview and newest bubble reveal.")
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

    func verifyScrollingDismissesPreview(removed: () -> UUID?) {
        let first = orbs[0]
        PreviewFixture.click(first)
        precondition(selected === first && !previewSurface.isHidden)
        let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                            wheelCount: 2, wheel1: 0, wheel2: -480, wheel3: 0)!
        list.scrollWheel(with: NSEvent(cgEvent: wheel)!)
        PreviewFixture.settle()
        precondition(list.visibleSurface(of: first).isEmpty && selected == nil && previewSurface.isHidden)
        PreviewFixture.press(remove)
        precondition(removed() == nil)
        let last = orbs.last!
        stack.scrollToVisible(last.frame)
        PreviewFixture.click(last)
        PreviewFixture.checkText(preview, in: previewScroll, matches: items.last!.text)
        let lastID = items.last!.id
        PreviewFixture.press(remove)
        precondition(removed() == lastID)
        close()
    }

    func verifyVerticalLinkedShelf() {
        precondition(!list.horizontal && list.canPan && orbs[1].frame.minY > orbs[0].frame.minY)
        PreviewFixture.click(orbs[0])
        precondition(selected === orbs[0])
        list.browse(to: 280)
        precondition(selected == nil && previewSurface.isHidden)
        setOrientation(.horizontal)
        precondition(list.horizontal && orbs[0].frame.minY == orbs[1].frame.minY)
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
        let items = (1...9).map { (number: Int) in
            SavedBubble(text: "Check the deployment log for scenario \(number).\n" +
                        String(repeating: "Look for repeated failures in the build report.\n", count: 90) + "End.",
                        chatKey: "test", number: number)
        }
        var removed: UUID?
        LinkedBubbleWindow(items: items, near: .zero, on: area, undoID: nil,
            onRemove: { removed = $0; return true }, onUndo: { _ in nil }).verifyScrollingDismissesPreview { removed }
        print("Passed closing offscreen linked preview and removing the newly visible selection.")
        BubblePanelController().verifyInterruptedMove(on: area)
        BubblePanelController().verifyVerticalShelf(on: area)
        LinkedBubbleWindow(items: items, near: .zero, on: area, orientation: .vertical, undoID: nil,
            onRemove: { _ in false }, onUndo: { _ in nil }).verifyVerticalLinkedShelf()
        let suite = "ComposerBubbles.OrientationTest." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var selectedOrientation: ShelfOrientation?
        let settings = BubbleSettingsController(defaults: defaults, onChange: { _ in }, onSaveStyleChange: { _ in },
                                                onOrientationChange: { orientation in
            selectedOrientation = orientation
            orientation.save(to: defaults)
        })
        let control = settings.window!.contentView!.subviews.compactMap { $0 as? NSSegmentedControl }
            .first { $0.accessibilityIdentifier() == "composer-bubbles.orientation-picker" }!
        precondition(control.selectedSegment == 0 && ShelfOrientation.load(from: defaults) == .horizontal)
        control.selectedSegment = 1
        NSApp.sendAction(control.action!, to: control.target, from: control)
        precondition(selectedOrientation == .vertical && ShelfOrientation.load(from: defaults) == .vertical)
        settings.updateOrientation(.horizontal)
        precondition(control.selectedSegment == 0 && selectedOrientation == .vertical)
        settings.close()
        print("Passed linked vertical layout and persistent Settings selection.")
        BubblePanelController().verifyIncrementalRows(on: area)
    }
}
