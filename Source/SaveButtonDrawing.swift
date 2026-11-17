import AppKit

@MainActor
enum SaveButtonDrawing {
    nonisolated static let reservedWidth: CGFloat = 76

    static func size(for style: SaveButtonStyle, bubbleStyle: BubbleStyle = .shortCaptions) -> NSSize {
        let cell = BubbleGlass.cellSize(for: bubbleStyle, caption: "Save", number: 1)
        if bubbleStyle == .shortCaptions && style == .bookmarkAndText {
            return NSSize(width: reservedWidth, height: cell.height)
        }
        return cell
    }

    static func surfaceRect(in bounds: NSRect, style: SaveButtonStyle, bubbleStyle: BubbleStyle = .shortCaptions) -> NSRect {
        let size = size(for: style, bubbleStyle: bubbleStyle)
        let width = min(bounds.width, size.width), height = min(bounds.height, size.height)
        return BubbleGlass.surfaceRect(in: NSRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2,
                                                  width: width, height: height))
    }

    static func draw(in bounds: NSRect, style: SaveButtonStyle, bubbleStyle: BubbleStyle = .shortCaptions, highlighted: Bool = false,
                     nativeBackdrop: Bool = false) {
        let face = surfaceRect(in: bounds, style: style, bubbleStyle: bubbleStyle)
        guard !face.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        BubbleGlass.drawSurface(in: face, selected: highlighted, nativeBackdrop: nativeBackdrop)

        let scale = min(1, face.height / BubbleGlass.surfaceRect(in: NSRect(origin: .zero, size: size(for: style, bubbleStyle: bubbleStyle))).height)
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: face.midX, y: face.midY)
        context.scaleBy(x: scale, y: scale)
        let text = "Save" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: BubbleGlass.captionFont, .foregroundColor: NSColor.labelColor
        ]
        let textSize = style == .bookmarkOnly ? .zero : text.size(withAttributes: attributes)
        var symbol: NSImage?
        if style != .textOnly {
            let config = NSImage.SymbolConfiguration(pointSize: style == .bookmarkOnly ? 13 : 12, weight: .medium)
            symbol = NSImage(systemSymbolName: "bookmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(config.applying(.init(paletteColors: [.labelColor])))
        }
        let iconWidth = symbol?.size.width ?? 0
        let gap: CGFloat = symbol != nil && style == .bookmarkAndText ? 4 : 0
        let left = -(iconWidth + gap + textSize.width) / 2
        if let symbol {
            symbol.draw(at: NSPoint(x: left, y: -symbol.size.height / 2),
                        from: .zero, operation: .sourceOver, fraction: 1)
        }
        if style != .bookmarkOnly {
            text.draw(at: NSPoint(x: left + iconWidth + gap, y: -textSize.height / 2),
                      withAttributes: attributes)
        }
    }
}
