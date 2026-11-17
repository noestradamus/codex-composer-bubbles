import AppKit

@MainActor
enum GlassTabDrawing {
    nonisolated static let controlSize = NSSize(width: 21, height: 30)
    private static let faceSize = NSSize(width: 12.4, height: 25.2)

    static func surfaceRect(in bounds: NSRect) -> NSRect {
        guard !bounds.isEmpty else { return .zero }
        let scale = min(1, bounds.width / controlSize.width, bounds.height / controlSize.height)
        let width = faceSize.width * scale, height = faceSize.height * scale
        return NSRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
    }

    static func draw(in bounds: NSRect, grabbed: Bool = false, nativeBackdrop: Bool = false) {
        let face = surfaceRect(in: bounds)
        guard !face.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        BubbleGlass.drawSurface(in: face, selected: grabbed, nativeBackdrop: nativeBackdrop)

        let dark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let scale = face.height / faceSize.height
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: face.midX, y: face.midY)
        context.scaleBy(x: scale, y: scale)
        context.setLineCap(.round)

        // The slight offset puts a highlight on one wall of the inset groove.
        let shine = dark ? NSColor(srgbRed: 0.96, green: 0.98, blue: 1, alpha: 0.58) : .white
        context.setStrokeColor(shine.cgColor)
        context.setLineWidth(1.32)
        context.move(to: CGPoint(x: 0.42, y: -5.53))
        context.addLine(to: CGPoint(x: 0.42, y: 4.57))
        context.strokePath()

        let shadow = dark ? NSColor(srgbRed: 0.016, green: 0.035, blue: 0.047, alpha: 0.72)
                          : NSColor(srgbRed: 0.322, green: 0.345, blue: 0.380, alpha: 0.64)
        context.setStrokeColor((highContrast ? NSColor.labelColor : shadow).cgColor)
        context.setLineWidth(highContrast ? 1.7 : 1.36)
        context.move(to: CGPoint(x: -0.2, y: -5.05))
        context.addLine(to: CGPoint(x: -0.2, y: 5.05))
        context.strokePath()
    }
}
