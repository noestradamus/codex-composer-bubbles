import AppKit
import ApplicationServices
import Carbon
import OSLog

// Register a single shortcut while Codex is active. This does not observe typing.
private final class SaveShortcut {
    private var key: EventHotKeyRef?
    private var handler: EventHandlerRef?
    let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            var pressed = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            guard result == noErr, pressed.signature == 0x43425542, pressed.id == 1 else {
                return OSStatus(eventNotHandledErr)
            }
            Unmanaged<SaveShortcut>.fromOpaque(context).takeUnretainedValue().action()
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func setActive(_ active: Bool) {
        if active && key == nil && handler != nil {
            let ident = EventHotKeyID(signature: 0x43425542, id: 1)
            RegisterEventHotKey(UInt32(kVK_ANSI_B), UInt32(cmdKey | optionKey | shiftKey),
                                ident, GetApplicationEventTarget(), 0, &key)
        } else if !active, let key {
            UnregisterEventHotKey(key)
            self.key = nil
        }
    }
}

private func visibleHostWindow(of application: NSRunningApplication) -> CGRect? {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let rows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]],
          let primary = NSScreen.screens.first else { return nil }
    for row in rows {
        guard row[kCGWindowOwnerPID as String] as? Int32 == application.processIdentifier,
              row[kCGWindowLayer as String] as? Int == 0,
              let bounds = row[kCGWindowBounds as String] as? NSDictionary,
              let box = CGRect(dictionaryRepresentation: bounds),
              box.width > 250, box.height > 160 else { continue }
        return CGRect(x: box.minX, y: primary.frame.maxY - box.maxY, width: box.width, height: box.height)
    }
    return nil
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let panel = BubblePanelController()
    private let host = HostAccess()
    private var observingPID: pid_t?
    private var refreshGeneration = 0
    private var refreshPending = false
    private var displayedChat: String?
    private var savingDraft = false
    private var store: BubbleStore!
    private var shortcut: SaveShortcut!
    private var status: NSStatusItem!
    private var timer: Timer?
    private var lastStatus: String?
    private let healthLog = Logger(subsystem: "local.composerbubbles.mac", category: "capture")
    private var lastHealth: String?
    private let defaults = UserDefaults.standard
    private lazy var settings = BubbleSettingsController(
        defaults: defaults,
        onChange: { [weak self] style in self?.panel.setStyle(style) },
        onSaveStyleChange: { [weak self] style in self?.panel.setSaveStyle(style) }
    )
    private let placementKey = "shelfPlacementV2"
    private var isHidden: Bool { defaults.bool(forKey: "hideShelf") }
    private var pendingRemoval: SavedBubble?
    private enum LinkAction {
        case show, currentDraft(String), selectedText(String), assignEarlier(UUID)
    }
    private struct LinkRequest {
        let id = UUID()
        let context: CodexLinkContext
        let initialCopy: Int
        let action: LinkAction
        let until: Date
    }
    private var linkRequest: LinkRequest?
    private var linkTimer: Timer?
    private let hostBundleID = "com.openai.codex"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            showError(ShelfError.unavailableDirectory.localizedDescription)
            NSApp.terminate(nil)
            return
        }
        store = BubbleStore(directory: base.appendingPathComponent("Composer Bubbles", isDirectory: true))
        do { try store.reload() } catch { lastStatus = error.localizedDescription }

        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "bubble.left.and.bubble.right", accessibilityDescription: "Composer Bubbles")
        status.button?.setAccessibilityLabel("Composer Bubbles")
        status.button?.toolTip = "Composer Bubbles"
        let menu = NSMenu()
        menu.delegate = self
        status.menu = menu
        let savedPlacement = defaults.data(forKey: placementKey).flatMap {
            try? JSONDecoder().decode(ShelfPlacement.self, from: $0)
        }
        let hasLegacyOffset = defaults.object(forKey: "shelfX") != nil || defaults.object(forKey: "shelfY") != nil
        let legacyOffset = hasLegacyOffset
            ? NSPoint(x: defaults.double(forKey: "shelfX"), y: defaults.double(forKey: "shelfY")) : nil
        panel.onPlacementChanged = { [weak self] placement in
            guard let self, let data = try? JSONEncoder().encode(placement) else { return }
            defaults.set(data, forKey: placementKey)
            defaults.removeObject(forKey: "shelfX")
            defaults.removeObject(forKey: "shelfY")
        }
        panel.restorePlacement(savedPlacement, legacyOffset: legacyOffset)
        panel.setStyle(.load(from: defaults))
        panel.setSaveStyle(.load(from: defaults))
        panel.onSettings = { [weak self] in self?.openSettings() }
        panel.onSave = { [weak self] in self?.saveDraft() }
        panel.onDropText = { [weak self] text in self?.saveText(text) ?? false }
        panel.onRemove = { [weak self] id in self?.removeBubble(id) }
        panel.canUseBubble = { [weak self] id in self?.canUseBubble(id) ?? false }
        panel.verifyPreview = { [weak self] id, completion in
            guard let self, let item = store.bubbles.first(where: { $0.id == id }),
                  let owner = canonicalBubbleChat(item.chatKey), displayedChat == owner else {
                completion(false)
                return
            }
            let generation = refreshGeneration
            host.perform({ canonicalBubbleChat($0.currentChatKey()) == owner }) { [weak self] allowed in
                guard let self, refreshGeneration == generation, displayedChat == owner, !isHidden,
                      NSWorkspace.shared.frontmostApplication?.bundleIdentifier == hostBundleID else {
                    completion(false)
                    return
                }
                completion(allowed)
                if !allowed { refresh() }
            }
        }
        panel.onCancelLink = { [weak self] in self?.finishLinkRequest() }
        shortcut = SaveShortcut { [weak self] in
            DispatchQueue.main.async { self?.saveDraft() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(workspaceChanged), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(workspaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer?.tolerance = 0.1
        healthLog.notice("Started. Accessibility granted: \(AXIsProcessTrusted(), privacy: .public)")
        refresh()
    }

    private func reportHealth(_ observation: ShelfObservation, editor: Bool, chat: String?, visibleCount: Int) {
        let status = "Accessibility=\(observation.trusted) composer=\(editor) chatIdentified=\(chat != nil) identitySource=\(observation.source) visibleBubbles=\(visibleCount)"
        if status != lastHealth {
            healthLog.notice("\(status, privacy: .public)")
            lastHealth = status
        }
    }

    private func currentChat() -> String? {
        host.read { canonicalBubbleChat($0.currentChatKey()) }
    }

    private func canUseBubble(_ id: UUID) -> Bool {
        guard let chat = currentChat(),
              let item = store.bubbles.first(where: { $0.id == id }),
              canonicalBubbleChat(item.chatKey) == chat else {
            refresh()
            return false
        }
        return true
    }

    @objc private func workspaceChanged() {
        if observingPID != nil {
            refreshGeneration += 1
            observingPID = nil
            displayedChat = nil
            host.reset()
            panel.hide()
        }
        refresh()
    }

    @objc private func refresh() {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier == hostBundleID, !front.isHidden, !isHidden else {
            if observingPID != nil {
                observingPID = nil
                refreshGeneration += 1
                displayedChat = nil
                host.reset()
            }
            if linkRequest != nil { finishLinkRequest() }
            shortcut?.setActive(false)
            panel.hide()
            return
        }
        shortcut.setActive(true)
        let pid = front.processIdentifier
        if observingPID != pid {
            observingPID = pid
            refreshGeneration += 1
        }
        guard !refreshPending else { return }
        refreshPending = true
        let generation = refreshGeneration
        let keys = Set(store.bubbles.compactMap { canonicalBubbleChat($0.chatKey) })
        host.observe(savedKeys: keys) { [weak self] observation in
            guard let self else { return }
            refreshPending = false
            guard generation == refreshGeneration, !isHidden,
                  let active = NSWorkspace.shared.frontmostApplication,
                  active.bundleIdentifier == hostBundleID, active.processIdentifier == pid,
                  !active.isHidden else {
                refresh()
                return
            }
            updateShelf(with: observation, front: active)
        }
    }

    private func updateShelf(with observation: ShelfObservation, front: NSRunningApplication) {
        let chat = canonicalBubbleChat(observation.chatKey)
        displayedChat = chat
        let visible = store.visible(in: chat)
        if let geometry = observation.placement {
            reportHealth(observation, editor: true, chat: chat, visibleCount: visible.count)
            panel.setChatIdentified(chat != nil)
            panel.show(bubbles: visible, anchor: geometry.anchor, screen: geometry.screen)
            return
        }
        // Window geometry is enough for manual placement. No screenshot or title is collected.
        guard !front.isHidden, let window = visibleHostWindow(of: front) ?? NSScreen.main?.visibleFrame,
              let display = NSScreen.screens.max(by: {
                  $0.frame.intersection(window).area < $1.frame.intersection(window).area
              }) else {
            panel.hide()
            return
        }
        let railWidth: CGFloat = min(580, window.width * 0.58)
        let trailing: CGFloat = min(window.maxX - 55, window.midX + railWidth * 0.54)
        let estimate = NSRect(x: trailing - railWidth, y: window.minY + 26, width: railWidth, height: 66)
        reportHealth(observation, editor: false, chat: chat, visibleCount: visible.count)
        panel.setChatIdentified(chat != nil, accessibilityEnabled: observation.trusted)
        panel.show(bubbles: visible, anchor: estimate, screen: display.visibleFrame, realAnchor: false)
    }

    // AX references in these immutable results go straight back to the host queue.
    private enum DraftRead: @unchecked Sendable {
        case captured(CodexSurface, String)
        case link(CodexLinkContext, String?)
        case choices(String?), changed, failure(String)
    }

    @objc private func saveDraft() {
        guard !savingDraft else { return }
        savingDraft = true
        let generation = refreshGeneration
        let intendedChat = displayedChat
        host.perform({ host -> DraftRead in
            guard let surface = host.current() else { return .choices(nil) }
            guard let chat = canonicalBubbleChat(surface.chatKey) else {
                guard let context = host.linkContext(for: surface) else { return .changed }
                do { return .link(context, try host.draftForLink(in: context)) }
                catch CaptureError.empty { return .link(context, nil) }
                catch { return .failure(error.localizedDescription) }
            }
            guard intendedChat == nil || intendedChat == chat else { return .changed }
            do {
                let text = try host.capture(in: surface)
                guard canonicalBubbleChat(host.currentChatKey()) == chat else { return .changed }
                return .captured(surface, text)
            } catch { return .choices(error.localizedDescription) }
        }) { [weak self] outcome in
            guard let self else { return }
            savingDraft = false
            guard generation == refreshGeneration,
                  NSWorkspace.shared.frontmostApplication?.bundleIdentifier == hostBundleID else { return }
            switch outcome {
            case .captured(let surface, let text):
                guard persist(text, in: surface.chatKey) else { return }
                // Clearing occurs only after a durable save. The worker rechecks the
                // original editor, chat and text even if another edit arrived meanwhile.
                host.clearDraft(text, in: surface) { [weak self] cleared in
                    if !cleared { self?.lastStatus = "Saved. The original draft is still in the composer." }
                }
            case .link(let context, let text):
                beginLinkRequest(text.map(LinkAction.currentDraft) ?? .show, in: context)
            case .choices(let message):
                if let message { lastStatus = message }
                showCaptureChoices()
            case .changed: explainUnknownChat()
            case .failure(let message): showError(message)
            }
        }
    }

    @discardableResult
    private func saveText(_ text: String) -> Bool {
        guard let chat = currentChat() else { return beginLinkRequest(.selectedText(text)) }
        return persist(text, in: chat)
    }

    private func persist(_ text: String, in chat: String) -> Bool {
        do {
            try store.save(text, in: chat)
            lastStatus = nil
            refresh()
            return true
        } catch {
            showError("Couldn’t save the bubble. " + error.localizedDescription)
            return false
        }
    }

    private func removeBubble(_ id: UUID) {
        guard canUseBubble(id), let item = store.bubbles.first(where: { $0.id == id }) else { return }
        do {
            try store.remove(id)
            pendingRemoval = item
            lastStatus = "Removed. Undo is available in the menu bar."
            refresh()
        } catch { showError(error.localizedDescription) }
    }

    @objc private func undoRemoval() {
        guard let item = pendingRemoval, let chat = currentChat(), chat == canonicalBubbleChat(item.chatKey) else { return }
        do {
            try store.restore(item)
            pendingRemoval = nil
            lastStatus = "Bubble restored."
            refresh()
        } catch { showError(error.localizedDescription) }
    }

    private struct Assignment {
        let id: UUID
        let chat: String?
    }

    @objc private func assignEarlierBubble(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? Assignment else { return }
        guard let chat = choice.chat else {
            beginLinkRequest(.assignEarlier(choice.id))
            return
        }
        guard currentChat() == chat else {
            explainUnknownChat()
            return
        }
        do {
            try store.assign(choice.id, to: chat)
            lastStatus = "Moved the earlier bubble to this chat."
            refresh()
        } catch { showError(error.localizedDescription) }
    }

    private func explainUnknownChat() {
        let message = AXIsProcessTrusted()
            ? "Click in the prompt field of the local Codex chat where you want this bubble, then click Save."
            : "To capture the draft in one click, turn on Composer Bubbles in System Settings → Privacy & Security → Accessibility."
        showError(message)
    }

    @objc private func linkThisChat() {
        beginLinkRequest(.show)
    }

    @discardableResult
    private func beginLinkRequest(_ action: LinkAction, in existing: CodexLinkContext? = nil) -> Bool {
        finishLinkRequest()
        guard let context = existing ?? host.read({ $0.linkContext() }) else { explainUnknownChat(); return false }
        let request = LinkRequest(context: context, initialCopy: NSPasteboard.general.changeCount,
                                  action: action, until: Date().addingTimeInterval(50))
        let verb: String
        switch action {
        case .show: verb = "show its saved bubbles"
        case .currentDraft: verb = "save this draft"
        case .selectedText: verb = "save the selected text here"
        case .assignEarlier: verb = "move the earlier bubble here"
        }
        panel.showLinkPrompt("Press ⌘⌥L in this chat to " + verb + ". This is Codex’s Copy chat deep link shortcut.")
        linkRequest = request
        let requestID = request.id
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkRequestedLink(requestID) }
        }
        linkTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        return true
    }

    private func finishLinkRequest() {
        linkTimer?.invalidate()
        linkTimer = nil
        linkRequest = nil
        panel.finishLinkPrompt()
    }

    private func checkRequestedLink(_ id: UUID) {
        guard let request = linkRequest, request.id == id else { return }
        guard Date() < request.until, host.read({ $0.inLinkWindow(request.context) }) else {
            finishLinkRequest()
            return
        }
        // Read a new copy only during the user's explicit linking gesture.
        // The clipboard remains under the user's control throughout.
        let board = NSPasteboard.general
        let generation = board.changeCount
        guard generation != request.initialCopy,
              let string = board.string(forType: .string),
              board.changeCount == generation,
              let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              let chat = CodexHost.copiedChatKey(url) else { return }
        finishLinkRequest()
        guard let scope = host.read({ $0.acceptCopiedChat(chat, for: request.context) }) else {
            showError("The chat changed while linking. Click Save in the chat you want to use.")
            return
        }
        do {
            switch request.action {
            case .show: break
            case .assignEarlier(let id):
                try store.assign(id, to: chat)
            case .selectedText(let text):
                try store.save(text, in: chat)
            case .currentDraft(let original):
                let text = try host.read { try $0.draftForLink(in: request.context) }
                guard original == text, let confirmed = host.read({ $0.acceptCopiedChat(chat, for: request.context) }) else {
                    showError("The draft or chat changed. Click Save again to keep the current draft.")
                    return
                }
                try store.save(text, in: chat)
                if confirmed == .currentChat, let surface = host.read({ $0.current() }), surface.chatKey == chat {
                    _ = host.read { $0.clearIfUnchanged(text, in: surface) }
                }
            }
        } catch { showError(error.localizedDescription); return }
        lastStatus = nil
        refresh()
        if scope == .singleAction, host.read({ $0.inLinkWindow(request.context) }), currentChat() == nil {
            panel.showLinkedBubbles(store.visible(in: chat))
        }
    }

    private func menuItem(_ title: String, _ action: Selector? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func showCaptureChoices() {
        let menu = NSMenu()
        menu.addItem(menuItem("Press Tab in Codex to accept a prediction."))
        menu.addItem(menuItem("Drag selected text onto Save, or copy it and use"))
        menu.addItem(menuItem("Save Copied Text as Bubble", #selector(pasteBubble)))
        if !AXIsProcessTrusted() {
            menu.addItem(.separator())
            menu.addItem(menuItem("Enable Direct Draft Capture…", #selector(enableCapture)))
        }
        if displayedChat == nil {
            menu.addItem(menuItem("Link This Chat…", #selector(linkThisChat)))
        }
        menu.addItem(.separator())
        menu.addItem(menuItem("Settings…", #selector(openSettings)))
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func openSettings() {
        settings.present()
    }

    @objc private func viewReleases() {
        let releases = URL(string: "https://github.com/noestradamus/codex-composer-bubbles/releases")!
        if !NSWorkspace.shared.open(releases) {
            showError("Couldn't open the GitHub releases page in your browser.")
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    @objc private func pasteBubble() {
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showError("Copy the suggestion text in Codex first.")
            return
        }
        saveText(text)
    }

    @objc private func enableCapture() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }

    @objc private func toggleShelf() {
        defaults.set(!isHidden, forKey: "hideShelf")
        refresh()
    }

    @objc private func resetPosition() {
        defaults.removeObject(forKey: placementKey)
        defaults.removeObject(forKey: "shelfX")
        defaults.removeObject(forKey: "shelfY")
        panel.resetPlacement()
        refresh()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        menu.addItem(menuItem(version.map { "Composer Bubbles " + $0 } ?? "Composer Bubbles"))
        let chat = displayedChat
        if let chat {
            let count = store.visible(in: chat).count
            menu.addItem(menuItem("Current chat · " + String(count) + (count == 1 ? " bubble" : " bubbles")))
        } else {
            menu.addItem(menuItem("Use Link This Chat to open its bubbles"))
        }
        if let lastStatus { menu.addItem(menuItem(lastStatus)) }
        menu.addItem(.separator())
        let settingsItem = menuItem("Settings…", #selector(openSettings))
        settingsItem.keyEquivalent = ","
        menu.addItem(settingsItem)
        menu.addItem(menuItem("Save Copied Text as Bubble", #selector(pasteBubble)))
        if chat == nil {
            menu.addItem(menuItem("Link This Chat…", #selector(linkThisChat)))
        }
        if !AXIsProcessTrusted() {
            menu.addItem(menuItem("Enable Direct Draft Capture…", #selector(enableCapture)))
        } else {
            menu.addItem(menuItem("Save Draft in Codex    ⌥⇧⌘B"))
        }
        if !store.unassigned.isEmpty {
            let parent = menuItem("Move Earlier Bubble to This Chat")
            let choices = NSMenu()
            for bubble in store.unassigned {
                let label = bubble.text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                let title = label.count > 64 ? String(label.prefix(63)) + "…" : label
                let item = menuItem(title, #selector(assignEarlierBubble(_:)))
                item.toolTip = bubble.text
                item.representedObject = Assignment(id: bubble.id, chat: chat)
                choices.addItem(item)
            }
            parent.submenu = choices
            menu.addItem(parent)
        }
        if let chat, let item = pendingRemoval, canonicalBubbleChat(item.chatKey) == chat {
            menu.addItem(menuItem("Undo Remove Bubble", #selector(undoRemoval)))
        }
        menu.addItem(.separator())
        menu.addItem(menuItem(isHidden ? "Show Bubbles in Codex" : "Hide Bubbles in Codex", #selector(toggleShelf)))
        menu.addItem(menuItem("Reset Bubble Position", #selector(resetPosition)))
        menu.addItem(.separator())
        menu.addItem(menuItem("View Releases on GitHub…", #selector(viewReleases)))
        let quit = NSMenuItem(title: "Quit Composer Bubbles", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    private func showError(_ message: String) {
        lastStatus = message
        let alert = NSAlert()
        alert.messageText = "Composer Bubbles"
        alert.informativeText = message
        alert.runModal()
    }
}

private extension CGRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}
