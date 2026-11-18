import CoreGraphics
import Foundation

enum WindowInventoryChecks {
    static func run() {
        let first = CGRect(x: 0, y: 0, width: 900, height: 600)
        let second = first.offsetBy(dx: -1200, dy: -90)
        let pid: pid_t = 100
        func row(_ id: Int, _ frame: CGRect, owner: pid_t = 100, onscreen: Bool = true,
                 layer: Int = 0, alpha: CGFloat = 1) -> [String: Any] {
            [kCGWindowNumber as String: NSNumber(value: id), kCGWindowBounds as String: frame.dictionaryRepresentation,
             kCGWindowOwnerPID as String: NSNumber(value: owner), kCGWindowLayer as String: layer,
             kCGWindowAlpha as String: alpha, kCGWindowIsOnscreen as String: onscreen]
        }

        // Other Spaces and minimized windows have no on-screen surface. Neither a
        // translucent utility window nor the companion's floating shelf hides a Codex window.
        let front = [row(8, first, owner: 200, alpha: 0.3), row(9, second, owner: 201, layer: 3),
                     row(4, first, onscreen: false), row(5, first, alpha: 0), row(6, .init(x: 0, y: 0, width: 32, height: 32))]
        let visible = CodexWindowGeometry.inventory(front + [row(1, first), row(2, second)], pid: pid)
        precondition(visible.filter(\.exposed).map(\.id) == [1, 2])
        precondition(CodexWindowGeometry.match(visible, axFrames: [second, first], focused: 1, previous: [:]) == [1: 1, 2: 0])

        let covered = CodexWindowGeometry.inventory([row(3, first, owner: 200), row(1, first), row(2, second)], pid: pid)
        precondition(covered.filter(\.exposed).map(\.id) == [2])
        let half = CGRect(x: 0, y: 0, width: first.width / 2, height: first.height)
        let partly = CodexWindowGeometry.inventory([row(99, first, owner: 202, layer: 3), row(77, half, owner: 220),
                                                   row(1, first), row(2, second), row(3, first, owner: 300)], pid: pid)
        precondition(partly.filter(\.exposed).map(\.id) == [1, 2])
        precondition(partly[0].occludingQuartzFrames == [half] && partly[1].occludingQuartzFrames.isEmpty)
        precondition(CodexWindowGeometry.isExposed(first, behind: [half]))
        precondition(!CodexWindowGeometry.isExposed(first, behind: [half, half.offsetBy(dx: half.width, dy: 0)]))

        let stacked = CodexWindowGeometry.inventory([row(1, first), row(2, first)], pid: pid)
        precondition(stacked.filter(\.exposed).map(\.id) == [1])
        precondition(CodexWindowGeometry.match(stacked, axFrames: [first, first], focused: nil, previous: [:]).isEmpty)
        precondition(CodexWindowGeometry.match(stacked, axFrames: [first], focused: nil, previous: [:]).isEmpty)
        precondition(CodexWindowGeometry.match(stacked, axFrames: [first, first], focused: 1, previous: [1: 0, 2: 1])
                     == [1: 1, 2: 0])
        precondition(CodexWindowGeometry.match(visible, axFrames: [first, first], focused: nil, previous: [2: 1]).isEmpty)
        print("Passed simultaneous-window enumeration, visibility, frame matching and ambiguous ownership.")
    }
}
