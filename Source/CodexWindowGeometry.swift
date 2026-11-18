import CoreGraphics
import Foundation

typealias ShelfWindowID = CGWindowID

/// WindowServer returns windows front to back. It includes windows covered by other
/// windows, so visibility on a Space alone is insufficient for a floating control.
struct CodexWindowGeometry {
    let id: ShelfWindowID
    let frame: CGRect
    let exposed: Bool
    let occludingQuartzFrames: [CGRect]

    init(id: ShelfWindowID, frame: CGRect, exposed: Bool, occludingQuartzFrames: [CGRect] = []) {
        self.id = id
        self.frame = frame
        self.exposed = exposed
        self.occludingQuartzFrames = occludingQuartzFrames
    }

    static func inventory(_ rows: [[String: Any]], pid: pid_t) -> [Self] {
        var covers: [CGRect] = []
        var result: [Self] = []
        for row in rows {
            guard row[kCGWindowIsOnscreen as String] as? Bool == true, row[kCGWindowLayer as String] as? Int == 0,
                  (row[kCGWindowAlpha as String] as? CGFloat ?? 1) > 0,
                  let bounds = row[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds), !frame.isEmpty else { continue }
            if row[kCGWindowOwnerPID as String] as? pid_t == pid,
               frame.width > 250, frame.height > 160, let id = row[kCGWindowNumber as String] as? ShelfWindowID {
                let blockers = covers.filter { !$0.intersection(frame).isEmpty }
                result.append(Self(id: id, frame: frame, exposed: isExposed(frame, behind: blockers),
                                   occludingQuartzFrames: blockers))
            }
            if (row[kCGWindowAlpha as String] as? CGFloat ?? 1) >= 0.99 { covers.append(frame) }
        }
        return result
    }

    static func isExposed(_ frame: CGRect, behind covers: [CGRect]) -> Bool {
        var pieces = [frame]
        for cover in covers where cover.intersects(frame) {
            pieces = pieces.flatMap { piece -> [CGRect] in
                let cut = piece.intersection(cover)
                if cut.isEmpty { return [piece] }
                return [
                    CGRect(x: piece.minX, y: piece.minY, width: piece.width, height: cut.minY - piece.minY),
                    CGRect(x: piece.minX, y: cut.maxY, width: piece.width, height: piece.maxY - cut.maxY),
                    CGRect(x: piece.minX, y: cut.minY, width: cut.minX - piece.minX, height: cut.height),
                    CGRect(x: cut.maxX, y: cut.minY, width: piece.maxX - cut.maxX, height: cut.height)
                ].filter { $0.width >= 1 && $0.height >= 1 }
            }
            if pieces.isEmpty { return false }
        }
        return true
    }

    /// A public AX handle has no guaranteed WindowServer number. Reuse a witnessed
    /// pairing, then the focused/topmost pair, then unique frame matches. Never
    /// infer ownership of indistinguishable windows from AXWindows enumeration order.
    static func match(_ windows: [Self], axFrames: [CGRect], focused: Int?,
                      previous: [ShelfWindowID: Int]) -> [ShelfWindowID: Int] {
        var matched: [ShelfWindowID: Int] = [:]
        var used = Set<Int>()
        func fits(_ row: Self, _ i: Int) -> Bool {
            let a = row.frame, b = axFrames[i]
            return abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2 &&
                   abs(a.maxX - b.maxX) <= 2 && abs(a.maxY - b.maxY) <= 2
        }
        if let first = windows.first, let focused, fits(first, focused) {
            matched[first.id] = focused
            used.insert(focused)
        }
        for row in windows where matched[row.id] == nil {
            if let i = previous[row.id], !used.contains(i), fits(row, i) {
                matched[row.id] = i
                used.insert(i)
            }
        }
        for row in windows where matched[row.id] == nil {
            let choices = axFrames.indices.filter { !used.contains($0) && fits(row, $0) }
            guard choices.count == 1, let i = choices.first,
                  !windows.contains(where: { $0.id != row.id && matched[$0.id] == nil && fits($0, i) }) else { continue }
            matched[row.id] = i
            used.insert(i)
        }
        return matched
    }
}
