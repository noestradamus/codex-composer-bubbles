import AppKit

struct ShelfDisplay: Equatable {
    let id: String
    let frame: NSRect
    let visibleFrame: NSRect

    @MainActor static func connected() -> [ShelfDisplay] {
        NSScreen.screens.map { ShelfDisplay(id: ShelfPlacement.identifier(for: $0), frame: $0.frame,
                                             visibleFrame: $0.visibleFrame) }
    }
}

struct ShelfLayout: Equatable {
    let frame: NSRect
    let header: NSRect
    let save: NSRect
    let list: NSRect
    let horizontal: Bool
}

/// The saved point is the top left of the move grip, measured from the top
/// left of its physical display. AppKit's global origin can change when the
/// display arrangement changes or another monitor becomes the primary display.
struct ShelfPlacement: Codable, Equatable {
    let displayID: String
    private let left: CGFloat
    private let fromTop: CGFloat
    let horizontal: Bool
    let widthLimit: CGFloat
    // Missing in placements saved by 1.5, whose outer controls were 279 pt apart as a group.
    let laneWidth: CGFloat?

    init(displayID: String, grip: NSPoint, displayFrame: NSRect, horizontal: Bool, widthLimit: CGFloat,
         laneWidth: CGFloat? = nil) {
        self.displayID = displayID
        left = grip.x - displayFrame.minX
        fromTop = displayFrame.maxY - grip.y
        self.horizontal = horizontal
        self.widthLimit = widthLimit
        self.laneWidth = laneWidth
    }

    @MainActor static func identifier(for screen: NSScreen) -> String {
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            if let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() {
                return CFUUIDCreateString(nil, uuid) as String
            }
            return "display-\(number.uint32Value)"
        }
        return screen.localizedName
    }

    func grip(in displayFrame: NSRect) -> NSPoint {
        NSPoint(x: displayFrame.minX + left, y: displayFrame.maxY - fromTop)
    }

    var isValid: Bool {
        !displayID.isEmpty && left.isFinite && fromTop.isFinite && widthLimit.isFinite && widthLimit > 0
            && (laneWidth.map { $0.isFinite && $0 > 0 } ?? true)
    }

    static func initial(anchor: NSRect, visibleFrame: NSRect, displayFrame: NSRect, displayID: String,
                        count: Int, legacyOffset: NSPoint? = nil) -> Self {
        if legacyOffset == nil {
            let width = min(idealWidth, max(0, visibleFrame.width - 8))
            let height = min(laneHeight, max(0, visibleFrame.height - 8))
            let above = anchor.maxY + 6
            let box = NSRect(x: anchor.maxX - width,
                             y: above + height <= visibleFrame.maxY - 4 ? above : anchor.minY - 6 - height,
                             width: width, height: height)
            let frame = clampInitial(box, to: visibleFrame)
            return Self(displayID: displayID, grip: NSPoint(x: frame.minX, y: frame.midY + min(15, height / 2)),
                        displayFrame: displayFrame, horizontal: true, widthLimit: width, laneWidth: idealWidth)
        }
        // Replay the pre-1.4 arrangement only for someone migrating a legacy offset.
        let count = CGFloat(max(0, count))
        let width: CGFloat = count == 0 ? 96 : 148
        let right = visibleFrame.maxX - anchor.maxX >= width + 12
        let left = anchor.minX - visibleFrame.minX >= width + 12
        let horizontal = !(right || left)
        let limit = max(96, min(visibleFrame.width - 8, max(anchor.width, 235)))
        let initial: NSRect
        if horizontal {
            let width = min(count == 0 ? 96 : 99 + count * 128, limit)
            let y = anchor.maxY + 36 <= visibleFrame.maxY - 4 ? anchor.maxY + 6 : anchor.minY - 36
            initial = NSRect(x: anchor.maxX - width, y: y, width: width, height: 30)
        } else {
            let height = min(30 + count * 34, min(245, max(30, visibleFrame.height - 8)))
            initial = NSRect(x: right ? anchor.maxX + 6 : anchor.minX - 6 - width,
                             y: anchor.midY - height / 2, width: width, height: height)
        }
        var frame = clampInitial(initial, to: visibleFrame)
        if let offset = legacyOffset {
            frame = clampInitial(frame.offsetBy(dx: offset.x, dy: offset.y), to: visibleFrame)
        }
        return Self(displayID: displayID, grip: NSPoint(x: frame.minX, y: frame.maxY),
                    displayFrame: displayFrame, horizontal: horizontal, widthLimit: limit)
    }

    private static func clampInitial(_ frame: NSRect, to screen: NSRect) -> NSRect {
        let room = screen.insetBy(dx: 4, dy: 4)
        return NSRect(x: min(max(room.minX, frame.minX), max(room.minX, room.maxX - frame.width)),
                      y: min(max(room.minY, frame.minY), max(room.minY, room.maxY - frame.height)),
                      width: frame.width, height: frame.height).integral
    }

    private static let laneHeight = BubbleGlass.rowHeight
    private static let idealWidth: CGFloat = 325

    func layout(displayFrame: NSRect, visibleFrame: NSRect, count: Int,
                emptySaveWidth: CGFloat = SaveButtonDrawing.reservedWidth) -> ShelfLayout {
        let pin = grip(in: displayFrame)
        let room = visibleFrame.insetBy(dx: min(4, visibleFrame.width / 4), dy: min(4, visibleFrame.height / 4))
        let gripWidth = min(GlassTabDrawing.controlSize.width, room.width)
        let gripHeight = min(GlassTabDrawing.controlSize.height, room.height)
        let x = min(max(pin.x, room.minX), room.maxX - gripWidth)
        let top = min(max(pin.y, room.minY + gripHeight), room.maxY)
        let grip = NSRect(x: x, y: top - gripHeight, width: gripWidth, height: gripHeight)
        let right = room.maxX - grip.minX, left = grip.maxX - room.minX
        let preferredWidth = laneWidth ?? 279
        let preferRight = right >= preferredWidth || right >= left
        let span = min(preferredWidth, max(right, left))
        let saveWidth = min(SaveButtonDrawing.reservedWidth, max(0, room.width - gripWidth - 2))
        let gap: CGFloat = 4
        let laneHeight = min(Self.laneHeight, room.height)
        let bottom = min(max(grip.midY - laneHeight / 2, room.minY), room.maxY - laneHeight)
        let area: NSRect, save: NSRect, list: NSRect
        let isRow = span >= gripWidth + saveWidth + 90 + 2 * gap
        if count == 0 {
            // Keep the tab pinned and close the bubble lane all the way up to Save.
            let available = max(0, (preferRight ? right : left) - gripWidth)
            let spacing = min(gap, available)
            let width = min(emptySaveWidth, available - spacing)
            let sx = preferRight ? grip.maxX + spacing : grip.minX - spacing - width
            save = NSRect(x: sx, y: bottom, width: width, height: laneHeight)
            area = grip.union(save)
            list = .zero
        } else if isRow {
            // Filled shelves keep the same lane as bubbles are added or styles change.
            let available = preferRight ? right : left
            let width = min(preferredWidth, available)
            area = NSRect(x: preferRight ? grip.minX : grip.maxX - width, y: bottom, width: width, height: laneHeight)
            save = NSRect(x: preferRight ? area.maxX - saveWidth : area.minX, y: bottom,
                          width: saveWidth, height: laneHeight)
            let laneX = preferRight ? grip.maxX : save.maxX
            list = NSRect(x: laneX + gap, y: bottom, width: width - gripWidth - saveWidth - 2 * gap, height: laneHeight)
        } else {
            // On a very narrow display there may be no room for even one full
            // caption between the controls. Stack the scrollable bubbles instead.
            let width = min(room.width, max(gripWidth + gap + saveWidth, 142))
            let originX = min(max(preferRight ? grip.minX : grip.maxX - width, room.minX), room.maxX - width)
            let above = room.maxY - (bottom + laneHeight), below = bottom - room.minY
            let goesUp = below < min(2 * Self.laneHeight, above)
            let listHeight = min(2 * Self.laneHeight, goesUp ? above : below)
            area = NSRect(x: originX, y: goesUp ? bottom : bottom - listHeight,
                          width: width, height: laneHeight + listHeight)
            let sx = preferRight ? min(grip.maxX + gap, room.maxX - saveWidth) : max(room.minX, grip.minX - gap - saveWidth)
            save = NSRect(x: sx, y: bottom, width: saveWidth, height: laneHeight)
            list = NSRect(x: originX, y: goesUp ? bottom + laneHeight : area.minY, width: width, height: listHeight)
        }
        let frame = area.union(grip).union(save)
        func local(_ rect: NSRect) -> NSRect { rect.offsetBy(dx: -frame.minX, dy: -frame.minY) }
        return ShelfLayout(frame: frame, header: local(grip), save: local(save),
                           list: count == 0 ? .zero : local(list), horizontal: isRow)
    }
}
