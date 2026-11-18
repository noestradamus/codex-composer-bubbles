import AppKit

enum DisplayPlacementChecks {
    static func run() {
        let builtIn = ShelfDisplay(id: "built-in", frame: NSRect(x: 0, y: 0, width: 1470, height: 956),
                                   visibleFrame: NSRect(x: 0, y: 0, width: 1470, height: 923))
        let external = ShelfDisplay(id: "external", frame: NSRect(x: -1191, y: 956, width: 1920, height: 1080),
                                    visibleFrame: NSRect(x: -1191, y: 956, width: 1920, height: 1047))
        let both = [builtIn, external]
        let builtInAnchor = NSRect(x: 400, y: 40, width: 650, height: 75)
        let externalAnchor = NSRect(x: -800, y: 1000, width: 600, height: 70)
        let oldPin = ShelfPlacement(displayID: builtIn.id, grip: NSPoint(x: 956, y: 164),
                                    displayFrame: builtIn.frame, horizontal: true, widthLimit: 325)
        let suite = "ComposerBubbles.DisplayTest." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try! JSONEncoder().encode(oldPin), forKey: "shelfPlacementV2")

        var positions = ShelfPlacements(defaults: defaults)
        func resolve(_ host: ShelfDisplay, _ anchor: NSRect, real: Bool = true, count: Int = 1,
                     screens: [ShelfDisplay]? = nil) -> (placement: ShelfPlacement, display: ShelfDisplay, didSave: Bool) {
            positions.resolve(host: host, connected: screens ?? both, anchor: anchor, count: count, realAnchor: real)
        }
        precondition(resolve(builtIn, builtInAnchor).placement == oldPin)
        let estimate = resolve(external, externalAnchor.offsetBy(dx: 70, dy: 25), real: false)
        precondition(estimate.display == external && !estimate.didSave)
        let first = resolve(external, externalAnchor)
        precondition(first.display == external && first.placement.displayID == external.id)
        let externalPin = ShelfPlacement(displayID: external.id, grip: NSPoint(x: -720, y: 1130),
                                         displayFrame: external.frame, horizontal: true, widthLimit: 325)
        positions.pin(externalPin, for: external.id)
        for count in [0, 3, 12] {
            precondition(resolve(builtIn, builtInAnchor, count: count).placement == oldPin)
            precondition(resolve(external, externalAnchor.offsetBy(dx: 40, dy: 100),
                                 real: false, count: count).placement == externalPin)
        }

        positions.save(to: defaults)
        positions = ShelfPlacements(defaults: defaults)
        precondition(resolve(external, externalAnchor).placement == externalPin)
        precondition(resolve(builtIn, builtInAnchor).placement == oldPin)

        // A deliberate drag across the display boundary belongs to the window's original display.
        positions.pin(externalPin, for: builtIn.id)
        precondition(resolve(builtIn, builtInAnchor).display == external)
        precondition(resolve(builtIn, builtInAnchor, screens: [builtIn]).display == builtIn)
        precondition(resolve(builtIn, builtInAnchor).placement == externalPin)
        positions.reset(for: builtIn.id)
        precondition(resolve(builtIn, builtInAnchor).display == builtIn)
        precondition(resolve(external, externalAnchor).placement == externalPin)
        print("Passed display switching, per-display placement, migration, reconnection and reset.")
    }
}
