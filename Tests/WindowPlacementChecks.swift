import AppKit

enum WindowPlacementChecks {
    static func run() {
        let screen = ShelfDisplay(id: "left", frame: CGRect(x: -1600, y: 0, width: 1600, height: 1000),
                                  visibleFrame: CGRect(x: -1600, y: 0, width: 1600, height: 976))
        let other = ShelfDisplay(id: "right", frame: CGRect(x: 0, y: -200, width: 1800, height: 1050),
                                 visibleFrame: CGRect(x: 0, y: -200, width: 1800, height: 1019))
        let screens = [screen, other]
        let left = CGRect(x: -1500, y: 100, width: 580, height: 720)
        let right = left.offsetBy(dx: 800, dy: -80)
        let suite = "ComposerBubbles.WindowTest." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        func pinned(_ x: CGFloat, _ y: CGFloat, _ display: ShelfDisplay = screen) -> ShelfPlacement {
            ShelfPlacement(displayID: display.id, grip: CGPoint(x: x, y: y), displayFrame: display.frame,
                           horizontal: true, widthLimit: 325, laneWidth: 325)
        }
        let legacy = pinned(-1460, 350)
        defaults.set(try! JSONEncoder().encode([screen.id: legacy]), forKey: "shelfPlacementsByDisplayV3")
        var positions = WindowShelfPlacements(defaults: defaults)
        func resolve(_ id: CGWindowID, _ window: CGRect, on host: ShelfDisplay = screen) -> ShelfPlacement {
            let anchor = CGRect(x: window.midX - 160, y: window.minY + 28, width: 320, height: 60)
            return positions.resolve(id: id, window: window, host: host, connected: screens,
                                     anchor: anchor, count: 1, realAnchor: true).placement
        }
        func grip(_ id: CGWindowID, _ window: CGRect) -> CGPoint {
            resolve(id, window).grip(in: screen.frame)
        }
        precondition(grip(1, left) == legacy.grip(in: screen.frame))
        let rightDefault = grip(2, right)
        precondition(right.contains(rightDefault))
        let leftPin = pinned(-1310, 400), rightPin = pinned(-490, 290)
        positions.pin(leftPin, id: 1, window: left, host: screen)
        positions.pin(rightPin, id: 2, window: right, host: screen)
        for _ in 0..<3 {
            precondition(grip(2, right) == rightPin.grip(in: screen.frame))
            precondition(grip(1, left) == leftPin.grip(in: screen.frame))
        }
        let moved = left.offsetBy(dx: 140, dy: -90)
        precondition(grip(1, moved) == CGPoint(x: -1170, y: 310))
        precondition(grip(2, right) == rightPin.grip(in: screen.frame))
        let narrow = CGRect(x: left.minX, y: left.minY, width: 165, height: left.height)
        let narrowPin = resolve(1, narrow)
        let narrowRoom = narrowPin.layoutDisplay(screen, host: screen, window: narrow).visibleFrame
        precondition(narrow.contains(narrowPin.layout(displayFrame: screen.frame, visibleFrame: narrowRoom, count: 5).frame))
        // A deliberate drag to another monitor stays there when the owning window moves.
        let cross = pinned(150, 460, other)
        positions.pin(cross, id: 1, window: left, host: screen)
        precondition(resolve(1, moved).grip(in: other.frame) == cross.grip(in: other.frame))
        positions.pin(leftPin, id: 1, window: left, host: screen)

        // Codex can assign new window IDs after relaunch and enumerate windows in a different order.
        positions = WindowShelfPlacements(defaults: defaults)
        precondition(grip(202, right) == rightPin.grip(in: screen.frame))
        precondition(grip(101, left) == leftPin.grip(in: screen.frame))
        positions.retain(liveWindowIDs: [101], process: 42)
        precondition(grip(303, right) == rightPin.grip(in: screen.frame))

        positions.reset(101, on: screen)
        precondition(grip(303, right) == rightPin.grip(in: screen.frame))
        precondition(grip(101, left) != leftPin.grip(in: screen.frame))

        func shelf(_ windows: [CGRect], avoiding neighbors: [CGRect] = []) -> CGRect? {
            rightPin.visibleRoom(on: screen, host: screen, window: right, count: 1,
                                 saveWidth: SaveButtonDrawing.reservedWidth, avoiding: neighbors, occludedBy: windows)
                .map { rightPin.layout(displayFrame: screen.frame, visibleFrame: $0, count: 1).frame }
        }
        let base = shelf([])!
        let shifted = shelf([], avoiding: [base])!
        precondition(!base.intersects(shifted) && right.contains(shifted))
        let hiddenLeft = CGRect(x: right.minX, y: right.minY, width: right.width - 130, height: right.height)
        let strip = shelf([hiddenLeft])!
        precondition(right.contains(strip) && !hiddenLeft.intersects(strip) && strip.height > base.height)
        precondition(shelf([right]) == nil)
        let thinEdge = CGRect(x: right.minX, y: right.minY, width: right.width - 15, height: right.height)
        precondition(shelf([thinEdge]) == nil)
        precondition(shelf([]) == base)
        precondition(grip(303, right) == rightPin.grip(in: screen.frame))

        // WindowServer numbers may be recycled when Codex restarts.
        let afterReset = grip(101, left)
        positions.retain(liveWindowIDs: [101, 303], process: 43)
        precondition(grip(101, right) == rightPin.grip(in: screen.frame))
        precondition(grip(303, left) == afterReset)

        // Covering or minimizing the first window frees the UI, but preserves
        // its reservation when a second live window has the exact same frame.
        positions = WindowShelfPlacements()
        let full = screen.visibleFrame
        positions.pin(leftPin, id: 10, window: full, host: screen)
        positions.retain(liveWindowIDs: [10, 20], process: 42)
        precondition(grip(20, full) != leftPin.grip(in: screen.frame))
        let otherPin = pinned(-1070, 250)
        positions.pin(otherPin, id: 20, window: full, host: screen)
        positions.retain(liveWindowIDs: [10, 20], process: 42)
        precondition(grip(10, full) == leftPin.grip(in: screen.frame))
        precondition(grip(20, full) == otherPin.grip(in: screen.frame))
        positions.retain(liveWindowIDs: [10], process: 42) // 20 closed; a new window can reuse its free slot.
        precondition(grip(30, full) == otherPin.grip(in: screen.frame))

        // Save and the tab remain separate hit targets in tall and short exposed strips.
        for height: CGFloat in [96, 800] {
            let column = CGRect(x: 0, y: 0, width: 120, height: height)
            for x: CGFloat in [45, 51, 61] {
                let tab = CGPoint(x: x, y: height == 96 ? 90 : 330)
                let owner = CGRect(x: 0, y: 0, width: 900, height: height)
                let display = ShelfDisplay(id: "strip", frame: owner, visibleFrame: owner)
                let covered = CGRect(x: column.maxX, y: 0, width: owner.width-column.width, height: height)
                let placement = ShelfPlacement(displayID: display.id, grip: tab, displayFrame: owner, horizontal: true, widthLimit: 325)
                let room = placement.visibleRoom(on: display, host: display, window: owner, count: 3,
                                                 saveWidth: SaveButtonDrawing.reservedWidth, avoiding: [], occludedBy: [covered])!
                let layout = placement.layout(displayFrame: owner, visibleFrame: room, count: 3)
                precondition(column.contains(layout.frame) && layout.save.width == SaveButtonDrawing.reservedWidth)
                precondition(!layout.header.intersects(layout.save) && !layout.list.intersects(layout.save))
                precondition(!layout.header.intersects(layout.list) && layout.list.height >= BubbleGlass.rowHeight)
                if height == 800 { precondition(layout.frame.minX + layout.header.minX == x) }
            }
        }
        // Two overlapping windows leave a short strip. Fit a complete row
        // there even if the pin is too centered to fit the row on either side.
        let owner = CGRect(x: -1500, y: 100, width: 690, height: 610)
        let exposed = CGRect(x: owner.minX, y: owner.minY, width: 320, height: 60)
        let upper = CGRect(x: owner.minX - 65, y: exposed.maxY, width: 950, height: 690)
        let lowerRight = CGRect(x: exposed.maxX, y: owner.minY - 70, width: 920, height: 500)
        let centered = pinned(exposed.midX - 10, exposed.midY + 10)
        let exposedRoom = centered.visibleRoom(on: screen, host: screen, window: owner, count: 1,
                                               saveWidth: SaveButtonDrawing.reservedWidth,
                                               avoiding: [], occludedBy: [upper, lowerRight])!
        let fitted = centered.layout(displayFrame: screen.frame, visibleFrame: exposedRoom, count: 1)
        precondition(fitted.horizontal && exposed.contains(fitted.frame))
        precondition(fitted.save.width == SaveButtonDrawing.reservedWidth && fitted.list.height == BubbleGlass.rowHeight)
        let free = centered.layoutDisplay(screen, host: screen, window: owner).visibleFrame
        let restored = centered.layout(displayFrame: screen.frame, visibleFrame: free, count: 1)
        precondition(restored.frame.minX + restored.header.minX == exposed.midX - 10)
        checkVertical(on: screen, owner: owner, covering: [upper, lowerRight])
        checkDisconnect()
        print("Passed simultaneous shelf placement, independent pins, move/resize, relaunch and collision checks.")
    }

    private static func checkVertical(on screen: ShelfDisplay, owner: CGRect, covering: [CGRect]) {
        let room = screen.visibleFrame
        let saveWidth: CGFloat = 76
        let cell = BubbleGlass.portraitCell(for: .shortCaptions)
        for x in [room.minX + 4, room.midX, room.maxX - 25] {
            for y in [room.minY + 34, room.midY, room.maxY - 4] {
                let pin = CGPoint(x: x, y: y)
                let placement = ShelfPlacement(displayID: screen.id, grip: pin, displayFrame: screen.frame,
                                               horizontal: true, widthLimit: 325, laneWidth: 325)
                var savedPosition: CGRect?
                for count in [0, 1, 3, 12, 1_000] {
                    let layout = placement.layout(displayFrame: screen.frame, visibleFrame: room,
                                                  count: count, emptySaveWidth: saveWidth, portraitCell: cell)
                    precondition(layout.controlOrientation == .vertical && !layout.horizontal && room.contains(layout.frame))
                    precondition(layout.header.intersection(layout.save).isEmpty && layout.save.intersection(layout.list).isEmpty)
                    precondition(layout.frame.minX + layout.header.minX == pin.x)
                    precondition(layout.frame.minY + layout.header.maxY == pin.y)
                    precondition(layout.save.size == cell && layout.frame.width == cell.width)
                    if count > 0 {
                        precondition(layout.list.width == cell.width && layout.list.minX == layout.save.minX)
                        precondition(layout.list.height >= cell.height && layout.list.height <= CGFloat(min(count, 5)) * cell.height)
                        let gap = max(layout.list.minY - layout.save.maxY, layout.save.minY - layout.list.maxY)
                        precondition(gap == 5)
                    } else {
                        precondition(layout.list.isEmpty && layout.frame.height == cell.height + GlassTabDrawing.controlSize.height + 2)
                    }
                    let save = layout.save.offsetBy(dx: layout.frame.minX, dy: layout.frame.minY)
                    if let savedPosition { precondition(save == savedPosition) }
                    savedPosition = save
                }
            }
        }

        // A low exposed strip still has a usable row when a column physically cannot fit.
        let pin = CGPoint(x: owner.minX + 150, y: owner.minY + 40)
        let placement = ShelfPlacement(displayID: screen.id, grip: pin, displayFrame: screen.frame,
                                       horizontal: true, widthLimit: 325, laneWidth: 325)
        let exposed = placement.visibleRoom(on: screen, host: screen, window: owner, count: 8,
                                            saveWidth: saveWidth, portraitCell: cell, avoiding: [], occludedBy: covering)!
        let fallback = placement.layout(displayFrame: screen.frame, visibleFrame: exposed, count: 8, portraitCell: cell)
        precondition(fallback.horizontal && fallback.controlOrientation == .horizontal && covering.allSatisfy { !$0.intersects(fallback.frame) })
        let safe = placement.visibleRoom(on: screen, host: screen, window: owner, count: 8,
                                          saveWidth: saveWidth, portraitCell: cell, avoiding: [], occludedBy: [])!
        let column = placement.layout(displayFrame: screen.frame, visibleFrame: safe, count: 8, portraitCell: cell)
        precondition(!column.horizontal && owner.contains(column.frame))
        precondition(column.frame.minX + column.header.minX == pin.x)
        print("Passed vertical fit, Save placement, stable pins and low-strip fallback.")
    }

    private static func checkDisconnect() {
        let screen = ShelfDisplay(id: "laptop", frame: CGRect(x: 0, y: 0, width: 1470, height: 956),
                                  visibleFrame: CGRect(x: 0, y: 0, width: 1470, height: 923))
        let desktop = CGRect(x: 1470, y: 0, width: 1920, height: 1080)
        let monitor = ShelfDisplay(id: "external", frame: desktop, visibleFrame: desktop)
        let left = CGRect(x: 0, y: 0, width: 735, height: 923), right = left.offsetBy(dx: 735, dy: 0)
        let pin = ShelfPlacement(displayID: monitor.id, grip: CGPoint(x: desktop.minX + 1280, y: 300),
                                 displayFrame: desktop, horizontal: true, widthLimit: 325, laneWidth: 325)
        let positions = WindowShelfPlacements()
        positions.pin(pin, id: 1, window: left, host: screen)
        func resolve(_ id: CGWindowID, _ owner: CGRect, _ screens: [ShelfDisplay], editorShift: CGFloat = 0) -> ShelfPlacement {
            let editor = CGRect(x: owner.midX - 150, y: 30 + editorShift, width: 300, height: 60)
            return positions.resolve(id: id, window: owner, host: screen, connected: screens, anchor: editor,
                                     count: 1, realAnchor: true).placement
        }
        var occupied: [CGRect] = []
        for (id, owner) in [(CGWindowID(1), left), (CGWindowID(2), right)] {
            let p = resolve(id, owner, [screen])
            let room = p.visibleRoom(on: screen, host: screen, window: owner, count: 1,
                                     saveWidth: SaveButtonDrawing.reservedWidth, avoiding: occupied, occludedBy: [])!
            let frame = p.layout(displayFrame: screen.frame, visibleFrame: room, count: 1).frame
            precondition(p.displayID == screen.id && owner.contains(frame))
            precondition(p == resolve(id, owner, [screen], editorShift: 35))
            occupied.append(frame)
        }
        precondition(!occupied[0].intersects(occupied[1]))
        let restored = resolve(1, left, [screen, monitor])
        precondition(restored.displayID == monitor.id && restored.grip(in: desktop) == pin.grip(in: desktop))
    }
}
