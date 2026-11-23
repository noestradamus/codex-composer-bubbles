import AppKit

func bubbleDragItem(_ text: String) -> NSDraggingItem {
    let value = NSPasteboardItem()
    value.setString(text, forType: .string)
    return NSDraggingItem(pasteboardWriter: value)
}

private final class FloatingBubblePanel: NSPanel {
    init(label: String, identifier: String) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        title = label
        setAccessibilityLabel(label)
        setAccessibilityIdentifier(identifier)
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        animationBehavior = .none
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class BubbleDropZone: NSView {
    var onDropText: ((String) -> Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.string])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    private func canReceive(_ sender: NSDraggingInfo) -> Bool {
        !(sender.draggingSource is BubblePill)
            && sender.draggingPasteboard.availableType(from: [.string]) != nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        canReceive(sender) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard canReceive(sender), let text = sender.draggingPasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return onDropText?(text) ?? false
    }
}

private struct RowPress {
    let point: NSPoint
    let origin: CGFloat

    func offset(following pointer: NSPoint, horizontal: Bool) -> CGFloat {
        // Window y increases upward and the bubble document is flipped.
        horizontal ? origin + point.x - pointer.x : origin + pointer.y - point.y
    }
}

private final class BubblePill: NSButton, NSDraggingSource {
    let fullText: String?
    private var number: Int?
    private var measuredSize: NSSize?
    var style: BubbleStyle = .shortCaptions {
        didSet {
            guard style != oldValue else { return }
            measuredSize = nil
            updateSpokenLabel()
            needsDisplay = true
        }
    }
    var saveStyle: SaveButtonStyle = .bookmarkAndText { didSet { needsDisplay = true } }
    var orientation: ShelfOrientation = .horizontal {
        didSet { if orientation != oldValue { needsDisplay = true } }
    }
    var surface: NSRect {
        if fullText == nil {
            return SaveButtonDrawing.surfaceRect(in: bounds, style: saveStyle, bubbleStyle: style, orientation: orientation)
        }
        return BubbleGlass.surfaceRect(in: bounds, orientation: orientation)
    }
    var saveConfirmation: CGFloat = 0 {
        didSet { if saveConfirmation != oldValue { needsDisplay = true } }
    }
    weak var glassBackdrop: NSView? {
        didSet { if glassBackdrop !== oldValue { needsDisplay = true } }
    }
    var preferredCellSize: NSSize {
        if let measuredSize { return measuredSize }
        let size = BubbleGlass.cellSize(for: style, caption: title, number: number)
        measuredSize = size
        return size
    }
    override var isFlipped: Bool { false }
    var onPress: (() -> Void)?
    var requestPress: (() -> Void)?
    var canUse: (() -> Bool)?
    var dragActivity: ((Bool) -> Void)?
    var isOpen = false {
        didSet {
            guard isOpen != oldValue else { return }
            setAccessibilityExpanded(isOpen)
            needsDisplay = true
        }
    }
    private enum Gesture {
        case idle, pressed(RowPress), panning(RowPress), exporting
    }
    private var gesture = Gesture.idle

    init(title: String, text: String? = nil, identifier: String) {
        fullText = text
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(pressed)
        setAccessibilityIdentifier(identifier)
        setAccessibilityLabel(text == nil ? title : "Saved suggestion: " + title)
        setAccessibilityHelp(text ?? "Save the focused draft, or drop selected text here.")
        if text != nil { setAccessibilityExpanded(false) }
        toolTip = text == nil ? "Save the Codex draft, or drop text here. Right-click for Settings."
                              : "Click to open or close the preview. Drag toward the composer to restore."
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    convenience init(bubble: SavedBubble, style: BubbleStyle = .shortCaptions, identifier: String) {
        self.init(title: BubbleGlass.caption(for: bubble.text), text: bubble.text, identifier: identifier)
        number = bubble.number
        self.style = style
        updateSpokenLabel()
    }

    private func updateSpokenLabel() {
        guard fullText != nil else { return }
        let name = style == .numbers ? number.map { "Bubble " + String($0) } ?? "Saved suggestion" : "Saved suggestion"
        setAccessibilityLabel(name + ", " + title)
    }

    @objc private func pressed() {
        if let requestPress { requestPress(); return }
        guard canUse?() ?? true else { return }
        onPress?()
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if fullText != nil {
            drawSuggestion(nativeBackdrop: glassBackdrop?.superview != nil)
        } else {
            SaveButtonDrawing.draw(in: bounds, style: saveStyle, bubbleStyle: style, orientation: orientation, highlighted: isHighlighted,
                                   nativeBackdrop: glassBackdrop?.superview != nil, confirmation: saveConfirmation)
        }
    }

    private func drawSuggestion(nativeBackdrop: Bool) {
        BubbleGlass.draw(in: bounds, style: style, caption: title, number: number, orientation: orientation,
                         selected: isOpen || isHighlighted, nativeBackdrop: nativeBackdrop)
    }

    override func mouseDown(with event: NSEvent) {
        guard fullText != nil else { super.mouseDown(with: event); return }
        highlight(true)
        let row = enclosingScrollView as? BubbleScroll
        gesture = .pressed(RowPress(point: event.locationInWindow, origin: row?.browseOffset ?? 0))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let fullText else { return }
        let point = event.locationInWindow
        let row = enclosingScrollView as? BubbleScroll
        switch gesture {
        case .idle, .exporting:
            return
        case .pressed(let press):
            let dx = abs(point.x - press.point.x), dy = abs(point.y - press.point.y)
            let distance = hypot(dx, dy)
            guard distance >= 5 else { return }
            highlight(false)
            if let row, row.canPan, !event.modifierFlags.contains(.option), !row.exitedAcrossShelf(at: point) {
                let along = row.horizontal ? dx : dy
                let across = row.horizontal ? dy : dx
                if along >= 1.25 * across {
                    gesture = .panning(press)
                    row.browse(to: press.offset(following: point, horizontal: row.horizontal))
                    return
                }
                // Let a small diagonal move settle before choosing scrolling or a text drag.
                if across < 1.25 * along, distance < 9 { return }
            }
        case .panning(let press):
            guard let row, row.canPan else { gesture = .idle; return }
            if !event.modifierFlags.contains(.option), !row.exitedAcrossShelf(at: point) {
                row.browse(to: press.offset(following: point, horizontal: row.horizontal))
                return
            }
        }
        guard canUse?() ?? true else { gesture = .idle; return }
        gesture = .exporting
        let item = bubbleDragItem(fullText)
        let image = NSImage(size: bounds.size, flipped: isFlipped) { [self] _ in
            drawSuggestion(nativeBackdrop: false)
            return true
        }
        item.setDraggingFrame(bounds, contents: image)
        dragActivity?(true)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { gesture = .idle }
        guard fullText != nil else { super.mouseUp(with: event); return }
        highlight(false)
        if case .pressed = gesture, bounds.contains(convert(event.locationInWindow, from: nil)) { pressed() }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        gesture = .idle
        dragActivity?(false)
    }
}

private final class BubbleMoveHandle: NSButton {
    weak var glassBackdrop: NSView?
    var onMoveBegan: (() -> Void)?
    var onMoveBy: ((NSPoint) -> Void)?
    var onMoveEnded: (() -> Void)?
    private var start: NSPoint? { didSet { needsDisplay = true } }
    override var isFlipped: Bool { false }

    init() {
        super.init(frame: .zero)
        title = "Move bubbles"
        isBordered = false
        toolTip = "Drag to move bubbles"
        setAccessibilityLabel(title)
        setAccessibilityIdentifier("composer-bubbles.move")
        setAccessibilityHelp("Drag to reposition the bubble rail.")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func draw(_ dirtyRect: NSRect) {
        GlassTabDrawing.draw(in: bounds, grabbed: start != nil, nativeBackdrop: glassBackdrop?.superview != nil)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) {
        guard start == nil else { return }
        start = NSEvent.mouseLocation
        NSCursor.closedHand.push()
        onMoveBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let point = NSEvent.mouseLocation
        onMoveBy?(NSPoint(x: point.x - start.x, y: point.y - start.y))
    }

    override func mouseUp(with event: NSEvent) {
        guard start != nil else { return }
        cancelMove()
        onMoveEnded?()
    }

    func cancelMove() {
        guard start != nil else { return }
        start = nil
        NSCursor.pop()
    }
}

private final class BubbleScroll: NSScrollView {
    var horizontal = false
    private var buttons: [BubblePill] = []
    private var backedButtons: Set<BubblePill> = []
    private var backgroundPress: RowPress?
    private enum WheelAxis { case x, y }
    private var gestureAxis: WheelAxis?

    private var viewportLength: CGFloat { horizontal ? contentView.bounds.width : contentView.bounds.height }
    private var browseLimit: CGFloat {
        guard let documentView else { return 0 }
        return max(0, (horizontal ? documentView.frame.width : documentView.frame.height) - viewportLength)
    }
    var browseOffset: CGFloat { horizontal ? contentView.bounds.minX : contentView.bounds.minY }
    var canPan: Bool { browseLimit > 0.5 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        hasHorizontalScroller = false
        drawsBackground = false
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(updateBackdrops),
            name: NSView.boundsDidChangeNotification, object: contentView)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func layoutBubbles(_ pills: [BubblePill], centered: Bool, portraitCell: NSSize? = nil) {
        guard let documentView else { return }
        backgroundPress = nil
        gestureAxis = nil
        buttons = pills
        let viewportWidth = max(0, contentSize.width)
        // Keep captions at their readable widths. Compressing a nearly full
        // row to exactly the viewport used to eliminate both browsing gestures.
        let widths = pills.map { min(portraitCell?.width ?? $0.preferredCellSize.width, viewportWidth) }
        let occupied = widths.reduce(0, +)
        let row = portraitCell?.height ?? BubbleGlass.rowHeight
        let width = horizontal ? max(occupied, viewportWidth) : viewportWidth
        let size = NSSize(width: width, height: horizontal ? row : row * CGFloat(pills.count))
        if documentView.frame.size != size { documentView.setFrameSize(size) }
        var x = centered ? max(0, (width - occupied) / 2) : 0
        for (index, pill) in pills.enumerated() {
            let w = min(widths[index], width)
            let frame = NSRect(x: horizontal ? x : (width - w) / 2, y: horizontal ? 0 : CGFloat(index) * row,
                               width: w, height: row)
            pill.orientation = portraitCell == nil ? .horizontal : .vertical
            if pill.frame != frame { pill.frame = frame }
            x += w
        }
        // A label change or removal can shorten the document while it is scrolled.
        browse(to: browseOffset)
        updateBackdrops()
        window?.invalidateCursorRects(for: self)
        let direction = horizontal ? "sideways" : "up and down"
        setAccessibilityHelp(canPan ? "Swipe with two fingers or drag \(direction) to browse saved suggestions." : nil)
    }

    @objc private func displayOptionsChanged() {
        updateBackdrops()
        buttons.forEach { $0.needsDisplay = true }
    }

    func exitedAcrossShelf(at windowPoint: NSPoint) -> Bool {
        let point = convert(windowPoint, from: nil)
        if horizontal { return point.y < bounds.minY - 8 || point.y > bounds.maxY + 8 }
        return point.x < bounds.minX - 8 || point.x > bounds.maxX + 8
    }

    func visibleSurface(of pill: BubblePill) -> NSRect {
        guard let documentView else { return .zero }
        let face = documentView.convert(pill.surface, from: pill)
        return face.intersection(contentView.documentVisibleRect)
    }

    func browse(to requested: CGFloat) {
        guard documentView != nil else { return }
        let offset = min(browseLimit, max(0, requested))
        guard offset != browseOffset else { return }
        let clip = contentView
        clip.scroll(to: horizontal ? NSPoint(x: offset, y: clip.bounds.minY) : NSPoint(x: clip.bounds.minX, y: offset))
        reflectScrolledClipView(clip)
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard canPan else { return super.accessibilityCustomActions() }
        var actions = super.accessibilityCustomActions() ?? []
        if browseOffset > 0 {
            actions.append(NSAccessibilityCustomAction(name: horizontal ? "Scroll left" : "Scroll up",
                                                       target: self, selector: #selector(pageBackward)))
        }
        if browseOffset < browseLimit {
            actions.append(NSAccessibilityCustomAction(name: horizontal ? "Scroll right" : "Scroll down",
                                                       target: self, selector: #selector(pageForward)))
        }
        return actions
    }

    @objc private func pageBackward() -> Bool { page(by: -viewportLength) }
    @objc private func pageForward() -> Bool { page(by: viewportLength) }

    private func page(by distance: CGFloat) -> Bool {
        let previous = browseOffset
        browse(to: previous + distance)
        return browseOffset != previous
    }

    override func moveLeft(_ sender: Any?) {
        if horizontal && canPan { _ = pageBackward() } else { super.moveLeft(sender) }
    }

    override func moveRight(_ sender: Any?) {
        if horizontal && canPan { _ = pageForward() } else { super.moveRight(sender) }
    }

    override func moveUp(_ sender: Any?) {
        if !horizontal && canPan { _ = pageBackward() } else { super.moveUp(sender) }
    }

    override func moveDown(_ sender: Any?) {
        if !horizontal && canPan { _ = pageForward() } else { super.moveDown(sender) }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if canPan { addCursorRect(contentView.frame, cursor: .openHand) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        guard canPan else { return hit }
        if hit === documentView || hit === contentView { return self }
        if let pill = hit as? BubblePill,
           !pill.surface.contains(pill.convert(point, from: superview)) { return self }
        return hit
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard canPan else { super.mouseDown(with: event); return }
        backgroundPress = RowPress(point: event.locationInWindow, origin: browseOffset)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let backgroundPress else { super.mouseDragged(with: event); return }
        browse(to: backgroundPress.offset(following: event.locationInWindow, horizontal: horizontal))
    }

    override func mouseUp(with event: NSEvent) {
        guard backgroundPress != nil else { super.mouseUp(with: event); return }
        backgroundPress = nil
    }

    // The scroll view clips each complete glass shape. Only visible bubbles need
    // a compositor view, even when the document has hundreds of buttons.
    @objc private func updateBackdrops() {
        guard let documentView else { return }
        let viewport = documentVisibleRect
        let visible: [(BubblePill, NSRect)] = BubbleGlass.usesNativeBackdrop && !viewport.isEmpty
            ? buttons.compactMap { button in
                guard button.superview === documentView, button.frame.intersects(viewport) else { return nil }
                let surface = documentView.convert(button.surface, from: button)
                return surface.intersects(viewport) ? (button, surface) : nil
            } : []
        let visibleButtons = Set(visible.map { $0.0 })
        var reusable: [NSView] = []
        for old in backedButtons.subtracting(visibleButtons) {
            if let glass = old.glassBackdrop { reusable.append(glass) }
            old.glassBackdrop = nil
        }
        for (button, frame) in visible {
            if button.glassBackdrop == nil {
                guard let glass = reusable.popLast() ?? BubbleGlass.makeBackdrop() else { continue }
                if glass.superview !== documentView {
                    documentView.addSubview(glass, positioned: .below, relativeTo: nil)
                }
                button.glassBackdrop = glass
            }
            if let glass = button.glassBackdrop, glass.frame != frame { glass.frame = frame }
        }
        reusable.forEach { $0.removeFromSuperview() }
        backedButtons = visibleButtons
    }

    override func scrollWheel(with event: NSEvent) {
        guard horizontal && canPan else {
            gestureAxis = nil
            super.scrollWheel(with: event)
            return
        }
        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        let phased = !event.phase.isEmpty || !event.momentumPhase.isEmpty
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) || !phased { gestureAxis = nil }
        if dx != 0 || dy != 0 {
            let axis = gestureAxis ?? (abs(dx) >= abs(dy) ? .x : .y)
            // Wait for a meaningful sample before locking a trackpad's swipe axis.
            if phased, max(abs(dx), abs(dy)) >= 1 { gestureAxis = axis }
            let delta = axis == .x ? dx : dy
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : horizontalLineScroll
            browse(to: browseOffset - delta * scale)
        }
        if event.phase.contains(.cancelled) || event.momentumPhase.contains(.ended) ||
            event.momentumPhase.contains(.cancelled) { gestureAxis = nil }
    }
}

private final class PreviewGlassInk: NSView {
    var body = NSRect.zero
    var tip: NSPoint?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard !body.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        // Keep the center close to the editor's paper color, with just enough
        // tint behind the text to separate it from the chat underneath.
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        context.saveGState()
        context.addPath(BubbleGlass.contour(of: body, tip: tip))
        context.setFillColor(CGColor(gray: dark ? 0.08 : 1, alpha: dark ? 0.22 : 0.32))
        context.fillPath()
        context.restoreGState()
        BubbleGlass.drawSurface(in: body, tip: tip)
    }
}

private final class BubbleCallout: NSView {
    private let frost = NSVisualEffectView()
    private let ink = PreviewGlassInk()
    private var glass: NSView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        // A larger reading surface needs blur behind the words. Its outline is
        // painted by the same glass renderer as the collapsed bubble.
        frost.material = .popover
        frost.blendingMode = .behindWindow
        frost.state = .active
        frost.alphaValue = 0.30
        for decoration in [frost, ink] as [NSView] {
            decoration.setAccessibilityElement(false)
            addSubview(decoration)
        }
        appearanceChanged()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appearanceChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    @objc private func appearanceChanged() {
        if BubbleGlass.usesNativeBackdrop {
            if glass == nil, let backdrop = BubbleGlass.makeBackdrop() {
                glass = backdrop
                addSubview(backdrop, positioned: .below, relativeTo: ink)
                BubbleGlass.fitPreviewBackdrop(backdrop, to: ink.body, tip: ink.tip)
            }
        } else {
            glass?.removeFromSuperview()
            glass = nil
        }
        ink.needsDisplay = true
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        ink.needsDisplay = true
    }

    func shape(body: NSRect, tip: NSPoint? = nil) {
        let face = body.insetBy(dx: 1.5, dy: 1.5)
        guard !face.isEmpty, face != ink.body || tip != ink.tip || frost.frame != bounds else { return }
        ink.body = face
        ink.tip = tip
        ink.frame = bounds
        frost.frame = bounds
        BubbleGlass.fitPreviewBackdrop(glass, to: face, tip: tip)
        let outline = BubbleGlass.contour(of: face, tip: tip)
        frost.maskImage = NSImage(size: bounds.size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(outline)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fillPath()
            return true
        }
        ink.needsDisplay = true
        window?.invalidateShadow()
    }
}

private class TopDownDocument: NSView {
    override var isFlipped: Bool { true }
}

private final class BubbleDocument: TopDownDocument {
    override func draw(_ dirtyRect: NSRect) {
        // WindowServer passes fully transparent pixels through. Drawing here
        // keeps the gutters interactive without NSScrollView's opaque backing.
        NSColor(calibratedWhite: 0.5, alpha: 0.02).setFill()
        dirtyRect.fill()
    }
}

/// Inset scrollers take space from the text after AppKit tiles a scroll view.
/// The document must wrap at that final width, including when the system changes scroller style.
private final class PreviewTextScroll: NSScrollView {
    private var fitting = false

    func setText(_ value: String) {
        (documentView as? NSTextView)?.string = value
    }

    override func tile() {
        super.tile()
        fitDocument()
    }

    func fitDocument() {
        guard !fitting, let text = documentView as? NSTextView else { return }
        fitting = true
        defer { fitting = false }
        // Let TextKit 2 resize the document as it lays out the viewport. Only
        // constrain the width and minimum height to the tiled scroll area.
        for _ in 0..<2 {
            let viewport = contentView.bounds.size
            guard viewport.width > 0, viewport.height > 0 else { return }
            if text.minSize.height != viewport.height {
                text.minSize = NSSize(width: 0, height: viewport.height)
            }
            if text.frame.width != viewport.width || text.frame.height < viewport.height {
                text.setFrameSize(NSSize(width: viewport.width, height: max(text.frame.height, viewport.height)))
            }
            if contentView.bounds.size == viewport { break }
        }
    }
}

@MainActor
private func configurePreviewText(_ text: NSTextView, in scroll: PreviewTextScroll) {
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay
    text.drawsBackground = false
    text.textColor = .labelColor
    text.isEditable = false
    text.isSelectable = true
    text.isRichText = false
    text.isHorizontallyResizable = false
    text.isVerticallyResizable = true
    text.minSize = .zero
    text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    text.textContainer?.widthTracksTextView = true
    text.textContainer?.lineFragmentPadding = 0
    text.textContainerInset = .zero
    text.font = .systemFont(ofSize: 13)
    text.setAccessibilityLabel("Full suggestion")
    scroll.documentView = text
}

@MainActor
private func configureRemoveButton(_ button: NSButton, identifier: String) {
    button.isBordered = false
    button.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
    button.imagePosition = .imageLeading
    button.imageHugsTitle = true
    button.font = .systemFont(ofSize: 11)
    button.contentTintColor = .secondaryLabelColor
    button.setAccessibilityLabel("Remove saved bubble")
    button.setAccessibilityIdentifier(identifier)
}

/// A one-use snapshot opened by an explicit chat-link copy. This activating
/// window owns its items independently of the nonactivating, tracked rail.
@MainActor
private final class LinkedBubbleWindow: NSWindow {
    var onDismiss: (() -> Void)?
    private let stack = BubbleDocument()
    private let list = BubbleScroll()
    private let hint = NSTextField(labelWithString: "")
    private let undo = NSButton(title: "Undo", target: nil, action: nil)
    private let remove = NSButton(title: "Remove", target: nil, action: nil)
    private let preview = NSTextView(usingTextLayoutManager: true)
    private let previewScroll = PreviewTextScroll()
    private let previewSurface = BubbleCallout(frame: .zero)
    private let initialScreen: NSRect
    private let onRemove: (UUID) -> Bool
    private let onUndo: (UUID) -> SavedBubble?
    private var undoID: UUID?
    private var items: [SavedBubble] = []
    private var orbs: [BubblePill] = []
    private var selected: BubblePill?
    private var style: BubbleStyle
    private var orientation: ShelfOrientation
    private var portraitCell: NSSize? { orientation == .vertical ? BubbleGlass.portraitCell(for: style) : nil }
    private var expansionAbove: CGFloat = 0
    private var layingOutSnapshot = false
    private var dragging = false
    private var dismissed = false

    init(items: [SavedBubble], near anchor: NSRect, on screen: NSRect, style: BubbleStyle = .shortCaptions,
         orientation: ShelfOrientation = .horizontal,
         undoID: UUID?, onRemove: @escaping (UUID) -> Bool, onUndo: @escaping (UUID) -> SavedBubble?) {
        self.style = style
        self.orientation = orientation
        self.initialScreen = screen
        self.undoID = undoID
        self.onRemove = onRemove
        self.onUndo = onUndo
        let width = min(330, screen.width - 12)
        let size = NSSize(width: width, height: items.isEmpty ? 56 : 45 + BubbleGlass.rowHeight)
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isRestorable = false
        title = "Bubbles for This Chat"
        setAccessibilityIdentifier("composer-bubbles.linked-window")
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        level = .floating
        let content = TopDownDocument(frame: NSRect(origin: .zero, size: size))
        contentView = content

        hint.setAccessibilityIdentifier("composer-bubbles.linked-hint")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        content.addSubview(hint)
        undo.isBordered = false
        undo.font = .systemFont(ofSize: 12)
        undo.setAccessibilityIdentifier("composer-bubbles.linked-undo")
        undo.setAccessibilityLabel("Undo remove bubble")
        undo.toolTip = "Undo the last bubble removal in this chat."
        undo.target = self
        undo.action = #selector(undoRemoval)
        content.addSubview(undo)

        list.horizontal = orientation == .horizontal
        list.hasVerticalScroller = !list.horizontal
        list.scrollerStyle = .overlay
        list.autohidesScrollers = true
        list.setAccessibilityLabel("Bubbles saved in this chat")
        list.documentView = stack
        content.addSubview(list)
        configurePreviewText(preview, in: previewScroll)
        preview.setAccessibilityIdentifier("composer-bubbles.linked-preview")
        previewSurface.addSubview(previewScroll)
        configureRemoveButton(remove, identifier: "composer-bubbles.linked-remove")
        remove.target = self
        remove.action = #selector(removeSelection)
        previewSurface.addSubview(remove)
        content.addSubview(previewSurface)

        for item in items.sorted(by: { ($0.number ?? Int.max) < ($1.number ?? Int.max) }) {
            insert(item, at: self.items.count)
        }
        let idealX = anchor.isEmpty ? screen.midX - frame.width / 2 : anchor.maxX - frame.width
        let idealY = anchor.isEmpty ? screen.midY - frame.height / 2 : anchor.maxY + 12
        setFrameOrigin(NSPoint(x: max(screen.minX + 4, min(idealX, screen.maxX - frame.width - 4)),
                               y: max(screen.minY + 4, min(idealY, screen.maxY - frame.height - 4))))
        layoutSnapshot()
        list.layoutBubbles(orbs, centered: false, portraitCell: portraitCell)
        NotificationCenter.default.addObserver(self, selector: #selector(closeOffscreenPreview),
                                               name: NSView.boundsDidChangeNotification, object: list.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(deactivated),
                                               name: NSApplication.didResignActiveNotification, object: NSApp)
    }

    private var acceptsSnapshotAction: Bool { !dismissed && isVisible && NSApp.isActive }

    private func insert(_ item: SavedBubble, at index: Int) {
        let pill = BubblePill(bubble: item, style: style, identifier: "composer-bubbles.linked-item." + item.id.uuidString)
        pill.canUse = { [weak self] in self?.acceptsSnapshotAction == true }
        pill.onPress = { [weak self, weak pill] in
            guard let self, let pill, acceptsSnapshotAction else { return }
            select(selected === pill ? nil : pill)
        }
        // Keep a dragged source alive if Codex becomes active before AppKit ends the session.
        pill.dragActivity = { [weak self] active in
            guard let self else { return }
            dragging = active
            if !active && dismissed { finishClosing() }
        }
        items.insert(item, at: index)
        orbs.insert(pill, at: index)
        stack.addSubview(pill)
    }

    private func select(_ next: BubblePill?) {
        selected?.isOpen = false
        selected = next
        next?.isOpen = true
        previewScroll.setText(next?.fullText ?? "")
        layoutSnapshot()
        preview.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    @objc private func removeSelection() {
        guard acceptsSnapshotAction, let selected, let index = orbs.firstIndex(of: selected) else { return }
        guard !list.visibleSurface(of: selected).isEmpty else { select(nil); return }
        let id = items[index].id
        guard onRemove(id), !dismissed else { return }
        undoID = id
        items.remove(at: index)
        orbs.remove(at: index).removeFromSuperview()
        select(nil)
        list.layoutBubbles(orbs, centered: false, portraitCell: portraitCell)
    }

    @objc private func undoRemoval() {
        guard acceptsSnapshotAction, let undoID, let restored = onUndo(undoID), !dismissed else { return }
        self.undoID = nil
        if !items.contains(where: { $0.id == restored.id }) {
            let index = items.firstIndex { ($0.number ?? Int.max) > (restored.number ?? Int.max) } ?? items.count
            insert(restored, at: index)
        }
        select(nil)
        list.layoutBubbles(orbs, centered: false, portraitCell: portraitCell)
        if let index = items.firstIndex(where: { $0.id == restored.id }) { stack.scrollToVisible(orbs[index].frame) }
    }

    private func layoutSnapshot() {
        layingOutSnapshot = true
        defer { layingOutSnapshot = false }
        let display = screen?.visibleFrame ?? initialScreen
        let top = frame.maxY - expansionAbove
        let width = contentRect(forFrameRect: frame).width
        let row = portraitCell?.height ?? BubbleGlass.rowHeight
        let rows = portraitCell == nil ? 1 : min(items.count, ShelfPlacement.maximumColumnRows)
        let titleHeight = frame.height - contentRect(forFrameRect: frame).height
        let usableHeight = max(row, display.height - titleHeight - 45 - 112 - 8)
        let listHeight = min(row * CGFloat(rows), usableHeight)
        let collapsed = items.isEmpty ? CGFloat(56) : 45 + listHeight
        let baseHeight = frameRect(forContentRect: NSRect(x: 0, y: 0, width: width, height: collapsed)).height
        let gap: CGFloat = 4
        let below = top - baseHeight - display.minY - gap
        let above = display.maxY - gap - top
        let extra: CGFloat = selected == nil ? 0 : min(112, max(0, display.height - 2 * gap - baseHeight))
        expansionAbove = below < extra && above > below ? extra : 0
        let size = NSSize(width: width, height: collapsed + extra)
        let bounds = frameRect(forContentRect: NSRect(origin: .zero, size: size))
        let y = min(display.maxY - gap - bounds.height, max(display.minY + gap, top + expansionAbove - bounds.height))
        let nextFrame = NSRect(x: frame.minX, y: y, width: bounds.width, height: bounds.height)
        if nextFrame != frame { setFrame(nextFrame, display: true) }

        hint.stringValue = items.isEmpty ? "No saved bubbles in this chat." : "Click to read. Drag into Codex to edit."
        hint.frame = NSRect(x: 14, y: expansionAbove + (items.isEmpty ? 17 : 10),
                            width: width - (undoID == nil ? 28 : 71), height: 21)
        undo.isHidden = undoID == nil
        undo.frame = NSRect(x: width - 53, y: hint.frame.minY, width: 41, height: 21)
        list.isHidden = items.isEmpty
        list.frame = NSRect(x: 12, y: expansionAbove + 38, width: width - 24, height: listHeight)
        previewSurface.isHidden = selected == nil
        if selected != nil {
            let previewY = expansionAbove > 0 ? gap : list.frame.maxY + gap
            previewSurface.frame = NSRect(x: 12, y: previewY, width: width - 24, height: max(0, extra - 6))
            previewSurface.shape(body: previewSurface.bounds)
            previewScroll.frame = NSRect(x: 14, y: 31, width: previewSurface.bounds.width - 28,
                                         height: max(1, previewSurface.bounds.height - 40))
            previewScroll.fitDocument()
            remove.frame = NSRect(x: 10, y: 5, width: 61, height: 21)
        }
    }

    func setStyle(_ style: BubbleStyle) {
        self.style = style
        orbs.forEach { $0.style = style }
        layoutSnapshot()
        layingOutSnapshot = true
        list.layoutBubbles(orbs, centered: false, portraitCell: portraitCell)
        if let selected { stack.scrollToVisible(selected.frame) }
        layingOutSnapshot = false
        closeOffscreenPreview()
    }

    func setOrientation(_ next: ShelfOrientation) {
        guard orientation != next else { return }
        orientation = next
        layoutSnapshot()
        layingOutSnapshot = true
        list.horizontal = next == .horizontal
        list.hasVerticalScroller = !list.horizontal
        list.layoutBubbles(orbs, centered: false, portraitCell: portraitCell)
        list.contentView.scroll(to: .zero)
        list.reflectScrolledClipView(list.contentView)
        if let selected { stack.scrollToVisible(selected.frame) }
        layingOutSnapshot = false
        closeOffscreenPreview()
    }

    @objc private func closeOffscreenPreview() {
        guard !layingOutSnapshot, let selected, list.visibleSurface(of: selected).isEmpty else { return }
        select(nil)
    }

    func present() {
        if NSApp.isActive { showAfterActivation(); return }
        // An accessory app's activation can be asynchronous. Make the snapshot
        // visible only when our app owns focus, and discard a declined request.
        NotificationCenter.default.addObserver(self, selector: #selector(showAfterActivation),
                                               name: NSApplication.didBecomeActiveNotification, object: NSApp)
        if #available(macOS 14.0, *) { NSApp.activate() }
        else { NSApp.activate(ignoringOtherApps: true) }
        if NSApp.isActive && !isVisible { showAfterActivation() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, !self.isVisible, !self.dismissed else { return }
            self.close()
        }
    }

    @objc private func showAfterActivation() {
        guard !dismissed, NSApp.isActive else { return }
        NotificationCenter.default.removeObserver(self, name: NSApplication.didBecomeActiveNotification, object: NSApp)
        makeKeyAndOrderFront(nil)
    }

    @objc private func deactivated() { close() }
    override func cancelOperation(_ sender: Any?) { close() }

    override func close() {
        guard !dismissed else { return }
        dismissed = true
        orderOut(nil)
        if !dragging { finishClosing() }
    }

    private func finishClosing() {
        NotificationCenter.default.removeObserver(self)
        selected = nil
        preview.string = ""
        stack.subviews.forEach { $0.removeFromSuperview() }
        super.close()
        onDismiss?()
    }
}

@MainActor
final class BubblePanelController {
    var onSave: (() -> Void)?
    var onSettings: (() -> Void)?
    var onOrientationChange: ((ShelfOrientation) -> Void)?
    var onRemove: ((UUID) -> Void)?
    var canUseBubble: ((UUID) -> Bool)?
    var verifyPreview: ((UUID, @escaping @MainActor (Bool) -> Void) -> Void)?
    var onCancelLink: (() -> Void)?
    var onDropText: ((String) -> Bool)?
    var frame: CGRect? { panel.isVisible ? panel.frame : nil }

    private let panel = FloatingBubblePanel(label: "Composer Bubbles", identifier: "composer-bubbles.panel")
    private let card = FloatingBubblePanel(label: "Saved suggestion", identifier: "composer-bubbles.preview")
    private let root = BubbleDropZone(frame: .zero)
    private let save = BubblePill(title: "Save", identifier: "composer-bubbles.save")
    private let orientationMenuItem = NSMenuItem()
    private var confirmationTask: Task<Void, Never>?
    private let move = BubbleMoveHandle()
    private let scroll = BubbleScroll(frame: .zero)
    private let document = BubbleDocument(frame: .zero)
    private let textScroll = PreviewTextScroll(frame: .zero)
    private let previewText = NSTextView(usingTextLayoutManager: true)
    private let remove = NSButton(title: "Remove", target: nil, action: nil)
    private let cancelLink = NSButton(title: "Cancel", target: nil, action: nil)
    private let previewSurface = BubbleCallout(frame: .zero)
    private var linkedWindow: LinkedBubbleWindow?
    private var style = BubbleStyle.shortCaptions
    private var orientation = ShelfOrientation.horizontal
    private var alternateOrientation: ShelfOrientation { orientation == .horizontal ? .vertical : .horizontal }
    private var portraitCell: NSSize? { orientation == .vertical ? BubbleGlass.portraitCell(for: style) : nil }
    private var incomingBubbles: [SavedBubble] = []
    private var bubbles: [SavedBubble] = []
    private var revealID: UUID?
    private var resetScroll = false
    private var pills: [BubblePill] = []
    private var selectedID: UUID?
    private var pendingPreview: (id: UUID, request: UUID)?
    private var previewMetrics: (available: CGFloat, width: CGFloat, textHeight: CGFloat)?
    private var linking = false {
        didSet {
            remove.isHidden = linking
            cancelLink.isHidden = !linking
        }
    }
    private var anchor = NSRect.zero
    private var screen = NSRect.zero
    private var placement: ShelfPlacement?
    private let windowID: CGWindowID
    private let placements: WindowShelfPlacements
    private var hostDisplay: ShelfDisplay?
    private var hostFrame = CGRect.zero
    private var layoutRoom: CGRect?
    private var display: ShelfDisplay?
    private var lastLayout: ShelfLayout?
    private var dragStart: NSPoint?
    private var didMove = false
    private var layoutDirty = true

    func resetPlacement() {
        guard let hostDisplay else { return }
        placements.reset(windowID, on: hostDisplay)
        placement = nil
    }

    func setSaveStyle(_ next: SaveButtonStyle) {
        guard save.saveStyle != next else { return }
        if next == .textOnly { stopSaveConfirmation() }
        save.saveStyle = next
        updateControlMaterials()
        if (bubbles.isEmpty || orientation == .vertical), let display { layout(on: display) }
    }

    func showSaveConfirmation() {
        guard panel.isVisible, save.saveStyle != .textOnly else { return }
        confirmationTask?.cancel()
        let initial = save.saveConfirmation
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let start = ProcessInfo.processInfo.systemUptime
        let hold = SaveButtonDrawing.confirmationHoldUntil
        let end = reduceMotion ? hold : SaveButtonDrawing.confirmationDuration
        confirmationTask = Task { @MainActor [weak save] in
            guard let save else { return }
            while !Task.isCancelled {
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                let level = SaveButtonDrawing.confirmation(at: elapsed, startingFrom: initial, reduceMotion: reduceMotion)
                save.saveConfirmation = level
                guard elapsed < end else { return }
                // Sleep through the hold. Only the fade uses per-frame redraws.
                let delay = level == 1 && elapsed < hold ? hold - elapsed : min(1.0 / 60, end - elapsed)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    private func stopSaveConfirmation() {
        confirmationTask?.cancel()
        confirmationTask = nil
        save.saveConfirmation = 0
    }

    @objc private func updateControlMaterials() {
        save.glassBackdrop = backdrop(under: save, current: save.glassBackdrop, surface: save.surface)
        move.glassBackdrop = backdrop(under: move, current: move.glassBackdrop,
                                      surface: GlassTabDrawing.surfaceRect(in: move.bounds))
    }

    private func backdrop(under control: NSButton, current: NSView?, surface: NSRect) -> NSView? {
        control.needsDisplay = true
        guard BubbleGlass.usesNativeBackdrop, !surface.isEmpty else {
            current?.removeFromSuperview()
            return nil
        }
        guard let glass = current ?? BubbleGlass.makeBackdrop() else { return nil }
        if glass.superview !== root { root.addSubview(glass, positioned: .below, relativeTo: control) }
        let frame = root.convert(surface, from: control)
        if glass.frame != frame { glass.frame = frame }
        return glass
    }

    func setStyle(_ next: BubbleStyle) {
        guard next != style else { return }
        style = next
        save.style = next
        pills.forEach { $0.style = next }
        linkedWindow?.setStyle(next)
        if let selectedID { revealID = selectedID }
        layoutDirty = true
        if let display { layout(on: display) }
    }

    func setOrientation(_ next: ShelfOrientation) {
        guard orientation != next else { return }
        orientation = next
        updateOrientationMenuTitle()
        linkedWindow?.setOrientation(next)
        if let selectedID { revealID = selectedID }
        layoutDirty = true
    }

    @objc private func openSettings() { onSettings?() }

    @objc private func switchOrientation() { onOrientationChange?(alternateOrientation) }

    private func updateOrientationMenuTitle() {
        orientationMenuItem.title = "Switch to \(alternateOrientation.title)"
    }

    func showLinkedBubbles(_ items: [SavedBubble], undoID: UUID?,
                           onRemove: @escaping (UUID) -> Bool, onUndo: @escaping (UUID) -> SavedBubble?) {
        linkedWindow?.close()
        guard let visible = screen.isEmpty ? NSScreen.main?.visibleFrame : screen else { return }
        hide()
        let window = LinkedBubbleWindow(items: items, near: panel.frame.isEmpty ? anchor : panel.frame, on: visible,
                                        style: style, orientation: orientation, undoID: undoID,
                                        onRemove: onRemove, onUndo: onUndo)
        linkedWindow = window
        window.onDismiss = { [weak self, weak window] in
            if self?.linkedWindow === window { self?.linkedWindow = nil }
        }
        window.present()
    }

    func setChatIdentified(_ value: Bool, accessibilityEnabled: Bool = true) {
        let hint: String
        if value {
            hint = "Save a suggestion to this chat, or drop selected text here."
        } else if accessibilityEnabled {
            hint = "Click Save, then press ⌘⌥L in Codex when prompted to link this chat."
        } else {
            hint = "Enable Composer Bubbles in macOS Accessibility settings to identify this chat."
        }
        let help = hint + " Right-click to switch layouts or open Settings."
        guard save.toolTip != help else { return }
        save.toolTip = help
        save.setAccessibilityHelp(help)
    }

    init(windowID: CGWindowID = 0, placements: WindowShelfPlacements = WindowShelfPlacements()) {
        self.windowID = windowID
        self.placements = placements
        panel.contentView = root
        root.onDropText = { [weak self] text in self?.onDropText?(text) ?? false }
        root.addSubview(save)
        root.addSubview(move)
        root.addSubview(scroll)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(updateControlMaterials),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        save.onPress = { [weak self] in self?.onSave?() }
        let saveMenu = NSMenu()
        orientationMenuItem.action = #selector(switchOrientation)
        orientationMenuItem.target = self
        updateOrientationMenuTitle()
        saveMenu.addItem(orientationMenuItem)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        saveMenu.addItem(settings)
        save.menu = saveMenu
        move.onMoveBegan = { [weak self] in
            guard let self else { return }
            dragStart = NSPoint(x: panel.frame.minX + move.frame.minX, y: panel.frame.minY + move.frame.maxY)
            didMove = false
            closePreview()
        }
        move.onMoveBy = { [weak self] delta in
            guard let self, let dragStart, let previous = placement,
                  didMove || hypot(delta.x, delta.y) >= 2 else { return }
            let screens = ShelfDisplay.connected()
            guard let next = screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
                    ?? display ?? screens.first else { return }
            let requested = NSPoint(x: dragStart.x + delta.x, y: dragStart.y + delta.y)
            placement = ShelfPlacement(displayID: next.id, grip: requested, displayFrame: next.frame,
                                       horizontal: previous.horizontal, widthLimit: previous.widthLimit,
                                       laneWidth: previous.laneWidth)
            didMove = true
            layoutRoom = nil
            layout(on: next)
        }
        move.onMoveEnded = { [weak self] in
            guard let self else { return }
            dragStart = nil
            guard didMove, let hostDisplay, let display, let previous = placement else { return }
            didMove = false
            let grip = NSPoint(x: panel.frame.minX + move.frame.minX, y: panel.frame.minY + move.frame.maxY)
            let pinned = ShelfPlacement(displayID: display.id, grip: grip, displayFrame: display.frame,
                                        horizontal: previous.horizontal, widthLimit: previous.widthLimit,
                                        laneWidth: previous.laneWidth)
            placement = pinned
            placements.pin(pinned, id: windowID, window: hostFrame, host: hostDisplay)
        }
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.documentView = document
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(didScroll),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        scroll.setAccessibilityLabel("Saved suggestions")
        configurePreview()
    }

    private func configurePreview() {
        card.hasShadow = true
        card.contentView = previewSurface
        configurePreviewText(previewText, in: textScroll)
        previewText.setAccessibilityIdentifier("composer-bubbles.preview-text")
        previewSurface.addSubview(textScroll)
        configureRemoveButton(remove, identifier: "composer-bubbles.remove")
        remove.target = self
        remove.action = #selector(removeSelection)
        previewSurface.addSubview(remove)
        cancelLink.isBordered = false
        cancelLink.font = remove.font
        cancelLink.contentTintColor = .secondaryLabelColor
        cancelLink.setAccessibilityLabel("Cancel chat linking")
        cancelLink.setAccessibilityIdentifier("composer-bubbles.cancel-link")
        cancelLink.target = self
        cancelLink.action = #selector(closePreview)
        cancelLink.isHidden = true
        previewSurface.addSubview(cancelLink)
    }

    func show(bubbles incoming: [SavedBubble], anchor: NSRect, screen: NSRect, realAnchor: Bool = true,
              hostFrame: CGRect? = nil, avoiding occupied: [CGRect] = [], occludedBy windows: [CGRect] = []) {
        guard screen.width > 0 && screen.height > 0 else { hide(); return }
        self.anchor = anchor
        if incoming != incomingBubbles {
            let oldIDs = Set(bubbles.map(\.id))
            let sameChat = incoming.first?.chatKey == bubbles.first?.chatKey
            resetScroll = !sameChat || oldIDs.isEmpty
            if sameChat && !oldIDs.isEmpty && incoming.count == oldIDs.count + 1 {
                revealID = incoming.first(where: { !oldIDs.contains($0.id) })?.id
            } else { revealID = nil }
            if let selectedID, let selected = bubbles.first(where: { $0.id == selectedID }),
               !incoming.contains(selected) {
                // Remove must refer to the exact record shown in the open preview.
                closePreview()
            }
            incomingBubbles = incoming
            updatePills(incoming.sorted { ($0.number ?? Int.max) < ($1.number ?? Int.max) })
        }
        guard dragStart == nil else { return }
        let screens = ShelfDisplay.connected()
        guard let host = ShelfDisplay.containing(screen, in: screens) else { hide(); return }
        hostDisplay = host
        self.hostFrame = hostFrame ?? host.frame
        let result = placements.resolve(id: windowID, window: self.hostFrame, host: host, connected: screens,
                                        anchor: anchor, count: bubbles.count, realAnchor: realAnchor)
        placement = result.placement
        layoutRoom = result.placement.visibleRoom(on: result.display, host: host, window: self.hostFrame,
                                                  count: bubbles.count, saveWidth: saveWidth, portraitCell: portraitCell,
                                                  avoiding: occupied, occludedBy: windows)
        guard layoutRoom != nil else { hide(); return }
        layout(on: result.display)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() {
        move.cancelMove()
        dragStart = nil
        didMove = false
        stopSaveConfirmation()
        closePreview()
        if panel.isVisible { panel.orderOut(nil) }
    }

    func retire() {
        hide()
        linkedWindow?.close()
        linkedWindow = nil
        card.close()
        panel.close()
    }

    private func updatePills(_ next: [SavedBubble]) {
        pendingPreview = nil
        var existing: [UUID: (bubble: SavedBubble, pill: BubblePill)] = [:]
        for (bubble, pill) in zip(bubbles, pills) {
            let duplicate = existing.updateValue((bubble, pill), forKey: bubble.id)
            duplicate?.pill.removeFromSuperview()
        }
        pills = next.map { bubble in
            if let prior = existing.removeValue(forKey: bubble.id) {
                if prior.bubble == bubble { return prior.pill }
                prior.pill.removeFromSuperview()
            }
            let pill = BubblePill(bubble: bubble, style: style, identifier: "composer-bubbles.item." + bubble.id.uuidString)
            pill.isOpen = bubble.id == selectedID
            pill.canUse = { [weak self] in
                guard let self else { return false }
                return self.canUseBubble?(bubble.id) ?? true
            }
            pill.requestPress = { [weak self] in self?.requestPreview(bubble.id) }
            document.addSubview(pill)
            return pill
        }
        existing.values.forEach { $0.pill.removeFromSuperview() }
        bubbles = next
        layoutDirty = true
    }

    private static func clamped(_ frame: NSRect, within screen: NSRect) -> NSRect {
        let room = screen.insetBy(dx: 4, dy: 4)
        return NSRect(x: min(max(room.minX, frame.minX), max(room.minX, room.maxX - frame.width)),
                      y: min(max(room.minY, frame.minY), max(room.minY, room.maxY - frame.height)),
                      width: frame.width, height: frame.height).integral
    }

    private var saveWidth: CGFloat {
        if bubbles.isEmpty {
            return SaveButtonDrawing.size(for: save.saveStyle, bubbleStyle: style).width
        }
        return SaveButtonDrawing.reservedWidth
    }

    private func layout(on display: ShelfDisplay) {
        guard let placement else { return }
        let room = layoutRoom ?? placement.layoutDisplay(display, host: hostDisplay, window: hostFrame).visibleFrame
        let geometry = placement.layout(displayFrame: display.frame, visibleFrame: room,
                                        count: bubbles.count, emptySaveWidth: saveWidth, portraitCell: portraitCell)
        let displayChanged = self.display != display
        self.display = display
        screen = display.visibleFrame
        if panel.frame != geometry.frame { panel.setFrame(geometry.frame, display: true) }
        let changed = geometry != lastLayout
        let needsLayout = layoutDirty || changed
        if needsLayout {
            // Reconcile the preview after all frame changes and automatic scrolling are complete.
            layoutDirty = true
            layoutPills(geometry)
            lastLayout = geometry
            layoutDirty = false
        }
        if needsLayout || displayChanged {
            if linking { positionPreview() } else { didScroll() }
        }
    }

    private func layoutPills(_ geometry: ShelfLayout) {
        let horizontal = geometry.horizontal
        let orientationChanged = lastLayout?.horizontal != horizontal || lastLayout?.controlOrientation != geometry.controlOrientation
        move.frame = geometry.header
        save.orientation = geometry.controlOrientation
        save.frame = geometry.save
        updateControlMaterials()
        scroll.horizontal = horizontal
        scroll.hasVerticalScroller = !horizontal
        scroll.isHidden = pills.isEmpty
        scroll.frame = geometry.list
        let cell = geometry.controlOrientation == .vertical ? portraitCell : nil
        scroll.layoutBubbles(pills, centered: true, portraitCell: cell)
        if orientationChanged || resetScroll {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
            resetScroll = false
        }
        if let revealID, let index = bubbles.firstIndex(where: { $0.id == revealID }) {
            document.scrollToVisible(pills[index].frame)
        }
        revealID = nil
    }

    @objc private func didScroll() {
        guard let selectedID, !layoutDirty, let index = bubbles.firstIndex(where: { $0.id == selectedID }) else { return }
        if visibleSurface(of: pills[index]).isEmpty { closePreview() } else { positionPreview() }
    }

    private func visibleSurface(of pill: BubblePill) -> NSRect {
        scroll.visibleSurface(of: pill)
    }

    private func requestPreview(_ id: UUID) {
        if selectedID == id { closePreview(); return }
        if pendingPreview?.id == id { pendingPreview = nil; return }
        guard let verifyPreview else {
            if canUseBubble?(id) ?? true { togglePreview(id) }
            return
        }
        let request = UUID()
        pendingPreview = (id, request)
        verifyPreview(id) { [weak self] allowed in
            guard let self, pendingPreview?.request == request else { return }
            pendingPreview = nil
            guard allowed, panel.isVisible, let index = bubbles.firstIndex(where: { $0.id == id }),
                  !visibleSurface(of: pills[index]).isEmpty else { return }
            togglePreview(id)
        }
    }

    private func togglePreview(_ id: UUID) {
        if linking { closePreview() }
        if selectedID == id { closePreview(); return }
        guard let index = bubbles.firstIndex(where: { $0.id == id }), !visibleSurface(of: pills[index]).isEmpty else { return }
        selectedID = id
        for (i, pill) in pills.enumerated() { pill.isOpen = i == index }
        textScroll.setText(bubbles[index].text)
        previewMetrics = nil
        positionPreview()
        previewText.scrollRangeToVisible(NSRange(location: 0, length: 0))
        card.orderFrontRegardless()
    }

    @objc private func closePreview() {
        pendingPreview = nil
        guard selectedID != nil || linking || card.isVisible else { return }
        let cancelledLink = linking
        linking = false
        selectedID = nil
        pills.forEach { $0.isOpen = false }
        card.orderOut(nil)
        if cancelledLink { onCancelLink?() }
    }

    func showLinkPrompt(_ message: String) {
        closePreview()
        linking = true
        textScroll.setText(message)
        previewMetrics = nil
        positionPreview()
        card.orderFrontRegardless()
    }

    func finishLinkPrompt() {
        guard linking else { return }
        linking = false
        closePreview()
    }

    @objc private func removeSelection() {
        guard let id = selectedID else { return }
        closePreview()
        onRemove?(id)
    }

    private func positionPreview() {
        guard screen.width > 64, screen.height > 60 else { return }
        let availableWidth = min(370, screen.width - 10)
        let sideInset: CGFloat = 16
        let horizontalInsets = 2 * sideInset
        // Scrolling an open bubble moves the callout every frame. Measure its
        // text only when the suggestion or the available width changes.
        if previewMetrics?.available != availableWidth {
            let text = previewText.string as NSString
            let font = previewText.font ?? .systemFont(ofSize: 13)
            func extent(_ width: CGFloat) -> NSRect {
                text.boundingRect(with: NSSize(width: max(1, width), height: .greatestFiniteMagnitude),
                                  options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
            }
            if text.length > 1024 {
                previewMetrics = (availableWidth, availableWidth, 260)
            } else {
                let natural = extent(availableWidth - horizontalInsets)
                let width = min(availableWidth, max(155, ceil(natural.width) + horizontalInsets))
                previewMetrics = (availableWidth, width, ceil(extent(width - horizontalInsets).height))
            }
        }
        guard let metrics = previewMetrics else { return }
        let width = metrics.width
        let textWidth = width - horizontalInsets
        let bottomInset: CGFloat = 33
        let pointerHeight: CGFloat = 7
        let height = min(max(39, metrics.textHeight + 15 + bottomInset) + pointerHeight,
                         min(260, screen.height - 8))
        let vertical = orientation == .vertical && lastLayout?.horizontal == false
        let targetRect: NSRect
        if let selectedID, let index = bubbles.firstIndex(where: { $0.id == selectedID }) {
            let surface = visibleSurface(of: pills[index])
            guard !surface.isEmpty else { closePreview(); return }
            let visible = document.convert(surface, to: nil)
            let row = pills[index].convert(pills[index].bounds, to: nil)
            targetRect = vertical ? visible : NSRect(x: visible.minX, y: row.minY, width: visible.width, height: row.height)
        } else { targetRect = save.convert(save.bounds, to: nil) }
        let targetFrame = panel.convertToScreen(targetRect)
        let roomRight = screen.maxX - panel.frame.maxX, roomLeft = panel.frame.minX - screen.minX
        let frame: NSRect, body: NSRect, tip: NSPoint
        if vertical && max(roomRight, roomLeft) >= width + pointerHeight + 6 {
            let onRight = roomRight >= width + pointerHeight + 6
            let sideHeight = height - pointerHeight
            let x = onRight ? panel.frame.maxX + 2 : panel.frame.minX - 2 - width - pointerHeight
            frame = Self.clamped(NSRect(x: x, y: targetFrame.midY - sideHeight / 2,
                                        width: width + pointerHeight, height: sideHeight), within: screen)
            body = NSRect(x: onRight ? pointerHeight : 0, y: 0, width: width, height: sideHeight)
            let tipY = min(max(20, targetFrame.midY - frame.minY), sideHeight - 20)
            tip = NSPoint(x: onRight ? 1 : frame.width - 1, y: tipY)
        } else {
            let roomAbove = screen.maxY - targetFrame.maxY, roomBelow = targetFrame.minY - screen.minY
            let above = roomAbove >= height + 6 || roomAbove >= roomBelow
            let y = above ? targetFrame.maxY + 2 : targetFrame.minY - 2 - height
            frame = Self.clamped(NSRect(x: targetFrame.midX - width / 2, y: y, width: width, height: height), within: screen)
            body = NSRect(x: 0, y: above ? pointerHeight : 0, width: width, height: height - pointerHeight)
            let tipX = min(max(28, targetFrame.midX - frame.minX), width - 28)
            tip = NSPoint(x: tipX, y: above ? 1 : height - 1)
        }
        if card.frame.size != frame.size { card.setFrame(frame, display: false) }
        else if card.frame.origin != frame.origin { card.setFrameOrigin(frame.origin) }
        previewSurface.shape(body: body, tip: tip)
        let textFrame = NSRect(x: body.minX + sideInset, y: body.minY + bottomInset, width: textWidth,
                               height: max(10, body.height - 13 - bottomInset))
        if textScroll.frame != textFrame { textScroll.frame = textFrame }
        textScroll.fitDocument()
        remove.frame = NSRect(x: body.minX + 12, y: body.minY + 6, width: 61, height: 21)
        cancelLink.frame = NSRect(x: body.minX + 12, y: body.minY + 6, width: 43, height: 21)
    }
}
