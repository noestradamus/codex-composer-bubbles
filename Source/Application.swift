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

@MainActor
private final class WindowShelf {
    let panel: BubblePanelController
    var chat: String?
    var savingDraft = false
    var lastHealth: String?

    init(panel: BubblePanelController) { self.panel = panel }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var shelves: [ShelfWindowID: WindowShelf] = [:]
    private var focusedShelfID: ShelfWindowID?
    private lazy var placements = WindowShelfPlacements(defaults: defaults)
    private let host = HostAccess()
    private var observingPID: pid_t?
    private var refreshGeneration = 0
    private var refreshPending = false
    private var store: BubbleStore!
    private var shortcut: SaveShortcut!
    private var status: NSStatusItem!
    private var timer: Timer?
    private var lastStatus: String?
    private let healthLog = Logger(subsystem: "local.composerbubbles.mac", category: "capture")
    private let defaults = UserDefaults.standard
    private lazy var settings = BubbleSettingsController(
        defaults: defaults,
        onChange: { [weak self] style in self?.shelves.values.forEach { $0.panel.setStyle(style) } },
        onSaveStyleChange: { [weak self] style in self?.shelves.values.forEach { $0.panel.setSaveStyle(style) } }
    )
    private var isHidden: Bool { defaults.bool(forKey: "hideShelf") }
    private var pendingRemoval: SavedBubble?
    private enum LinkAction {
        case show, currentDraft(String), selectedText(String), assignEarlier(UUID)
    }
    private struct LinkRequest {
        let id = UUID()
        let windowID: ShelfWindowID
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
        shortcut = SaveShortcut { [weak self] in
            DispatchQueue.main.async {
                guard let self, let id = self.host.focusedWindowID() else { return }
                self.saveDraft(in: id)
            }
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

    private func makeShelf(for id: ShelfWindowID) -> WindowShelf {
        let panel = BubblePanelController(windowID: id, placements: placements)
        let shelf = WindowShelf(panel: panel)
        panel.setStyle(.load(from: defaults))
        panel.setSaveStyle(.load(from: defaults))
        panel.onSettings = { [weak self] in self?.openSettings() }
        panel.onSave = { [weak self] in self?.saveDraft(in: id) }
        panel.onDropText = { [weak self] text in self?.saveText(text, in: id) ?? false }
        panel.onRemove = { [weak self] bubble in self?.removeBubble(bubble, in: id) }
        panel.canUseBubble = { [weak self] bubble in self?.canUseBubble(bubble, in: id) ?? false }
        panel.verifyPreview = { [weak self, weak shelf] bubble, completion in
            guard let self, let shelf, self.shelves[id] === shelf,
                  let item = self.store.bubbles.first(where: { $0.id == bubble }),
                  let owner = canonicalBubbleChat(item.chatKey), shelf.chat == owner else {
                completion(false)
                return
            }
            let generation = self.refreshGeneration
            self.host.perform(in: id, { canonicalBubbleChat($0.currentChatKey()) == owner }) { [weak self, weak shelf] allowed in
                guard let self, let shelf, self.shelves[id] === shelf, self.refreshGeneration == generation,
                      shelf.chat == owner, !self.isHidden,
                      NSWorkspace.shared.frontmostApplication?.bundleIdentifier == self.hostBundleID else {
                    completion(false)
                    return
                }
                completion(allowed == true)
                if allowed != true { self.refresh() }
            }
        }
        panel.onCancelLink = { [weak self] in
            if self?.linkRequest?.windowID == id { self?.finishLinkRequest() }
        }
        return shelf
    }

    private func currentChat(in windowID: ShelfWindowID) -> String? {
        host.read(in: windowID) { canonicalBubbleChat($0.currentChatKey()) } ?? nil
    }

    private func canUseBubble(_ id: UUID, in windowID: ShelfWindowID) -> Bool {
        guard let shelf = shelves[windowID], let chat = shelf.chat,
              let item = store.bubbles.first(where: { $0.id == id }),
              canonicalBubbleChat(item.chatKey) == chat, currentChat(in: windowID) == chat else {
            refresh()
            return false
        }
        return true
    }

    private func hideShelves() {
        for shelf in shelves.values {
            shelf.chat = nil
            shelf.panel.hide()
        }
    }

    @objc private func workspaceChanged() {
        if observingPID != nil {
            refreshGeneration += 1
            observingPID = nil
            host.reset()
            hideShelves()
        }
        refresh()
    }

    @objc private func refresh() {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier == hostBundleID, !front.isHidden, !isHidden else {
            if observingPID != nil {
                observingPID = nil
                refreshGeneration += 1
                host.reset()
            }
            if linkRequest != nil { finishLinkRequest() }
            shortcut?.setActive(false)
            hideShelves()
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
        var keys = Set(store.bubbles.compactMap { canonicalBubbleChat($0.chatKey) })
        // A title-identified chat must remain identifiable after its last bubble is removed.
        if let undoOwner = canonicalBubbleChat(pendingRemoval?.chatKey) { keys.insert(undoOwner) }
        host.observeWindows(savedKeys: keys) { [weak self] observations, liveWindowIDs in
            guard let self else { return }
            refreshPending = false
            guard generation == refreshGeneration, !isHidden,
                  let active = NSWorkspace.shared.frontmostApplication,
                  active.bundleIdentifier == hostBundleID, active.processIdentifier == pid,
                  !active.isHidden else {
                refresh()
                return
            }
            if let liveWindowIDs { placements.retain(liveWindowIDs: liveWindowIDs, process: pid) }
            updateShelves(observations)
        }
    }

    private func updateShelves(_ observations: [WindowShelfObservation]) {
        focusedShelfID = observations.first(where: \.focused)?.id
        let visibleIDs = Set(observations.map(\.id))
        for id in shelves.keys.filter({ !visibleIDs.contains($0) }) {
            if linkRequest?.windowID == id { finishLinkRequest() }
            shelves.removeValue(forKey: id)?.panel.retire()
        }
        let screens = NSScreen.screens.map { (frame: $0.frame, visibleFrame: $0.visibleFrame) }
        guard let primary = screens.first else { hideShelves(); return }
        func appKitFrame(_ quartz: CGRect) -> CGRect {
            CGRect(x: quartz.minX, y: primary.frame.maxY - quartz.maxY, width: quartz.width, height: quartz.height)
        }
        var occupied: [CGRect] = []
        // A focus change can reorder the window list. Keep placement order stable.
        for window in observations.sorted(by: { $0.id < $1.id }) {
            let observation = window.observation
            let shelf = shelves[window.id] ?? makeShelf(for: window.id)
            shelves[window.id] = shelf
            shelf.chat = canonicalBubbleChat(observation.chatKey)
            guard let raw = observation.windowQuartzFrame,
                  let geometry = observation.placement(on: screens, fallbackQuartzWindow: nil, fallbackScreen: nil) else {
                shelf.panel.hide()
                continue
            }
            let bubbles = store.visible(in: shelf.chat)
            let health = "Accessibility=\(observation.trusted) composer=\(geometry.realAnchor) chatIdentified=\(shelf.chat != nil) identitySource=\(observation.source) visibleBubbles=\(bubbles.count)"
            if health != shelf.lastHealth {
                shelf.lastHealth = health
                healthLog.notice("Window \(window.id, privacy: .public) \(health, privacy: .public)")
            }
            shelf.panel.setChatIdentified(shelf.chat != nil, accessibilityEnabled: observation.trusted)
            shelf.panel.show(bubbles: bubbles, anchor: geometry.anchor, screen: geometry.screen,
                             realAnchor: geometry.realAnchor, hostFrame: appKitFrame(raw), avoiding: occupied,
                             occludedBy: window.occludingQuartzFrames.map(appKitFrame))
            if let panelFrame = shelf.panel.frame { occupied.append(panelFrame) }
        }
    }

    // AX references in these immutable results go straight back to the host queue.
    private enum DraftRead: @unchecked Sendable {
        case captured(chat: String, text: String)
        case link(CodexLinkContext, String?)
        case choices(String?), changed, failure(String)
    }

    private func saveDraft(in windowID: ShelfWindowID) {
        let shelf = shelves[windowID] ?? makeShelf(for: windowID)
        shelves[windowID] = shelf
        guard !shelf.savingDraft else { return }
        shelf.savingDraft = true
        let generation = refreshGeneration
        let intendedChat = shelf.chat
        host.perform(in: windowID, activate: true, { host -> DraftRead in
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
                return .captured(chat: chat, text: text)
            } catch { return .choices(error.localizedDescription) }
        }) { [weak self, weak shelf] outcome in
            guard let self, let shelf else { return }
            shelf.savingDraft = false
            guard shelves[windowID] === shelf, !isHidden,
                  NSWorkspace.shared.frontmostApplication?.bundleIdentifier == hostBundleID else { return }
            // Raising a visible full-screen Codex window can change the active Space.
            if generation != refreshGeneration && host.focusedWindowID() != windowID { return }
            switch outcome ?? .choices(nil) {
            case .captured(let chat, let text):
                // Accessibility cannot clear a specific revision of the editor.
                if saveAndRefresh(text, in: chat, from: windowID) { lastStatus = "Saved a copy of the draft." }
            case .link(let context, let text):
                beginLinkRequest(text.map(LinkAction.currentDraft) ?? .show, for: windowID, context: context)
            case .choices(let message):
                if let message { lastStatus = message }
                showCaptureChoices(in: windowID)
            case .changed: explainUnknownChat()
            case .failure(let message): showError(message)
            }
        }
    }

    @discardableResult
    private func saveText(_ text: String, in windowID: ShelfWindowID) -> Bool {
        guard let chat = currentChat(in: windowID) else { return beginLinkRequest(.selectedText(text), for: windowID) }
        if let shown = shelves[windowID]?.chat, shown != chat { refresh(); return false }
        return saveAndRefresh(text, in: chat, from: windowID)
    }

    private func persist(_ text: String, in chat: String, from windowID: ShelfWindowID) throws {
        try store.save(text, in: chat)
        shelves[windowID]?.panel.showSaveConfirmation()
    }

    private func saveAndRefresh(_ text: String, in chat: String, from windowID: ShelfWindowID) -> Bool {
        do {
            try persist(text, in: chat, from: windowID)
            lastStatus = nil
            refresh()
            return true
        } catch {
            showError("Couldn’t save the bubble. " + error.localizedDescription)
            return false
        }
    }

    private func removeBubble(_ id: UUID, in windowID: ShelfWindowID) {
        guard canUseBubble(id, in: windowID), let chat = shelves[windowID]?.chat else { return }
        removeStoredBubble(id, from: chat)
    }

    @discardableResult
    private func removeStoredBubble(_ id: UUID, from chat: String) -> Bool {
        do {
            guard let item = try store.remove(id, from: chat) else { refresh(); return false }
            pendingRemoval = item
            lastStatus = "Removed. Undo is available in this chat."
            refresh()
            return true
        } catch { showError(error.localizedDescription); return false }
    }

    @objc private func undoRemoval(_ sender: NSMenuItem) {
        guard let windowID = sender.representedObject as? ShelfWindowID, let item = pendingRemoval,
              let chat = currentChat(in: windowID) else { return }
        restoreRemovedBubble(item.id, in: chat)
    }

    @discardableResult
    private func restoreRemovedBubble(_ id: UUID, in chat: String) -> SavedBubble? {
        guard let item = pendingRemoval, item.id == id, canonicalBubbleChat(item.chatKey) == chat else { return nil }
        do {
            let restored = try store.restore(item)
            pendingRemoval = nil
            lastStatus = "Bubble restored."
            refresh()
            return restored
        } catch { showError(error.localizedDescription); return nil }
    }

    private struct Assignment {
        let id: UUID
        let windowID: ShelfWindowID
        let chat: String?
    }

    @objc private func assignEarlierBubble(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? Assignment else { return }
        guard let chat = choice.chat else {
            beginLinkRequest(.assignEarlier(choice.id), for: choice.windowID)
            return
        }
        guard currentChat(in: choice.windowID) == chat else {
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

    @objc private func linkThisChat(_ sender: NSMenuItem) {
        guard let windowID = sender.representedObject as? ShelfWindowID else { return }
        beginLinkRequest(.show, for: windowID)
    }

    @discardableResult
    private func beginLinkRequest(_ action: LinkAction, for windowID: ShelfWindowID, context existing: CodexLinkContext? = nil) -> Bool {
        finishLinkRequest()
        guard let panel = shelves[windowID]?.panel,
              let context = host.read(in: windowID, activate: true, { host -> CodexLinkContext? in
                  if let existing { return host.inLinkWindow(existing) ? existing : nil }
                  return host.linkContext()
              }) ?? nil else { explainUnknownChat(); return false }
        let request = LinkRequest(windowID: windowID, context: context, initialCopy: NSPasteboard.general.changeCount,
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
        let windowID = linkRequest?.windowID
        linkRequest = nil
        if let windowID { shelves[windowID]?.panel.finishLinkPrompt() }
    }

    private func checkRequestedLink(_ id: UUID) {
        guard let request = linkRequest, request.id == id else { return }
        let windowID = request.windowID
        guard Date() < request.until, host.read(in: windowID, { $0.inLinkWindow(request.context) }) == true else {
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
        let scope: LinkScope
        do {
            let accepted = try host.read(in: windowID) { host -> LinkScope? in
                if case .currentDraft(let original) = request.action {
                    guard let text = try? host.draftForLink(in: request.context),
                          original.utf8.elementsEqual(text.utf8) else { throw CaptureError.changed }
                }
                return host.acceptCopiedChat(chat, for: request.context)
            }
            guard let accepted = accepted ?? nil else {
                showError("The chat changed while linking. Click Save in the chat you want to use.")
                return
            }
            scope = accepted
            switch request.action {
            case .show: break
            case .assignEarlier(let id):
                try store.assign(id, to: chat)
            case .selectedText(let text), .currentDraft(let text):
                try persist(text, in: chat, from: windowID)
            }
        } catch CaptureError.changed {
            showError("The draft or chat changed. Click Save again to keep the current draft.")
            return
        } catch { showError(error.localizedDescription); return }
        lastStatus = nil
        refresh()
        if scope == .singleAction, host.read(in: windowID, { $0.inLinkWindow(request.context) }) == true,
           currentChat(in: windowID) == nil, let shelf = shelves[windowID] {
            let undoID = canonicalBubbleChat(pendingRemoval?.chatKey) == chat ? pendingRemoval?.id : nil
            shelf.panel.showLinkedBubbles(store.visible(in: chat), undoID: undoID, onRemove: { [weak self, weak shelf] id in
                guard let self, let shelf, self.shelves[windowID] === shelf else { return false }
                return self.removeStoredBubble(id, from: chat)
            }, onUndo: { [weak self, weak shelf] id in
                guard let self, let shelf, self.shelves[windowID] === shelf else { return nil }
                return self.restoreRemovedBubble(id, in: chat)
            })
        }
    }

    private func menuItem(_ title: String, _ action: Selector? = nil, window: ShelfWindowID? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = window
        return item
    }

    private func showCaptureChoices(in windowID: ShelfWindowID) {
        let menu = NSMenu()
        menu.addItem(menuItem("Press Tab in Codex to accept a prediction."))
        menu.addItem(menuItem("Drag selected text onto Save, or copy it and use"))
        menu.addItem(menuItem("Save Copied Text as Bubble", #selector(pasteBubble(_:)), window: windowID))
        if !AXIsProcessTrusted() {
            menu.addItem(.separator())
            menu.addItem(menuItem("Enable Direct Draft Capture…", #selector(enableCapture)))
        }
        if shelves[windowID]?.chat == nil {
            menu.addItem(menuItem("Link This Chat…", #selector(linkThisChat(_:)), window: windowID))
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

    @objc private func pasteBubble(_ sender: NSMenuItem) {
        guard let windowID = sender.representedObject as? ShelfWindowID else { return }
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showError("Copy the suggestion text in Codex first.")
            return
        }
        saveText(text, in: windowID)
    }

    @objc private func enableCapture() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }

    @objc private func toggleShelf() {
        defaults.set(!isHidden, forKey: "hideShelf")
        refresh()
    }

    @objc private func resetPosition(_ sender: NSMenuItem) {
        guard let windowID = sender.representedObject as? ShelfWindowID else { return }
        shelves[windowID]?.panel.resetPlacement()
        refresh()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        menu.addItem(menuItem(version.map { "Composer Bubbles " + $0 } ?? "Composer Bubbles"))
        let windowID = host.focusedWindowID() ?? focusedShelfID
        let chat = windowID.flatMap { shelves[$0]?.chat }
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
        if let windowID {
            menu.addItem(menuItem("Save Copied Text as Bubble", #selector(pasteBubble(_:)), window: windowID))
            if chat == nil {
                menu.addItem(menuItem("Link This Chat…", #selector(linkThisChat(_:)), window: windowID))
            }
        }
        if !AXIsProcessTrusted() {
            menu.addItem(menuItem("Enable Direct Draft Capture…", #selector(enableCapture)))
        } else {
            menu.addItem(menuItem("Save Draft in Codex    ⌥⇧⌘B"))
        }
        if let windowID, !store.unassigned.isEmpty {
            let parent = menuItem("Move Earlier Bubble to This Chat")
            let choices = NSMenu()
            for bubble in store.unassigned {
                let label = bubble.text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                let title = label.count > 64 ? String(label.prefix(63)) + "…" : label
                let item = menuItem(title, #selector(assignEarlierBubble(_:)))
                item.toolTip = bubble.text
                item.representedObject = Assignment(id: bubble.id, windowID: windowID, chat: chat)
                choices.addItem(item)
            }
            parent.submenu = choices
            menu.addItem(parent)
        }
        if let chat, let item = pendingRemoval, canonicalBubbleChat(item.chatKey) == chat {
            menu.addItem(menuItem("Undo Remove Bubble", #selector(undoRemoval(_:)), window: windowID))
        }
        menu.addItem(.separator())
        menu.addItem(menuItem(isHidden ? "Show Bubbles in Codex" : "Hide Bubbles in Codex", #selector(toggleShelf)))
        if let windowID {
            menu.addItem(menuItem("Reset Bubble Position", #selector(resetPosition(_:)), window: windowID))
        }
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
