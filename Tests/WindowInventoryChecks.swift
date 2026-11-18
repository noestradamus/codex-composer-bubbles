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

        // The website chat exposes two stacked, equally sized AX system dialogs.
        // They still cover part of the chat, while each real chat keeps its shelf.
        let websiteChat = CGRect(x: 0, y: 0, width: 1470, height: 923)
        let popup = CGRect(x: 1176, y: 614, width: 332, height: 246)
        let website = CodexWindowGeometry.inventory([row(17, popup), row(18, popup), row(1, websiteChat), row(2, second)], pid: pid)
        let axFrames = [second, websiteChat, popup, popup]
        let roles = ["AXStandardWindow", "AXStandardWindow", "AXSystemDialog", "AXSystemDialog"]
        func trustedShelves(_ windows: [CodexWindowGeometry], _ frames: [CGRect], focused: Int) -> [ShelfWindowID] {
            let pairs = CodexWindowGeometry.match(windows, axFrames: frames, focused: focused, previous: [:])
            return windows.filter { row in
                let pair = pairs[row.id]
                return row.isEligible(trusted: true, paired: pair != nil, subrole: pair.map { roles[$0] })
            }.map(\.id)
        }
        precondition(trustedShelves(website, axFrames, focused: 1) == [1, 2]) // ambiguous dialogs
        precondition(trustedShelves(website, axFrames, focused: 2) == [1, 2]) // focused dialog pairs explicitly
        let singleDialog = CodexWindowGeometry.inventory([row(17, popup), row(1, websiteChat), row(2, second)], pid: pid)
        precondition(trustedShelves(singleDialog, Array(axFrames.prefix(3)), focused: 1) == [1, 2])
        precondition(!website[1].exposed && website[2].occludingQuartzFrames.contains(popup))
        precondition(website.filter { $0.isEligible(trusted: false, paired: false) }.map(\.id) == [17, 1, 2])

        let chat = website[2]
        precondition(chat.isEligible(trusted: true, paired: false, missingPairAge: 0.6))
        let duringMove = CodexWindowGeometry.match(website, axFrames: [second, websiteChat.offsetBy(dx: 154, dy: 0), popup, popup],
                                                   focused: 1, previous: [1: 1, 2: 0])
        precondition(duringMove[1] == nil && !duringMove.values.contains(1))
        precondition(chat.isEligible(trusted: true, paired: false, missingPairAge: 0.6,
                                     previousHandleClaimed: duringMove.values.contains(1)))
        precondition(!chat.isEligible(trusted: true, paired: false, missingPairAge: 0.6, previousHandleClaimed: true))
        precondition(!chat.isEligible(trusted: true, paired: false, missingPairAge: 3))
        precondition(!chat.isEligible(trusted: true, paired: false)) // actions never inherit the passive display grace
        precondition(!stacked[1].isEligible(trusted: true, paired: true))
        print("Passed simultaneous-window enumeration, visibility, frame matching and ambiguous ownership.")
    }
}
