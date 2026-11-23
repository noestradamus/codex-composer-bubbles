import AppKit

@MainActor
private final class ShelfPreviewInk: NSView {
    weak var shelf: BubbleStylePreview?
    override func draw(_ dirtyRect: NSRect) { shelf?.drawControls() }
}

@MainActor
private final class BubbleStylePreview: NSView {
    private let examples = ["Review changes", "Write tests"]
    private let ink = ShelfPreviewInk()
    private var backdrops: [NSView] = []
    var style: BubbleStyle {
        didSet { updateMaterial() }
    }
    var saveStyle: SaveButtonStyle {
        didSet { updateMaterial() }
    }
    var orientation: ShelfOrientation {
        didSet { updateMaterial() }
    }

    init(style: BubbleStyle, saveStyle: SaveButtonStyle, orientation: ShelfOrientation) {
        self.style = style
        self.saveStyle = saveStyle
        self.orientation = orientation
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Shelf preview")
        ink.shelf = self
        ink.setAccessibilityElement(false)
        addSubview(ink)
        updateMaterial()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(updateMaterial),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func accessibilityValue() -> Any? { "\(orientation.title), \(style.title), \(saveStyle.title)" }

    @objc private func updateMaterial() {
        if BubbleGlass.usesNativeBackdrop, backdrops.isEmpty {
            // The preview contains the glass tab, one surface per suggestion, then Save.
            backdrops = (0..<(examples.count + 2)).compactMap { _ in BubbleGlass.makeBackdrop() }
            for backdrop in backdrops { addSubview(backdrop, positioned: .below, relativeTo: ink) }
        } else if !BubbleGlass.usesNativeBackdrop {
            for backdrop in backdrops { backdrop.removeFromSuperview() }
            backdrops.removeAll()
        }
        needsLayout = true
        ink.needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        ink.needsDisplay = true
    }

    private func frames(in bounds: NSRect) -> (tab: NSRect, tiles: [NSRect], save: NSRect) {
        let tabSize = GlassTabDrawing.controlSize
        let saveSize = SaveButtonDrawing.size(for: saveStyle, bubbleStyle: style, orientation: orientation)
        if orientation == .vertical {
            let tile = NSRect(x: bounds.midX - saveSize.width / 2, y: 0, width: saveSize.width, height: saveSize.height)
            let save = tile.offsetBy(dx: 0, dy: tile.height)
            let tab = NSRect(x: bounds.midX - tabSize.width / 2, y: save.maxY + 2, width: tabSize.width, height: tabSize.height)
            return (tab, [tile], save)
        }
        let sizes = examples.enumerated().map {
            BubbleGlass.cellSize(for: style, caption: $0.element, number: $0.offset + 1)
        }
        let tabGap: CGFloat = 4, saveGap: CGFloat = 8
        let totalWidth = sizes.reduce(tabSize.width + tabGap + saveSize.width + saveGap) { $0 + $1.width }
        var x = bounds.midX - totalWidth / 2
        let tab = NSRect(origin: NSPoint(x: x, y: bounds.midY - tabSize.height / 2), size: tabSize)
        x = tab.maxX + tabGap
        let tiles = sizes.map { size in
            let tile = NSRect(origin: NSPoint(x: x, y: bounds.midY - size.height / 2), size: size)
            x += size.width
            return tile
        }
        let saveRect = NSRect(origin: NSPoint(x: x + saveGap, y: bounds.midY - saveSize.height / 2), size: saveSize)
        return (tab, tiles, saveRect)
    }

    override func layout() {
        super.layout()
        if orientation == .vertical {
            let cell = BubbleGlass.portraitCell(for: style)
            let height = GlassTabDrawing.controlSize.height + 2 + 2 * cell.height
            let scale = min(1, max(0, bounds.height - 8) / height)
            ink.frame = NSRect(x: bounds.midX - cell.width * scale / 2, y: bounds.midY - height * scale / 2,
                               width: cell.width * scale, height: height * scale)
            ink.bounds = NSRect(x: 0, y: 0, width: cell.width, height: height)
        } else {
            ink.frame = bounds
            ink.bounds = NSRect(origin: .zero, size: bounds.size)
        }
        let frames = frames(in: ink.bounds)
        let surfaces = [GlassTabDrawing.surfaceRect(in: frames.tab)]
            + frames.tiles.map { BubbleGlass.surfaceRect(in: $0, orientation: orientation) }
            + [SaveButtonDrawing.surfaceRect(in: frames.save, style: saveStyle, bubbleStyle: style, orientation: orientation)]
        for (index, backdrop) in backdrops.enumerated() {
            backdrop.isHidden = !surfaces.indices.contains(index)
            if !backdrop.isHidden { backdrop.frame = convert(surfaces[index], from: ink) }
        }
    }

    fileprivate func drawControls() {
        let frames = frames(in: ink.bounds)
        GlassTabDrawing.draw(in: frames.tab, nativeBackdrop: !backdrops.isEmpty)
        for (index, tile) in frames.tiles.enumerated() {
            let caption = orientation == .vertical ? BubbleGlass.portraitWord(for: examples[index]) : examples[index]
            BubbleGlass.draw(in: tile, style: style, caption: caption, number: index + 1, orientation: orientation,
                             nativeBackdrop: backdrops.indices.contains(index + 1))
        }
        SaveButtonDrawing.draw(in: frames.save, style: saveStyle, bubbleStyle: style, orientation: orientation,
                               nativeBackdrop: backdrops.indices.contains(frames.tiles.count + 1))
    }
}

@MainActor
final class BubbleSettingsController: NSWindowController {
    private let defaults: UserDefaults
    private let onChange: (BubbleStyle) -> Void
    private let onSaveStyleChange: (SaveButtonStyle) -> Void
    private let onOrientationChange: (ShelfOrientation) -> Void
    private let styles = BubbleStyle.allCases
    private let saveStyles = SaveButtonStyle.allCases
    private let orientations = ShelfOrientation.allCases
    private let picker: NSSegmentedControl
    private let savePicker: NSSegmentedControl
    private let orientationPicker: NSSegmentedControl
    private let preview: BubbleStylePreview

    init(defaults: UserDefaults, onChange: @escaping (BubbleStyle) -> Void,
         onSaveStyleChange: @escaping (SaveButtonStyle) -> Void,
         onOrientationChange: @escaping (ShelfOrientation) -> Void) {
        self.defaults = defaults
        self.onChange = onChange
        self.onSaveStyleChange = onSaveStyleChange
        self.onOrientationChange = onOrientationChange
        preview = BubbleStylePreview(style: .load(from: defaults), saveStyle: .load(from: defaults),
                                     orientation: .load(from: defaults))
        picker = NSSegmentedControl(labels: BubbleStyle.allCases.map(\.title), trackingMode: .selectOne,
                                    target: nil, action: nil)
        savePicker = NSSegmentedControl(labels: SaveButtonStyle.allCases.map(\.title), trackingMode: .selectOne,
                                        target: nil, action: nil)
        orientationPicker = NSSegmentedControl(labels: ShelfOrientation.allCases.map(\.title), trackingMode: .selectOne,
                                               target: nil, action: nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 405),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Composer Bubbles Settings"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.setAccessibilityIdentifier("composer-bubbles.settings")
        guard let content = window.contentView else { return }
        let heading = NSTextField(labelWithString: "Bubble style")
        let saveHeading = NSTextField(labelWithString: "Save button")
        let orientationHeading = NSTextField(labelWithString: "Shelf orientation")
        for (label, control, id, action) in [
            (heading, picker, "composer-bubbles.style-picker", #selector(selectStyle(_:))),
            (saveHeading, savePicker, "composer-bubbles.save-style-picker", #selector(selectSaveStyle(_:))),
            (orientationHeading, orientationPicker, "composer-bubbles.orientation-picker", #selector(selectOrientation(_:)))
        ] {
            label.font = .systemFont(ofSize: 15, weight: .semibold)
            control.setAccessibilityLabel(label.stringValue)
            control.setAccessibilityIdentifier(id)
            control.segmentDistribution = .fillEqually
            control.target = self
            control.action = action
        }
        let scope = NSTextField(labelWithString: "Applies to all chats on this Mac.")
        scope.textColor = .secondaryLabelColor
        scope.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        for view in [heading, picker, saveHeading, savePicker, orientationHeading, orientationPicker, preview, scope] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            picker.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 10),
            picker.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            picker.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            saveHeading.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            saveHeading.topAnchor.constraint(equalTo: picker.bottomAnchor, constant: 17),
            savePicker.topAnchor.constraint(equalTo: saveHeading.bottomAnchor, constant: 10),
            savePicker.leadingAnchor.constraint(equalTo: picker.leadingAnchor),
            savePicker.trailingAnchor.constraint(equalTo: picker.trailingAnchor),
            orientationHeading.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            orientationHeading.topAnchor.constraint(equalTo: savePicker.bottomAnchor, constant: 17),
            orientationPicker.topAnchor.constraint(equalTo: orientationHeading.bottomAnchor, constant: 10),
            orientationPicker.leadingAnchor.constraint(equalTo: picker.leadingAnchor),
            orientationPicker.trailingAnchor.constraint(equalTo: picker.trailingAnchor),
            preview.topAnchor.constraint(equalTo: orientationPicker.bottomAnchor, constant: 6),
            preview.leadingAnchor.constraint(equalTo: picker.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: picker.trailingAnchor),
            preview.bottomAnchor.constraint(equalTo: scope.topAnchor, constant: -6),
            scope.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            scope.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])
        window.initialFirstResponder = picker
        refreshFromDefaults()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func present() {
        refreshFromDefaults()
        if #available(macOS 14.0, *) { NSApp.activate() }
        else { NSApp.activate(ignoringOtherApps: true) }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func selectStyle(_ sender: NSSegmentedControl) {
        guard styles.indices.contains(sender.selectedSegment) else { return }
        let style = styles[sender.selectedSegment]
        style.save(to: defaults)
        preview.style = style
        onChange(style)
    }

    @objc private func selectSaveStyle(_ sender: NSSegmentedControl) {
        guard saveStyles.indices.contains(sender.selectedSegment) else { return }
        let style = saveStyles[sender.selectedSegment]
        style.save(to: defaults)
        preview.saveStyle = style
        onSaveStyleChange(style)
    }

    @objc private func selectOrientation(_ sender: NSSegmentedControl) {
        guard orientations.indices.contains(sender.selectedSegment) else { return }
        onOrientationChange(orientations[sender.selectedSegment])
    }

    func updateOrientation(_ orientation: ShelfOrientation) {
        preview.orientation = orientation
        orientationPicker.selectedSegment = orientations.firstIndex(of: orientation) ?? 0
    }

    private func refreshFromDefaults() {
        preview.style = .load(from: defaults)
        preview.saveStyle = .load(from: defaults)
        picker.selectedSegment = styles.firstIndex(of: preview.style) ?? 0
        savePicker.selectedSegment = saveStyles.firstIndex(of: preview.saveStyle) ?? 0
        updateOrientation(.load(from: defaults))
    }
}
