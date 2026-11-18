import AppKit

@main @MainActor
enum EmptyShelfChecks {
    static func main() {
        DisplayPlacementChecks.run()
        WindowPlacementChecks.run()
        WindowInventoryChecks.run()
        let displays = [
            NSRect(x: 0, y: 0, width: 1440, height: 900),
            NSRect(x: -1440, y: 50, width: 1440, height: 900),
            NSRect(x: 20, y: 30, width: 168, height: 400)
        ]
        var cases = 0
        for display in displays {
            let room = display.insetBy(dx: 4, dy: 4)
            for x in [room.minX, room.midX - 10, room.maxX - 21] {
                for y in [room.minY + 30, room.midY, room.maxY] {
                    for preferredWidth: CGFloat? in [nil, 325] {
                        let pin = NSPoint(x: x, y: y)
                        let placement = ShelfPlacement(displayID: "synthetic", grip: pin, displayFrame: display,
                                                      horizontal: true, widthLimit: 325, laneWidth: preferredWidth)
                        func layout(_ count: Int, width: CGFloat) -> ShelfLayout {
                            placement.layout(displayFrame: display, visibleFrame: display, count: count, emptySaveWidth: width)
                        }
                        let full = layout(3, width: SaveButtonDrawing.reservedWidth)
                        for style in BubbleStyle.allCases {
                            for saveStyle in SaveButtonStyle.allCases {
                                let width = SaveButtonDrawing.size(for: saveStyle, bubbleStyle: style).width
                                let empty = layout(0, width: width)
                                let fitsRight = room.maxX - x >= (preferredWidth ?? 279)
                                let toRight = fitsRight || room.maxX - x >= x + empty.header.width - room.minX
                                let space = toRight ? room.maxX - x - empty.header.width : x - room.minX
                                let gap = toRight ? empty.save.minX - empty.header.maxX : empty.header.minX - empty.save.maxX
                                precondition(gap == 4 && empty.list == .zero)
                                precondition(empty.save.width == min(width, space - gap))
                                precondition(empty.frame.width == empty.header.width + empty.save.width + gap)
                                precondition(room.contains(empty.frame) && !empty.header.intersects(empty.save))
                                precondition(empty.frame.minX + empty.header.minX == pin.x)
                                precondition(empty.frame.minY + empty.header.maxY == pin.y)
                                precondition(full.frame.minX + full.header.minX == pin.x)
                                precondition(full.frame.minY + full.header.maxY == pin.y)
                                precondition(full == layout(1, width: width) && full == layout(200, width: width))
                                precondition(full.save.width == SaveButtonDrawing.reservedWidth && !full.list.isEmpty)
                                if full.horizontal {
                                    precondition(full.frame.width == (preferredWidth ?? 279))
                                }
                                cases += 1
                            }
                        }
                    }
                }
            }
        }
        print("Passed \(cases) compact shelf layout cases across styles, screen edges and saved placements.")
    }
}
