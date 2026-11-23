import AppKit

@MainActor
enum SaveButtonDrawing {
    nonisolated static let reservedWidth: CGFloat = 76
    // Ultramarine sampled from the bookmark ribbon in Resources/AppIcon.png.
    private static let ribbonBlue = NSColor(srgbRed: 35.0 / 255, green: 83.0 / 255, blue: 250.0 / 255, alpha: 1)
    static let confirmationHoldUntil: TimeInterval = 0.68
    static let confirmationDuration: TimeInterval = 1.05

    static func confirmation(at elapsed: TimeInterval, startingFrom initial: CGFloat, reduceMotion: Bool) -> CGFloat {
        if reduceMotion { return elapsed < confirmationHoldUntil ? 1 : 0 }
        func smoothstep(_ fraction: Double) -> CGFloat {
            let t = CGFloat(min(1, max(0, fraction)))
            return t * t * (3 - 2 * t)
        }
        if elapsed < 0.14 { return initial + (1 - initial) * smoothstep(elapsed / 0.14) }
        return 1 - smoothstep((elapsed - confirmationHoldUntil) / (confirmationDuration - confirmationHoldUntil))
    }

    static func size(for style: SaveButtonStyle, bubbleStyle: BubbleStyle = .shortCaptions,
                     orientation: ShelfOrientation = .horizontal) -> NSSize {
        if orientation == .vertical { return BubbleGlass.portraitCell(for: bubbleStyle) }
        let cell = BubbleGlass.cellSize(for: bubbleStyle, caption: "Save", number: 1)
        if bubbleStyle == .shortCaptions && style == .bookmarkAndText {
            return NSSize(width: reservedWidth, height: cell.height)
        }
        return cell
    }

    static func surfaceRect(in bounds: NSRect, style: SaveButtonStyle, bubbleStyle: BubbleStyle = .shortCaptions,
                            orientation: ShelfOrientation = .horizontal) -> NSRect {
        let size = size(for: style, bubbleStyle: bubbleStyle, orientation: orientation)
        let width = min(bounds.width, size.width), height = min(bounds.height, size.height)
        return BubbleGlass.surfaceRect(in: NSRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2,
                                                  width: width, height: height), orientation: orientation)
    }

    static func draw(in bounds: NSRect, style: SaveButtonStyle, bubbleStyle: BubbleStyle = .shortCaptions,
                     orientation: ShelfOrientation = .horizontal, highlighted: Bool = false,
                     nativeBackdrop: Bool = false, confirmation: CGFloat = 0) {
        let face = surfaceRect(in: bounds, style: style, bubbleStyle: bubbleStyle, orientation: orientation)
        guard !face.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        BubbleGlass.drawSurface(in: face, selected: highlighted, nativeBackdrop: nativeBackdrop)

        let naturalSize = size(for: style, bubbleStyle: bubbleStyle, orientation: orientation)
        let naturalFace = BubbleGlass.surfaceRect(in: NSRect(origin: .zero, size: naturalSize), orientation: orientation)
        let portrait = orientation == .vertical
        let scale = portrait ? min(1, face.width / naturalFace.width, face.height / naturalFace.height)
                             : min(1, face.height / naturalFace.height)
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: face.midX, y: face.midY)
        context.scaleBy(x: scale, y: scale)
        let text = "Save" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: BubbleGlass.captionFont, .foregroundColor: NSColor.labelColor
        ]
        let textSize = style == .bookmarkOnly ? .zero : text.size(withAttributes: attributes)
        func bookmark(_ name: String, color: NSColor) -> NSImage? {
            let config = NSImage.SymbolConfiguration(pointSize: style == .bookmarkOnly ? 13 : 12, weight: .medium)
            return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(config.applying(.init(paletteColors: [color])))
        }
        let symbol = style == .textOnly ? nil : bookmark("bookmark", color: .labelColor)
        let iconWidth = symbol?.size.width ?? 0
        let gap: CGFloat = symbol != nil && style == .bookmarkAndText ? 4 : 0
        let left = -(iconWidth + gap + textSize.width) / 2
        let iconHeight = symbol?.size.height ?? 0
        let top = (iconHeight + gap + textSize.width) / 2
        if let symbol {
            let iconRect = NSRect(x: portrait ? -iconWidth / 2 : left, y: portrait ? top - iconHeight : -iconHeight / 2,
                                  width: iconWidth, height: iconHeight)
            if confirmation < 1 {
                symbol.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1 - confirmation)
            }
            if confirmation > 0, let filled = bookmark("bookmark.fill", color: ribbonBlue) {
                filled.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: confirmation)
            }
        }
        if style != .bookmarkOnly {
            if portrait {
                context.translateBy(x: 0, y: top - iconHeight - gap - textSize.width / 2)
                context.rotate(by: -.pi / 2)
            }
            let x = portrait ? -textSize.width / 2 : left + iconWidth + gap
            text.draw(at: NSPoint(x: x, y: -textSize.height / 2), withAttributes: attributes)
        }
    }
}
