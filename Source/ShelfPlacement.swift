import AppKit

struct ShelfDisplay: Equatable {
    let id: String
    let frame: NSRect
    let visibleFrame: NSRect

    @MainActor static func connected() -> [ShelfDisplay] {
        NSScreen.screens.map { ShelfDisplay(id: ShelfPlacement.identifier(for: $0), frame: $0.frame,
                                             visibleFrame: $0.visibleFrame) }
    }

    static func containing(_ visibleFrame: NSRect, in displays: [ShelfDisplay]) -> ShelfDisplay? {
        if let match = displays.first(where: { $0.visibleFrame == visibleFrame }) { return match }
        func area(_ display: ShelfDisplay) -> CGFloat {
            let overlap = display.frame.intersection(visibleFrame)
            return overlap.isEmpty ? 0 : overlap.width * overlap.height
        }
        return displays.max { area($0) < area($1) }
    }
}

/// Each Codex display owns its position, even if the user drags its tab to another display.
struct ShelfPlacements {
    private static let key = "shelfPlacementsByDisplayV3"
    private(set) var saved: [String: ShelfPlacement]
    private var estimates: [String: ShelfPlacement] = [:]
    private var legacyOffset: NSPoint?

    init(saved: [String: ShelfPlacement]? = nil, legacy: ShelfPlacement? = nil, legacyOffset: NSPoint? = nil) {
        if let saved {
            self.saved = saved.filter { !$0.key.isEmpty && $0.value.isValid }
        } else if let legacy, legacy.isValid {
            self.saved = [legacy.displayID: legacy]
        } else {
            self.saved = [:]
            self.legacyOffset = legacyOffset
        }
    }

    init(defaults: UserDefaults) {
        let decoder = JSONDecoder()
        let saved = defaults.data(forKey: Self.key).flatMap { try? decoder.decode([String: ShelfPlacement].self, from: $0) }
        let legacy = defaults.data(forKey: "shelfPlacementV2").flatMap { try? decoder.decode(ShelfPlacement.self, from: $0) }
        let hasOffset = defaults.object(forKey: "shelfX") != nil || defaults.object(forKey: "shelfY") != nil
        let offset = hasOffset ? NSPoint(x: defaults.double(forKey: "shelfX"), y: defaults.double(forKey: "shelfY")) : nil
        self.init(saved: saved, legacy: legacy, legacyOffset: offset)
        if saved == nil && legacy?.isValid == true { save(to: defaults) }
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(saved) else { return }
        defaults.set(data, forKey: Self.key)
        for key in ["shelfPlacementV2", "shelfX", "shelfY"] { defaults.removeObject(forKey: key) }
    }

    mutating func resolve(host: ShelfDisplay, connected: [ShelfDisplay], anchor: NSRect, count: Int, realAnchor: Bool,
                          slot: String? = nil, window: CGRect? = nil)
        -> (placement: ShelfPlacement, display: ShelfDisplay, didSave: Bool) {
        let key = slot ?? host.id
        if let placement = saved[key], let destination = connected.first(where: { $0.id == placement.displayID }) {
            estimates.removeValue(forKey: key)
            if let window, placement.ownerFrame == nil {
                let attached = placement.attached(to: window)
                saved[key] = attached
                return (attached, destination, true)
            }
            return (placement.following(window, on: host), destination, false)
        }
        // A disconnected destination keeps its saved pin. Anchor the temporary
        // shelf inside its owning window until that monitor is available again.
        let shouldPin = realAnchor && saved[key] == nil
        if !shouldPin, let estimate = estimates[key] {
            return (estimate.following(window, on: host), host, false)
        }
        let ownerRoom = window.map {
            CGRect(x: host.frame.minX + $0.minX, y: host.frame.maxY - $0.maxY, width: $0.width, height: $0.height)
                .intersection(host.visibleFrame)
        }
        let room = ownerRoom.flatMap { $0.isEmpty ? nil : $0 } ?? host.visibleFrame
        let initial = ShelfPlacement.initial(anchor: anchor, visibleFrame: room, displayFrame: host.frame,
            displayID: host.id, count: count, legacyOffset: shouldPin ? legacyOffset : nil)
            .attached(to: window)
        if shouldPin {
            pin(initial, for: key)
        } else {
            estimates[key] = initial
        }
        return (initial, host, shouldPin)
    }

    mutating func pin(_ placement: ShelfPlacement, for hostID: String) {
        saved[hostID] = placement
        estimates.removeValue(forKey: hostID)
        legacyOffset = nil
    }

    mutating func reset(for hostID: String) {
        saved.removeValue(forKey: hostID)
        estimates.removeValue(forKey: hostID)
        legacyOffset = nil
    }

    mutating func discardEstimate(for key: String) { estimates.removeValue(forKey: key) }
}

/// CG window numbers identify a live window. The saved slots survive a Codex restart,
/// when those numbers change. Match free slots using only the window's screen-local frame.
final class WindowShelfPlacements {
    private var positions: ShelfPlacements
    private let defaults: UserDefaults?
    private var slots: [String: [CGWindowID: String]] = [:]
    private var hostPID: pid_t?

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        positions = defaults.map(ShelfPlacements.init(defaults:)) ?? ShelfPlacements()
    }

    private func slot(for id: CGWindowID, on host: ShelfDisplay, window: CGRect) -> String {
        if let existing = slots[host.id]?[id] { return existing }
        let used = Set(slots[host.id, default: [:]].values)
        let prefix = host.id + "/window/"
        let available = positions.saved.keys.filter {
            !used.contains($0) && ($0 == host.id || $0.hasPrefix(prefix))
        }
        func distance(_ key: String) -> CGFloat {
            guard let previous = positions.saved[key]?.ownerFrame else { return 0 }
            return hypot(previous.midX - window.midX, previous.midY - window.midY)
        }
        var key = host.id
        if let match = available.min(by: { (distance($0), $0) < (distance($1), $1) }) {
            key = match
        } else {
            var index = 1
            while used.contains(key) {
                key = prefix + String(index)
                index += 1
            }
        }
        slots[host.id, default: [:]][id] = key
        return key
    }

    /// Screen-local coordinates keep pins stable when displays change arrangement.
    private func local(_ window: CGRect, on host: ShelfDisplay) -> CGRect {
        CGRect(x: window.minX - host.frame.minX, y: host.frame.maxY - window.maxY,
               width: window.width, height: window.height)
    }

    func resolve(id: CGWindowID, window: CGRect, host: ShelfDisplay, connected: [ShelfDisplay],
                 anchor: CGRect, count: Int, realAnchor: Bool) -> (placement: ShelfPlacement, display: ShelfDisplay) {
        let owner = local(window, on: host)
        let key = slot(for: id, on: host, window: owner)
        let result = positions.resolve(host: host, connected: connected, anchor: anchor, count: count,
                                       realAnchor: realAnchor, slot: key, window: owner)
        if result.didSave, let defaults { positions.save(to: defaults) }
        return (result.placement, result.display)
    }

    func pin(_ placement: ShelfPlacement, id: CGWindowID, window: CGRect, host: ShelfDisplay) {
        let owner = local(window, on: host)
        let key = slot(for: id, on: host, window: owner)
        positions.pin(placement.attached(to: owner), for: key)
        if let defaults { positions.save(to: defaults) }
    }

    func reset(_ id: CGWindowID, on host: ShelfDisplay) {
        guard let key = slots[host.id]?[id] else { return }
        positions.reset(for: key)
        if let defaults { positions.save(to: defaults) }
    }

    // A minimized, covered or off-Space window still owns its placement.
    func retain(liveWindowIDs: Set<CGWindowID>, process: pid_t) {
        let restarted = hostPID.map { $0 != process } ?? false
        hostPID = process
        for (display, reservations) in slots {
            for (id, key) in reservations where restarted || !liveWindowIDs.contains(id) {
                slots[display]?.removeValue(forKey: id)
                positions.discardEstimate(for: key)
            }
            if slots[display]?.isEmpty == true { slots.removeValue(forKey: display) }
        }
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
    private var left: CGFloat
    private var fromTop: CGFloat
    fileprivate private(set) var ownerFrame: CGRect?
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

    fileprivate func attached(to frame: CGRect?) -> Self {
        var result = self
        result.ownerFrame = frame
        return result
    }

    fileprivate func following(_ frame: CGRect?, on host: ShelfDisplay) -> Self {
        guard let frame, let previous = ownerFrame, host.id == displayID else { return self }
        var result = self
        result.left += frame.minX - previous.minX
        result.fromTop += frame.minY - previous.minY
        if previous.contains(CGPoint(x: left, y: fromTop)) {
            // When the window becomes narrower, an in-window pin stays with its owner.
            result.left = min(result.left, frame.maxX - 1)
            result.fromTop = min(result.fromTop, frame.maxY - 1)
        }
        result.ownerFrame = frame
        return result
    }

    func layoutDisplay(_ destination: ShelfDisplay, host: ShelfDisplay?, window: CGRect) -> ShelfDisplay {
        guard destination.id == host?.id, window.contains(grip(in: destination.frame)) else { return destination }
        let room = window.intersection(destination.visibleFrame)
        guard room.width >= 90, room.height >= Self.laneHeight + 8 else { return destination }
        return ShelfDisplay(id: destination.id, frame: destination.frame, visibleFrame: room)
    }

    /// Constrain layout to an exposed part of the owner. Keep the original pin so
    /// uncovering the window restores the location the user chose.
    func visibleRoom(on display: ShelfDisplay, host: ShelfDisplay?, window: CGRect, count: Int,
                     saveWidth: CGFloat, avoiding shelves: [CGRect], occludedBy windows: [CGRect]) -> CGRect? {
        let preferred = layoutDisplay(display, host: host, window: window).visibleFrame
        let original = layout(displayFrame: display.frame, visibleFrame: preferred,
                              count: count, emptySaveWidth: saveWidth).frame
        let obstacles = windows + shelves.map { $0.insetBy(dx: -2, dy: -2) }
        guard obstacles.contains(where: { !$0.intersection(original).isEmpty }) else { return preferred }

        let available = display.id == host?.id ? window.intersection(display.visibleFrame) : display.visibleFrame
        let minWidth = GlassTabDrawing.controlSize.width + 4 + saveWidth + 8
        let minHeight = Self.laneHeight + 8
        var regions = [available]
        for obstacle in obstacles {
            var next: [CGRect] = []
            func keep(_ candidate: CGRect) {
                guard candidate.width >= minWidth, candidate.height >= minHeight,
                      !next.contains(where: { $0.contains(candidate) }) else { return }
                next.removeAll { candidate.contains($0) }
                next.append(candidate)
            }
            for region in regions {
                let cut = region.intersection(obstacle)
                if cut.isEmpty { keep(region); continue }
                // Keep the full span on each side. A narrow, full-height strip can
                // still hold a vertical shelf even when the row cannot fit.
                keep(CGRect(x: region.minX, y: region.minY, width: cut.minX - region.minX, height: region.height))
                keep(CGRect(x: cut.maxX, y: region.minY, width: region.maxX - cut.maxX, height: region.height))
                keep(CGRect(x: region.minX, y: region.minY, width: region.width, height: cut.minY - region.minY))
                keep(CGRect(x: region.minX, y: cut.maxY, width: region.width, height: region.maxY - cut.maxY))
            }
            regions = next
            if regions.isEmpty { return nil }
        }

        var nearest: CGRect?
        var bestDistance = CGFloat.infinity
        for region in regions {
            let candidate = layout(displayFrame: display.frame, visibleFrame: region,
                                   count: count, emptySaveWidth: saveWidth)
            guard candidate.save.width >= saveWidth,
                  count == 0 || candidate.list.height >= Self.laneHeight else { continue }
            let distance = hypot(candidate.frame.midX - original.midX, candidate.frame.midY - original.midY)
            if distance < bestDistance {
                bestDistance = distance
                nearest = region
            }
        }
        return nearest
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
        var grip = NSRect(x: x, y: top - gripHeight, width: gripWidth, height: gripHeight)
        let preferredWidth = laneWidth ?? 279
        let gap = min(4, max(0, room.width - gripWidth))
        let saveWidth = min(SaveButtonDrawing.reservedWidth, max(0, room.width - gripWidth - gap))
        let laneHeight = min(Self.laneHeight, room.height)
        let bottom = min(max(grip.midY - laneHeight / 2, room.minY), room.maxY - laneHeight)
        let above = room.maxY - (bottom + laneHeight), below = bottom - room.minY
        let rowWidth = gripWidth + saveWidth + 90 + 2 * gap
        var right = room.maxX - grip.minX, left = grip.maxX - room.minX
        // An exposed strip can have room for a row but nowhere to stack the
        // bubbles. Shift the rendered grip only far enough to make a row fit.
        if count > 0, max(above, below) < Self.laneHeight,
           max(right, left) < rowWidth, min(preferredWidth, room.width) >= rowWidth {
            grip.origin.x = right >= left ? room.maxX - rowWidth : room.minX + rowWidth - gripWidth
            right = room.maxX - grip.minX
            left = grip.maxX - room.minX
        }
        let preferRight = right >= preferredWidth || right >= left
        let span = min(preferredWidth, max(right, left))
        let area: NSRect, save: NSRect, list: NSRect
        let isRow = span >= rowWidth
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
            let fitsBesideGrip = max(right, left) >= gripWidth + gap + saveWidth
            let goesUp = below < min((fitsBesideGrip ? 2 : 3) * laneHeight, above)
            let space = goesUp ? above : below
            // Keep the tab pinned and put Save on its own row when neither side
            // of the tab has room. In a short strip, shift the tab just enough
            // to share the control row and keep one row available for bubbles.
            let extraRow = !fitsBesideGrip && space >= 2 * laneHeight ? laneHeight : 0
            if !fitsBesideGrip && extraRow == 0 {
                grip.origin.x = preferRight ? room.maxX - saveWidth - gap - gripWidth : room.minX + saveWidth + gap
            }
            let sx = preferRight ? min(grip.maxX + gap, room.maxX - saveWidth) : max(room.minX, grip.minX - gap - saveWidth)
            save = NSRect(x: sx, y: bottom + (goesUp ? extraRow : -extraRow), width: saveWidth, height: laneHeight)
            let listHeight = min(2 * laneHeight, space - extraRow)
            list = NSRect(x: originX, y: goesUp ? save.maxY : save.minY - listHeight, width: width, height: listHeight)
            area = list.union(save)
        }
        let frame = area.union(grip).union(save)
        func local(_ rect: NSRect) -> NSRect { rect.offsetBy(dx: -frame.minX, dy: -frame.minY) }
        return ShelfLayout(frame: frame, header: local(grip), save: local(save),
                           list: count == 0 ? .zero : local(list), horizontal: isRow)
    }
}
