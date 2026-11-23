import AppKit
import SwiftUI

#if compiler(>=6.2)
@available(macOS 26.0, *)
private final class ClearBubbleBackdrop: NSView {
    private let glass = NSGlassEffectView()
    private let rim = CAShapeLayer()
    var pointerOpening: NSRect? { didSet { if pointerOpening != oldValue { needsLayout = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        rim.fillRule = .evenOdd
        rim.fillColor = CGColor(gray: 1, alpha: 1)
        layer?.mask = rim
        // Keep the system's contact shadow light when the backdrop belongs to
        // another app. The foreground supplies the brighter specular highlights.
        alphaValue = 0.26
        glass.style = .clear
        glass.tintColor = nil
        glass.setAccessibilityElement(false)
        setAccessibilityElement(false)
        addSubview(glass)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        glass.frame = bounds
        glass.cornerRadius = BubbleGlass.cornerRadius(for: bounds)
        // The full system material diffuses detail in inactive windows. Keep its
        // optical effect at the perimeter and let the real window show through the face.
        let inner = bounds.insetBy(dx: 1.7, dy: 1.7)
        let path = CGMutablePath()
        path.addPath(BubbleGlass.contour(of: bounds))
        if !inner.isEmpty { path.addPath(BubbleGlass.contour(of: inner)) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rim.frame = bounds
        rim.path = pointerOpening.map { path.subtracting(CGPath(rect: $0, transform: nil), using: .evenOdd) } ?? path
        CATransaction.commit()
    }
}
#endif

/// The shelf, Settings and drag preview use the same surface and typography.
@MainActor
enum BubbleGlass {
    nonisolated static let rowHeight: CGFloat = 40
    static let verticalLabelLineHeight: CGFloat = 12

    nonisolated static func portraitCell(for style: BubbleStyle) -> NSSize {
        NSSize(width: rowHeight, height: style == .shortCaptions ? 108 : 78)
    }

    static func cellSize(for style: BubbleStyle, caption: String? = nil, number: Int? = nil) -> NSSize {
        let width: CGFloat
        if style == .shortCaptions, caption == nil {
            width = 118
        } else {
            let value = label(for: style, caption: caption ?? "", number: number) as NSString
            let measured = ceil(value.size(withAttributes: [.font: font(for: style)]).width)
            // Count the gap between tiles and both text insets in the scrollable cell.
            width = min(176, max(style == .shortCaptions ? 64 : 54, measured + 31))
        }
        return NSSize(width: width, height: rowHeight)
    }

    static func caption(for text: String) -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace })
        guard let first = words.first else { return "" }
        let articles = ["a", "an", "the"]
        var excerpt = [first]
        for index in words.indices.dropFirst() {
            let word = words[index]
            if articles.contains(word.lowercased()) { continue }
            if excerpt.count >= 2 && index < words.count - 1 &&
                ["for", "to", "of", "with", "in", "on", "and"].contains(word.lowercased()) { break }
            excerpt.append(word)
            if excerpt.count == 3 { break }
        }
        var result = excerpt.joined(separator: " ")
        while let last = result.last, ".,!?:;。！？、".contains(last), result.count > 1 { result.removeLast() }
        return result
    }

    static func surfaceRect(in bounds: NSRect, orientation: ShelfOrientation = .horizontal) -> NSRect {
        let portrait = orientation == .vertical
        let dx: CGFloat = portrait ? 5 : 3.5, dy: CGFloat = portrait ? 3.5 : 5
        guard bounds.width > 2 * dx, bounds.height > 2 * dy else { return .zero }
        return bounds.insetBy(dx: dx, dy: dy)
    }

    static func contour(of rect: NSRect, tip: CGPoint? = nil) -> CGPath {
        let outline = RoundedRectangle(cornerRadius: cornerRadius(for: rect), style: .continuous).path(in: rect).cgPath
        guard let tip else { return outline }
        // Build side pointers by swapping the axes of the same contour.
        let side = tip.x < rect.minX || tip.x > rect.maxX
        let point = side ? CGPoint(x: tip.y, y: tip.x) : tip
        let below = side ? tip.x < rect.midX : tip.y < rect.midY
        let y = side ? (below ? rect.minX : rect.maxX) : (below ? rect.minY : rect.maxY)
        let inside = below ? y + 2 : y - 2
        let tail = CGMutablePath()
        tail.move(to: CGPoint(x: point.x - 11, y: inside))
        tail.addLine(to: CGPoint(x: point.x - 11, y: y))
        tail.addCurve(to: point, control1: CGPoint(x: point.x - 5, y: y), control2: CGPoint(x: point.x - 3, y: point.y))
        tail.addCurve(to: CGPoint(x: point.x + 11, y: y), control1: CGPoint(x: point.x + 3, y: point.y),
                      control2: CGPoint(x: point.x + 5, y: y))
        tail.addLine(to: CGPoint(x: point.x + 11, y: inside))
        tail.closeSubpath()
        if side {
            var swap = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
            return tail.copy(using: &swap).map { outline.union($0) } ?? outline
        }
        return outline.union(tail)
    }

    static func cornerRadius(for rect: NSRect) -> CGFloat {
        let side = min(rect.width, rect.height)
        return min(side > rowHeight ? 15 : 9, side / 3)
    }

    static var usesNativeBackdrop: Bool {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            return !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        }
        #endif
        return false
    }

    static func makeBackdrop() -> NSView? {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), usesNativeBackdrop {
            return ClearBubbleBackdrop(frame: .zero)
        }
        #endif
        return nil
    }

    static func fitPreviewBackdrop(_ backdrop: NSView?, to face: NSRect, tip: CGPoint?) {
        guard let backdrop else { return }
        backdrop.frame = face
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), let rim = backdrop as? ClearBubbleBackdrop {
            // Let the painted rim follow the pointer, without a second straight
            // edge across the opening where the pointer joins the reading surface.
            rim.pointerOpening = tip.map { point in
                if point.x < face.minX || point.x > face.maxX {
                    return NSRect(x: point.x < face.midX ? -1 : face.width - 3, y: point.y - face.minY - 11,
                                  width: 4, height: 22)
                }
                return NSRect(x: point.x - face.minX - 11, y: point.y < face.midY ? -1 : face.height - 3,
                              width: 22, height: 4)
            }
        }
        #endif
    }

    static func drawSurface(in surface: NSRect, selected: Bool = false, nativeBackdrop: Bool = false, tip: CGPoint? = nil) {
        guard !surface.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        let dark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let workspace = NSWorkspace.shared
        let opaque = workspace.accessibilityDisplayShouldReduceTransparency
        let contrast = workspace.accessibilityDisplayShouldIncreaseContrast
        context.saveGState()
        // Fully transparent pixels in a borderless window pass mouse events to the app beneath.
        context.addPath(contour(of: surface, tip: tip))
        context.setFillColor(opaque ? NSColor.controlBackgroundColor.cgColor : CGColor(gray: 0.5, alpha: 0.02))
        context.fillPath()
        if !opaque {
            // WindowServer supplies the narrow native rim. This directional highlight
            // also keeps the glass readable over a flat editor background.
            context.saveGState()
            if nativeBackdrop { context.setAlpha(0.88) }
            drawOpticalRim(in: surface, tip: tip, dark: dark, context: context)
            context.restoreGState()
        }
        if selected || opaque || contrast {
            let width: CGFloat = contrast ? 1.5 : (selected ? 1.15 : 0.8)
            context.addPath(contour(of: surface.insetBy(dx: width / 2, dy: width / 2), tip: tip))
            let edge = NSColor.labelColor.withAlphaComponent(contrast ? 0.8 : (selected ? 0.55 : 0.32))
            context.setStrokeColor(edge.cgColor)
            context.setLineWidth(width)
            context.strokePath()
        }
        context.restoreGState()
    }

    static func draw(in bounds: NSRect, style: BubbleStyle, caption: String,
                     number: Int?, orientation: ShelfOrientation = .horizontal,
                     selected: Bool = false, nativeBackdrop: Bool = false) {
        let surface = surfaceRect(in: bounds, orientation: orientation)
        guard !surface.isEmpty else { return }
        drawSurface(in: surface, selected: selected, nativeBackdrop: nativeBackdrop)
        if orientation == .vertical && style == .shortCaptions {
            drawVerticalLabel(caption, in: surface.insetBy(dx: 4, dy: 6))
            return
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let text = label(for: style, caption: caption, number: number) as NSString
        var typeface = font(for: style)
        let uprightNumber = orientation == .vertical && style == .numbers
        if uprightNumber {
            let measured = text.size(withAttributes: [.font: typeface]).width
            let room = max(1, surface.width - 4)
            if measured > room {
                let fitted = max(6, floor(typeface.pointSize * room / measured))
                typeface = .monospacedDigitSystemFont(ofSize: fitted, weight: .medium)
            }
        }
        if style == .shortCaptions, text.size(withAttributes: [.font: typeface]).width > surface.width - 10 {
            for candidate in [NSFont.systemFont(ofSize: 12, weight: .medium, width: .init(rawValue: -0.1)), compactCaptionFont]
                where text.size(withAttributes: [.font: candidate]).width <= surface.width - 10 {
                typeface = candidate
                break
            }
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: typeface, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
        ]
        let textSize = text.size(withAttributes: attributes)
        let padding = uprightNumber ? 2 : min(11, max(5, floor((surface.width - textSize.width) / 2)))
        let available = surface.insetBy(dx: padding, dy: 0)
        guard available.width > 0 else { return }
        let height = ceil(textSize.height)
        text.draw(in: NSRect(x: available.minX, y: available.midY - height / 2,
                             width: available.width, height: height + 1), withAttributes: attributes)
    }

    static func verticalLabel(_ text: String, fitting height: CGFloat) -> String {
        let rows = Int(max(0, height) / verticalLabelLineHeight)
        guard rows > 0 else { return "" }
        let prefix = text.prefix(rows + 1)
        guard prefix.count > rows else { return String(prefix) }
        return prefix.prefix(rows - 1).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    static func drawVerticalLabel(_ text: String, in bounds: NSRect) {
        guard !bounds.isEmpty else { return }
        let label = verticalLabel(text, fitting: bounds.height)
        let attributes: [NSAttributedString.Key: Any] = [.font: captionFont, .foregroundColor: NSColor.labelColor]
        let lineHeight = verticalLabelLineHeight
        var centerY = bounds.midY + CGFloat(label.count - 1) * lineHeight / 2
        for character in label {
            let glyph = String(character) as NSString
            let size = glyph.size(withAttributes: attributes)
            glyph.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: centerY - size.height / 2), withAttributes: attributes)
            centerY -= lineHeight
        }
    }

    // A drag image has no live backing window. A narrow shaded edge keeps its
    // shape legible over any destination and leaves the center transparent.
    private static func drawOpticalRim(in surface: NSRect, tip: CGPoint?, dark: Bool, context: CGContext) {
        let rim = contour(of: surface.insetBy(dx: 0.5, dy: 0.5), tip: tip)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -0.7), blur: 1.4,
                          color: CGColor(gray: 0, alpha: dark ? 0.4 : 0.26))
        context.addPath(rim)
        context.setLineWidth(0.9)
        context.setStrokeColor(CGColor(gray: 0, alpha: dark ? 0.38 : 0.24))
        context.strokePath()
        context.restoreGState()

        context.saveGState()
        context.addPath(rim)
        context.setLineWidth(1.25)
        context.replacePathWithStrokedPath()
        context.clip()
        let start = CGPoint(x: surface.minX, y: surface.maxY)
        let end = CGPoint(x: surface.maxX, y: surface.minY)
        context.drawLinearGradient(dark ? darkRim : lightRim, start: start, end: end,
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        context.restoreGState()

        context.addPath(contour(of: surface, tip: tip))
        context.clip()
        context.drawLinearGradient(lip, start: CGPoint(x: 0, y: surface.maxY),
                                   end: CGPoint(x: 0, y: surface.maxY - 3.0), options: [])
        // Glancing light catches each curved corner and fades within a few points.
        // Keep the middle perfectly clear, including over an empty composer.
        let reach = min(17, surface.width * 0.22)
        for (point, width, height) in [
            (CGPoint(x: surface.minX + 8, y: surface.maxY), reach, CGFloat(5.5)),
            (CGPoint(x: surface.maxX - 7, y: surface.minY - 0.6), reach * 0.8, CGFloat(3.6))
        ] {
            context.saveGState()
            context.translateBy(x: point.x, y: point.y)
            context.scaleBy(x: width, y: height)
            context.drawRadialGradient(reflection, startCenter: .zero, startRadius: 0,
                                       endCenter: .zero, endRadius: 1, options: [])
            context.restoreGState()
        }
    }

    private static let lightRim = gradient([
        1, 0.79,  1, 0.67,  1, 0.36,  0.26, 0.19,  1, 0.24,  1, 0.76
    ], stops: [0, 0.09, 0.30, 0.53, 0.72, 1])
    private static let darkRim = gradient([
        1, 0.65,  1, 0.52,  1, 0.28,  0.40, 0.20,  1, 0.20,  1, 0.58
    ], stops: [0, 0.09, 0.30, 0.53, 0.72, 1])
    private static let lip = gradient([1, 0.22, 1, 0.045, 1, 0], stops: [0, 0.52, 1])
    private static let reflection = gradient([1, 0.90, 1, 0.45, 1, 0.08, 1, 0],
                                             stops: [0, 0.27, 0.67, 1])

    private static func gradient(_ components: [CGFloat], stops: [CGFloat]) -> CGGradient {
        CGGradient(colorSpace: CGColorSpaceCreateDeviceGray(), colorComponents: components,
                   locations: stops, count: stops.count)!
    }

    private static func label(for style: BubbleStyle, caption: String, number: Int?) -> String {
        style == .shortCaptions ? caption : number.map(String.init) ?? ""
    }

    static let captionFont = NSFont.systemFont(ofSize: 12, weight: .medium)

    private static func font(for style: BubbleStyle) -> NSFont {
        style == .shortCaptions ? captionFont
            : .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    }

    private static var compactCaptionFont: NSFont {
        .systemFont(ofSize: 11.5, weight: .medium, width: .condensed)
    }
}
