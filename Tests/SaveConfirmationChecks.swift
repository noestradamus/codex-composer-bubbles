import AppKit

@MainActor
enum SaveConfirmationChecks {
    static func run() {
        func level(_ t: Double, from initial: CGFloat = 0, reduced: Bool = false) -> CGFloat {
            SaveButtonDrawing.confirmation(at: t, startingFrom: initial, reduceMotion: reduced)
        }
        precondition(level(0) == 0 && level(0.14) == 1 && level(0.68) == 1 && level(1.05) == 0)
        precondition(abs(level(0.07) - 0.5) < 0.001 && abs(level(0.865) - 0.5) < 0.001)
        precondition(level(0, from: 0.4) == 0.4 && level(0.07, from: 1) == 1)
        precondition(level(0, reduced: true) == 1 && level(0.679, reduced: true) == 1 && level(0.68, reduced: true) == 0)

        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = NSAppearance(named: appearanceName)!
            for style in SaveButtonStyle.allCases {
                let size = SaveButtonDrawing.size(for: style)
                let width = Int(size.width) * 3
                let idle = render(style, size: size, appearance: appearance, level: 0)
                let saved = render(style, size: size, appearance: appearance, level: 1)
                if style == .textOnly {
                    precondition(idle == saved, "Text-only Save changed during confirmation")
                    continue
                }
                var bluePixels = 0
                for index in stride(from: 0, to: saved.count, by: 4) {
                    let pixel = index..<(index + 4)
                    guard idle[pixel] != saved[pixel] else { continue }
                    let x = (index / 4) % width, y = (index / 4) / width
                    let allowedX = style == .bookmarkOnly ? (width / 2 - 24)...(width / 2 + 24) : 0...(width / 2)
                    precondition(allowedX.contains(x) && abs(y - Int(size.height) * 3 / 2) <= 28,
                                 "Save confirmation redrew pixels outside the bookmark")
                    if abs(Int(saved[index]) - 35) <= 3, abs(Int(saved[index + 1]) - 83) <= 3,
                       abs(Int(saved[index + 2]) - 250) <= 3 { bluePixels += 1 }
                }
                precondition(bluePixels > 25, "The bookmark did not fill with the ribbon blue")
            }
        }
        print("Passed Save bookmark color, unchanged label and surface, repeat timing, and Reduce Motion checks.")
    }

    private static func render(_ style: SaveButtonStyle, size: CGSize, appearance: NSAppearance, level: CGFloat) -> [UInt8] {
        let width = Int(size.width) * 3, height = Int(size.height) * 3
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                    bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.scaleBy(x: 3, y: 3)
            let bounds = CGRect(origin: .zero, size: size)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            appearance.performAsCurrentDrawingAppearance {
                context.setFillColor(NSColor.windowBackgroundColor.cgColor)
                context.fill(bounds)
                SaveButtonDrawing.draw(in: bounds, style: style, confirmation: level)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        return bytes
    }
}
