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
        positions.release(202)
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
        print("Passed simultaneous shelf placement, independent pins, move/resize, relaunch and collision checks.")
    }
}
