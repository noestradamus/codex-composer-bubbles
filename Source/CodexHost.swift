import AppKit
import ApplicationServices

/// Positions returned by Accessibility are in global Quartz coordinates.
// Accessibility reads are confined to the HostAccess queue.
struct CodexSurface: @unchecked Sendable {
    fileprivate let windowID: ShelfWindowID
    fileprivate let quartzFrame: CGRect
    let chatKey: String
    fileprivate let editor: AXUIElement
    fileprivate let window: AXUIElement
    fileprivate let process: pid_t
}

struct WindowShelfObservation: Sendable {
    let id: ShelfWindowID
    let focused: Bool
    let observation: ShelfObservation
    let occludingQuartzFrames: [CGRect]

    init(id: ShelfWindowID, focused: Bool, observation: ShelfObservation, occludingQuartzFrames: [CGRect] = []) {
        self.id = id
        self.focused = focused
        self.observation = observation
        self.occludingQuartzFrames = occludingQuartzFrames
    }
}

private struct WindowTarget {
    let id: ShelfWindowID
    let pid: pid_t
    let app: AXUIElement
    let window: AXUIElement?
    let frame: CGRect
    let focused: Bool
    let occludingQuartzFrames: [CGRect]
}

/// The label is an extra invalidation check for a recycled AX element. It is
/// never used as an identity, searched in a database, logged, or persisted.
struct CodexRowContext {
    fileprivate let window: AXUIElement
    fileprivate let navigation: AXUIElement
    fileprivate let row: AXUIElement
    fileprivate let label: [String]
    fileprivate func sameNode(_ other: Self) -> Bool {
        CFEqual(window, other.window) && CFEqual(navigation, other.navigation) && CFEqual(row, other.row)
    }
    fileprivate func matches(_ other: Self) -> Bool { sameNode(other) && label == other.label }
}

enum CaptureError: LocalizedError {
    case changed, empty, unavailable

    var errorDescription: String? {
        switch self {
        case .changed: return "Focus the Codex composer and try saving again."
        case .empty: return "Press Tab on the suggestion to put it in the draft, then save it."
        case .unavailable: return "Codex did not expose a plain-text draft. Select the suggestion text to save it manually."
        }
    }
}

/// Only the mounted primary tab chooses a candidate. This index translates
/// an opaque Codex client alias to its eventual canonical conversation ID.
struct CodexAliasIndex {
    private struct Field: CodingKey {
        var stringValue: String
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { return nil }
    }

    private struct Index: Decodable {
        var aliases: [String: Set<String>] = [:]
        init(from decoder: Decoder) throws {
            let root = try decoder.container(keyedBy: Field.self)
            for field in root.allKeys {
                let name = field.stringValue
                guard name == "electron-persisted-atom-state" || name.hasPrefix("electron-owner-atoms:"),
                      let bucket = try? root.nestedContainer(keyedBy: Field.self, forKey: field) else { continue }
                let prefix = "thread-client-id-v1:"
                for entry in bucket.allKeys where entry.stringValue.hasPrefix(prefix) {
                    guard let client = try? bucket.decode(String.self, forKey: entry),
                          let alias = CodexAliasIndex.canonicalAlias(client),
                          let scope = String(entry.stringValue.dropFirst(prefix.count)).removingPercentEncoding
                    else { continue }
                    let key: String
                    if scope.hasPrefix("local:"), let id = UUID(uuidString: String(scope.dropFirst(6))) {
                        key = "thread:" + id.uuidString.lowercased()
                    } else {
                        // An alias claimed by another scope must never resolve locally.
                        key = "other"
                    }
                    aliases[alias, default: []].insert(key)
                }
            }
        }
    }

    private struct Version: Equatable {
        let modified: Date?
        let fileID: UInt64?
        let bytes: Int
    }
    private var version: Version?
    private var aliases: [String: Set<String>] = [:]
    private let url: URL

    init(url: URL? = nil) {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"]
            .flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        self.url = url ?? home.appendingPathComponent(".codex-global-state.json")
    }

    static func canonicalAlias(_ candidate: String) -> String? {
        let prefix = "client-new-thread:"
        guard candidate.hasPrefix(prefix),
              let id = UUID(uuidString: String(candidate.dropFirst(prefix.count))) else { return nil }
        return prefix + id.uuidString.lowercased()
    }

    mutating func keys(for candidate: String) -> Set<String> {
        guard let alias = Self.canonicalAlias(candidate),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber, size.intValue > 0, size.intValue <= 32 * 1024 * 1024 else {
            return []
        }
        let latest = Version(modified: attrs[.modificationDate] as? Date,
                             fileID: (attrs[.systemFileNumber] as? NSNumber)?.uint64Value, bytes: size.intValue)
        if version != latest {
            // Decode only the alias entries. Unrelated settings and draft
            // content are never decoded or retained by the index.
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  data.count == latest.bytes,
                  let index = try? JSONDecoder().decode(Index.self, from: data) else { return [] }
            version = latest
            aliases = index.aliases
        }
        return aliases[alias] ?? []
    }
}

private func attribute(_ item: AXUIElement, _ name: String) -> CFTypeRef? {
    var output: CFTypeRef?
    guard AXUIElementCopyAttributeValue(item, name as CFString, &output) == .success else { return nil }
    return output
}

private func element(_ item: AXUIElement, _ name: String) -> AXUIElement? {
    guard let result = attribute(item, name), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
    return (result as! AXUIElement)
}

private func frame(_ item: AXUIElement) -> CGRect? {
    guard let p = attribute(item, "AXPosition"), CFGetTypeID(p) == AXValueGetTypeID(),
          let s = attribute(item, "AXSize"), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var origin = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &origin),
          AXValueGetValue(s as! AXValue, .cgSize, &size),
          size.width > 0, size.height > 0 else { return nil }
    return CGRect(origin: origin, size: size)
}


/// Reads the host's accessibility controls and resolves visible client IDs. The pasteboard and key events
/// are deliberately not part of the automatic capture path.
final class CodexHost {
    private typealias FocusedWindow = (pid: pid_t, app: AXUIElement, window: AXUIElement)
    private let chatTitle = CodexChatTitle()
    private let selectedTab = CodexSelectedChatTab()
    private let hostID = "com.openai.codex"
    fileprivate var target: WindowTarget {
        didSet {
            if let window = target.window {
                knownWindow = window
                lastPairedAt = ProcessInfo.processInfo.systemUptime
            }
        }
    }
    /// Retain explicit link bindings if Chromium briefly omits its AX window
    /// while remounting. The saved handle is never used to authorize a read.
    fileprivate private(set) var knownWindow: AXUIElement?
    fileprivate private(set) var lastPairedAt: TimeInterval?
    private var last: CodexSurface?
    private var lastDiscovery = Date.distantPast
    private var selectedRow: CodexRowContext?
    private var rowBindings: [(context: CodexRowContext, key: String)] = []
    private var composerBindings: [(window: AXUIElement, editor: AXUIElement, button: AXUIElement, key: String)] = []
    private var observedKeys: Set<String> = []
    private var rowWindow: AXUIElement?
    private var currentRow: AXUIElement?
    private var navigation: AXUIElement?
    private var verifiedPrimaryIDs: Set<String> = []
    private var scannedAt = Date.distantPast
    private var aliasIndex = CodexAliasIndex()
    private var copiedPanelKeys: [String: String] = [:]
    private let titleCatalog: LocalChatCatalog
    var savedChatKeys = Set<String>()
    private(set) var identitySource = "unknown"
    private var titleObservation: (window: AXUIElement, editor: AXUIElement, key: String, since: TimeInterval)?
    private struct ConfirmedShelf {
        let window: AXUIElement
        let editor: AXUIElement?
        let key: String
        let panel: String?
        let row: CodexRowContext?
        let nativeTitle: Data?
    }
    private var confirmedShelf: ConfirmedShelf?
    /// A sidebar/panel switch can arrive one frame before the old composer is
    /// unmounted. Its old key cannot authorize the new selection by itself.
    private var departure: (old: ConfirmedShelf, changedPanel: Bool, changedRow: Bool)?
    func clearReturnObservation() {
        titleObservation = nil
        confirmedShelf = nil
        departure = nil
        last = nil
        lastDiscovery = .distantPast
    }
    private(set) var primaryScopeToken: String?
    private(set) var isForeignContext = false

    fileprivate init(target: WindowTarget, titleCatalog: LocalChatCatalog = LocalChatCatalog()) {
        self.target = target
        self.knownWindow = target.window
        if target.window != nil { lastPairedAt = ProcessInfo.processInfo.systemUptime }
        self.titleCatalog = titleCatalog
    }

    fileprivate func matches(_ other: WindowTarget) -> Bool {
        guard target.pid == other.pid else { return false }
        if let knownWindow, let window = other.window { return CFEqual(knownWindow, window) }
        return true
    }

    func current() -> CodexSurface? { current(freshScan: true) }

    private func current(freshScan: Bool) -> CodexSurface? {
        observe(focusedHostWindow(), freshScan: freshScan, forShelf: false).surface
    }

    func currentChatKey() -> String? { observe(addressedWindow(), freshScan: true, forShelf: false).key }

    /// Window geometry and chat identity must belong to the same focus snapshot.
    func shelfObservation() -> ShelfObservation {
        let reading = observe(addressedWindow(), freshScan: false, forShelf: true)
        return ShelfObservation(quartzFrame: reading.surface?.quartzFrame, windowQuartzFrame: reading.windowFrame ?? target.frame,
                                chatKey: reading.key, source: identitySource, trusted: AXIsProcessTrusted())
    }

    private func observe(_ focus: FocusedWindow?, freshScan: Bool, forShelf: Bool)
        -> (surface: CodexSurface?, key: String?, windowFrame: CGRect?) {
        identitySource = "unavailable"
        selectedRow = nil
        observedKeys = []
        primaryScopeToken = nil
        isForeignContext = false
        guard let (pid, app, window) = focus else {
            clearReturnObservation()
            return (nil, nil, nil)
        }
        if let previousWindow = confirmedShelf?.window ?? last?.window,
           !CFEqual(previousWindow, window) { clearReturnObservation() }
        let windowFrame = frame(window)
        var editor = element(app, "AXFocusedUIElement").flatMap(composerAncestor)
        if let candidate = editor, !belongs(candidate, to: window) { editor = nil }
        if editor == nil, let prior = last, prior.process == pid, CFEqual(prior.window, window),
           let windowFrame, let bounds = frame(prior.editor), bounds.intersects(windowFrame),
           belongs(prior.editor, to: window),
           isVisibleComposer(prior.editor, in: app, bounds: bounds) {
            editor = prior.editor
        }
        if editor == nil, let windowFrame,
           freshScan || confirmedShelf != nil || Date().timeIntervalSince(lastDiscovery) >= 1.2 {
            lastDiscovery = Date()
            editor = findVisibleComposer(in: app, window: window, windowFrame: windowFrame)
        }
        let key = currentChatKey(in: window, editor: editor, freshScan: freshScan, forShelf: forShelf)
        // A hit-test miss can simply mean the shelf or a popup covers the
        // editor. Keep its handle for rediscovery; every reuse hit-tests anew.
        guard let editor, let rawFrame = frame(editor), let windowFrame, rawFrame.intersects(windowFrame)
        else { return (nil, key, windowFrame) }
        let surface = CodexSurface(windowID: target.id, quartzFrame: rawFrame, chatKey: key ?? "unresolved",
                                   editor: editor, window: window, process: pid)
        last = surface
        return (surface, key, windowFrame)
    }

    func capture(in surface: CodexSurface) throws -> String {
        guard isCurrent(surface) else { throw CaptureError.changed }
        guard let text = readDraft(surface.editor), !text.contains("\u{fffc}") else {
            throw CaptureError.unavailable
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CaptureError.empty
        }
        return text
    }

    private func isCurrent(_ surface: CodexSurface) -> Bool {
        guard surface.chatKey.hasPrefix("thread:"), let now = current(freshScan: true) else { return false }
        return now.process == surface.process && now.windowID == surface.windowID && CFEqual(now.editor, surface.editor)
            && CFEqual(now.window, surface.window) && now.chatKey == surface.chatKey
    }

    private func readDraft(_ editor: AXUIElement) -> String? {
        if (attribute(editor, "AXNumberOfCharacters") as? NSNumber)?.intValue == 0 { return "" }
        return attribute(editor, "AXValue") as? String
    }

    private func composerAncestor(of node: AXUIElement) -> AXUIElement? {
        var candidate: AXUIElement? = node
        for _ in 0..<7 {
            guard let item = candidate else { return nil }
            if isComposer(item) { return item }
            if attribute(item, "AXRole") as? String == "AXWebArea" { return nil }
            candidate = element(item, "AXParent")
        }
        return nil
    }

    private func belongs(_ item: AXUIElement, to window: AXUIElement) -> Bool {
        guard let owner = element(item, "AXWindow") else { return false }
        return CFEqual(owner, window)
    }

    private func findVisibleComposer(in app: AXUIElement, window: AXUIElement, windowFrame: CGRect) -> AXUIElement? {
        let samples: [(CGFloat, CGFloat)] = [(0.64, 103), (0.48, 103), (0.72, 72),
                                              (0.57, 146), (0.36, 86), (0.61, 188)]
        for (fraction, distance) in samples {
            let x = Float(windowFrame.minX + windowFrame.width * fraction)
            let y = Float(windowFrame.maxY - distance)
            var hit: AXUIElement?
            if AXUIElementCopyElementAtPosition(app, x, y, &hit) == .success,
               let hit, let composer = composerAncestor(of: hit), belongs(composer, to: window) { return composer }
        }
        return nil
    }

    /// AX can retain a background tab's editor with its previous screen frame.
    /// Only reuse that handle if the host's hit-test lands inside it now.
    private func isVisibleComposer(_ editor: AXUIElement, in app: AXUIElement, bounds: CGRect) -> Bool {
        guard bounds.width > 0, bounds.height > 0 else { return false }
        for fraction in [0.38, 0.7] {
            var hit: AXUIElement?
            if AXUIElementCopyElementAtPosition(app, Float(bounds.minX + bounds.width * fraction),
                                                Float(bounds.midY), &hit) == .success,
               let hit, let visible = composerAncestor(of: hit), CFEqual(visible, editor) { return true }
        }
        return false
    }

    private func isComposer(_ candidate: AXUIElement) -> Bool {
        guard let role = attribute(candidate, "AXRole") as? String,
              role == "AXTextArea" || role == "AXTextField" else { return false }
        let rawLabels = ["AXDescription", "AXTitle", "AXPlaceholderValue"].compactMap { attribute(candidate, $0) as? String }
        if CodexChatTitle.existingCodexEditor(labels: rawLabels) { return true }
        let labels = rawLabels.map { $0.lowercased() }
        // The installed Codex view attaches its localized placeholder as the
        // accessible name. These labels are specific to the Codex composer.
        let knownLabels: Set<String> = [
            "work with codex", "do anything", "ask codex", "ask for follow-up changes",
            "describe your task to generate a plan...", "describe your task to generate a plan…",
            "describe your goal, define measurable outcomes for best results"
        ]
        if labels.contains(where: knownLabels.contains) { return true }
        let classes = attribute(candidate, "AXDOMClassList") as? [String] ?? []
        return classes.contains("ProseMirror") && labels.contains { $0.contains("codex") }
    }

    private func focusedHostWindow() -> FocusedWindow? {
        guard AXIsProcessTrusted(), let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier == hostID, front.processIdentifier == target.pid,
              let expected = target.window, let window = element(target.app, "AXFocusedWindow"),
              CFEqual(expected, window) else { return nil }
        return (target.pid, target.app, window)
    }

    /// Passive reads may use an explicitly identified background window. Draft access and
    /// writes use focusedHostWindow() and also require the original editor and chat.
    private func addressedWindow() -> FocusedWindow? {
        guard let window = target.window, AXIsProcessTrusted(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else { return nil }
        return (target.pid, target.app, window)
    }

    fileprivate func focusTarget() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier == hostID, front.processIdentifier == target.pid else { return false }
        guard let window = target.window else {
            return !AXIsProcessTrusted() && Self.frontWindowNumber(for: front) == target.id
        }
        if focusedHostWindow() != nil { return true }
        guard AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success else { return false }
        if focusedHostWindow() != nil { return true }
        if settable(window, "AXMain") {
            _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        // Electron may publish the window-focus change just after AXRaise returns.
        for _ in 0..<4 {
            if focusedHostWindow() != nil { return true }
            Thread.sleep(forTimeInterval: 0.015)
        }
        return focusedHostWindow() != nil
    }

    /// In Electron, AXDocument and AXURL may identify only the app shell. The
    /// sidebar's current-page anchor then provides its canonical /local/<id>.
    private func currentChatKey(in window: AXUIElement, editor: AXUIElement?, freshScan: Bool,
                                forShelf: Bool = false) -> String? {
        identitySource = "unknown"
        selectedRow = nil
        observedKeys = []
        primaryScopeToken = nil
        isForeignContext = false
        var web: AXUIElement?
        var enclosingPanel: String?
        var node = editor
        for _ in 0..<48 {
            guard let item = node, let info = ancestorInfo(item) else { break }
            if enclosingPanel == nil { enclosingPanel = info.panel }
            if info.role == "AXWebArea" {
                web = item
                break
            }
            node = info.parent
        }
        if web == nil {
            // Stop at each web area's root. Embedded browsers are separate documents.
            web = descendants(of: window, matching: "AXWebArea", budget: 64, limit: 6).first { item in
                guard let raw = attribute(item, "AXURL"),
                      let url = (raw as? URL) ?? (raw as? String).flatMap(URL.init(string:)) else { return false }
                return ["app", "file", "codex", "chatgpt"].contains(url.scheme?.lowercased() ?? "")
            }
        }
        let token = enclosingPanel ?? web.flatMap { selectedTab.primaryToken(in: $0, window: window, editor: editor) }
        var panelKey: String?
        var localPanelKey: String?
        var aliasKeys: Set<String> = []
        if let token {
            if Self.isForeignPrimaryPanel(identifier: token) {
                primaryScopeToken = token
                isForeignContext = true
                identitySource = "other-panel"
                confirmedShelf = nil
                titleObservation = nil
                return nil
            }
            panelKey = Self.primaryPanelKey(identifier: token)
            localPanelKey = Self.localPanelKey(identifier: token)
            let prefix = "app-shell-tab-panel-fullscreen-primary:"
            let alias = token.hasPrefix(prefix)
                ? CodexAliasIndex.canonicalAlias(String(token.dropFirst(prefix.count))) : nil
            if panelKey != nil || localPanelKey != nil || alias != nil { primaryScopeToken = token }
            if let alias {
                aliasKeys = aliasIndex.keys(for: alias)
                if let copied = copiedPanelKeys[alias] { aliasKeys.insert(copied) }
                if aliasKeys.count > 1 || aliasKeys.contains("other") {
                    observedKeys = aliasKeys
                    isForeignContext = true
                    identitySource = "conflicting-panels"
                    confirmedShelf = nil
                    titleObservation = nil
                    return nil
                }
            }
        }
        let windowURL = url(on: window, name: "AXDocument")
        let documentURL = web.flatMap { url(on: $0, name: "AXURL") }
        if [windowURL, documentURL].compactMap({ $0 }).contains(where: Self.identifiesForeignRoute) {
            isForeignContext = true
            identitySource = "other-route"
            confirmedShelf = nil
            titleObservation = nil
            return nil
        }
        let windowKey = windowURL.flatMap(Self.threadKey)
        let documentKey = documentURL.flatMap(Self.threadKey)
        if rowWindow.map({ CFEqual($0, window) }) != true {
            rowWindow = window
            currentRow = nil
            navigation = nil
        }
        let sidebarKeys = web.map { self.sidebarKeys(in: $0, window: window, freshScan: freshScan) } ?? []
        if isForeignContext {
            identitySource = "other-sidebar-route"
            confirmedShelf = nil
            titleObservation = nil
            return nil
        }
        let independent = [windowKey, documentKey, localPanelKey] + sidebarKeys.union(aliasKeys).map(Optional.some)
        let known = selectedRow.flatMap(knownKey)
        if let old = confirmedShelf {
            if !CFEqual(window, old.window) {
                clearReturnObservation()
            } else {
                let changedPanel = primaryScopeToken.flatMap { token in old.panel.map { $0 != token } } == true
                let changedRow = selectedRow.flatMap { row in old.row.map { prior in
                    // A remount can replace the row under the same title. The
                    // exact unique title check handles this and vetoes namesakes.
                    prior.label != row.label
                } } == true
                if changedPanel || changedRow {
                    departure = (old, changedPanel, changedRow)
                    confirmedShelf = nil
                    titleObservation = nil
                }
            }
        }
        if let change = departure, !CFEqual(change.old.window, window) { departure = nil }
        func isDepartingKey(_ key: String) -> Bool {
            guard let change = departure, change.old.key == key else { return false }
            let originalRow = selectedRow.flatMap { row in change.old.row.map { $0.matches(row) } } == true
            let rowAgrees = !change.changedRow || originalRow || sidebarKeys.contains(key) || known == key
            let panelAgrees = !change.changedPanel || (primaryScopeToken != nil && primaryScopeToken == change.old.panel)
                || localPanelKey == key || aliasKeys == [key]
            return !rowAgrees || !panelAgrees
        }
        let witnessed = editor.flatMap { keyForComposer($0, window: window) }
        let routes = independent + [known, witnessed]
        let route = Self.agreedChatKey(routes)
        observedKeys = Set((routes + [panelKey]).compactMap { $0 })
        // The app calls its panel identifier a clientThreadId. Trust a bare
        // UUID for this fallback only after a canonical route proved it.
        if let panelKey, route == panelKey { verifiedPrimaryIDs.insert(panelKey) }
        if let key = Self.resolvedChatKey(routes: routes, panel: panelKey, verified: verifiedPrimaryIDs) {
            guard !isDepartingKey(key) else { identitySource = "changing-chat"; return nil }
            titleObservation = nil
            if witnessed == key { identitySource = "composer-control" }
            else if known == key || sidebarKeys.contains(key) { identitySource = "sidebar" }
            else if token != nil && enclosingPanel == nil { identitySource = "selected-tab" }
            else { identitySource = "chat-id" }
            rememberShelf(key, window: window, editor: editor)
            return key
        }
        guard observedKeys.count <= 1, !savedChatKeys.isEmpty else {
            confirmedShelf = nil
            titleObservation = nil
            return nil
        }
        if let old = confirmedShelf, !observedKeys.allSatisfy({ $0 == old.key }) {
            confirmedShelf = nil
            titleObservation = nil
        }
        // An explicit native title change is navigation evidence even when no
        // editor or chat header is accessible on this particular poll.
        if let old = confirmedShelf, let previousTitle = old.nativeTitle,
           let raw = attribute(window, "AXTitle") as? String,
           !raw.isEmpty, previousTitle != Data(raw.utf8),
           titleCatalog.uniqueKey(for: raw, among: savedChatKeys) != old.key {
            confirmedShelf = nil
            titleObservation = nil
        }
        if forShelf, let old = confirmedShelf, savedChatKeys.contains(old.key) {
            let sameNavigation = (primaryScopeToken != nil && primaryScopeToken == old.panel)
                || selectedRow.flatMap { row in old.row.map { $0.matches(row) } } == true
            if let evidence = chatTitle.continuing(in: window, web: web, editor: editor,
                                                         priorEditor: old.editor, sameNavigation: sameNavigation) {
                switch titleCatalog.lookup(evidence.title, among: savedChatKeys) {
                case .unique(let key) where key == old.key:
                    observedKeys.insert(key)
                    if let editor { _ = observedTitleTwice(key, window: window, editor: editor) }
                    rememberShelf(key, window: window, editor: editor)
                    identitySource = "confirmed-chat-visible"
                    return key
                case .busy(let previous) where evidence.anchored && previous == old.key:
                    // A writer holds the catalog. The very same mounted editor or
                    // selected navigation still witnesses the last exact title match.
                    identitySource = "confirmed-chat-catalog-busy"
                    return old.key
                case .unique, .noMatch:
                    // A new title/duplicate is authoritative even during an editor miss.
                    confirmedShelf = nil
                    titleObservation = nil
                default: break
                }
            }
        }
        guard let editor else {
            // Missing geometry is inconclusive. A different editor/window still
            // starts a new title observation when one is next discovered.
            return nil
        }
        let key = restoredChat(window: window, web: web, editor: editor)
        if let key {
            guard !isDepartingKey(key) else { identitySource = "changing-chat"; return nil }
            rememberShelf(key, window: window, editor: editor)
        }
        else if ["no-chat-title", "no-unique-saved-match", "conflicting-chat-title"].contains(identitySource) {
            confirmedShelf = nil
        }
        return key
    }

    private func rememberShelf(_ key: String, window: AXUIElement, editor: AXUIElement?) {
        departure = nil
        let prior = confirmedShelf
        let same = prior.map { CFEqual($0.window, window) && $0.key == key } == true
        confirmedShelf = ConfirmedShelf(window: window, editor: editor ?? (same ? prior?.editor : nil),
                                        key: key, panel: primaryScopeToken ?? (same ? prior?.panel : nil),
                                        row: selectedRow ?? (same ? prior?.row : nil),
                                        nativeTitle: (attribute(window, "AXTitle") as? String).map { Data($0.utf8) }
                                            ?? (same ? prior?.nativeTitle : nil))
    }

    private func restoredChat(window: AXUIElement, web: AXUIElement?, editor: AXUIElement) -> String? {
        guard let title = chatTitle.current(in: window, editor: editor, web: web) else {
            identitySource = "no-chat-title"
            titleObservation = nil
            return nil
        }
        let lookup = titleCatalog.lookup(title, among: savedChatKeys)
        guard case .unique(let key) = lookup else {
            switch lookup {
            case .busy: identitySource = "chat-catalog-busy"
            case .unavailable: identitySource = "chat-catalog-unavailable"
            default: identitySource = "no-unique-saved-match"; titleObservation = nil
            }
            return nil
        }
        guard observedKeys.allSatisfy({ $0 == key }) else {
            identitySource = "conflicting-chat-title"
            titleObservation = nil
            return nil
        }
        // The native window title can briefly lag the React route. Never carry
        // the previous editor's observation into a newly mounted conversation.
        if observedTitleTwice(key, window: window, editor: editor) {
            observedKeys.insert(key)
            identitySource = "local-chat-catalog"
            return key
        }
        identitySource = "waiting-for-chat-title"
        return nil
    }

    private func observedTitleTwice(_ key: String, window: AXUIElement, editor: AXUIElement) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if let old = titleObservation, old.key == key, CFEqual(old.window, window), CFEqual(old.editor, editor) {
            return now - old.since >= 0.45
        }
        titleObservation = (window, editor, key, now)
        return false
    }

    /// Called after an explicit copied chat link is checked against the
    /// same live window and primary panel. A bare UUID must equal that link.
    @discardableResult
    func rememberCopiedPanel(_ token: String, as key: String) -> Bool {
        guard !isForeignContext, primaryScopeToken == token, key.hasPrefix("thread:"),
              let id = UUID(uuidString: String(key.dropFirst(7))),
              key == "thread:" + id.uuidString.lowercased(), observedKeys.allSatisfy({ $0 == key }) else {
            return false
        }
        if let bare = Self.primaryPanelKey(identifier: token) {
            guard bare == key else { return false }
            verifiedPrimaryIDs.insert(key)
            return true
        }
        let prefix = "app-shell-tab-panel-fullscreen-primary:"
        guard token.hasPrefix(prefix),
              let alias = CodexAliasIndex.canonicalAlias(String(token.dropFirst(prefix.count))),
              copiedPanelKeys[alias].map({ $0 == key }) ?? true,
              aliasIndex.keys(for: alias).allSatisfy({ $0 == key }) else { return false }
        copiedPanelKeys[alias] = key
        return true
    }

    nonisolated static func resolvedChatKey(routes: [String?], panel: String?, verified: Set<String>) -> String? {
        // A mounted composer from A can briefly coexist with the newly selected
        // sidebar row B. Reject that transition even for a previously unseen panel.
        if routes.contains(where: { $0 != nil }) { return agreedChatKey(routes + [panel]) }
        return panel.flatMap { verified.contains($0) ? $0 : nil }
    }

    /// The desktop's local-thread route is represented as local:<conversationId>
    /// in the primary panel. Remote, Work and pending client scopes use other prefixes.
    nonisolated static func localPanelKey(identifier: String) -> String? {
        let prefix = "app-shell-tab-panel-fullscreen-primary:local:"
        guard identifier.hasPrefix(prefix),
              let id = UUID(uuidString: String(identifier.dropFirst(prefix.count))) else { return nil }
        return "thread:" + id.uuidString.lowercased()
    }

    nonisolated static func isForeignPrimaryPanel(identifier: String) -> Bool {
        let prefix = "app-shell-tab-panel-fullscreen-primary:"
        guard identifier.hasPrefix(prefix) else { return identifier.hasPrefix("app-shell-tab-panel-") }
        let scope = identifier.dropFirst(prefix.count)
        return scope.hasPrefix("remote:") || scope.hasPrefix("route:") || scope.hasPrefix("work:")
    }

    /// Chromium versions export a DOM id through AXDOMIdentifier or AXIdentifier.
    /// An ARIA tabpanel can also reference its owning tab as its title element.
    /// Only a panel on the actual composer's ancestor chain qualifies.
    private func ancestorInfo(_ item: AXUIElement) -> (role: String?, panel: String?, parent: AXUIElement?)? {
        let attributes = ["AXRole", "AXSubrole", "AXDOMIdentifier", "AXIdentifier", "AXParent"]
        var result: CFArray?
        let status = AXUIElementCopyMultipleAttributeValues(item, attributes as CFArray, [], &result)
        let values: [AnyObject]
        if status == .success, let batch = result as? [AnyObject], batch.count == attributes.count {
            values = batch
        } else if status == .notImplemented || status == .attributeUnsupported {
            values = attributes.map { attribute(item, $0) ?? NSNull() }
        } else {
            return nil
        }
        let role = values[0] as? String
        let ids = values[2...3].compactMap { $0 as? String }.filter { $0.hasPrefix("app-shell-tab-panel-") }
        var panel = ids.first
        if Set(ids).count > 1 { panel = "app-shell-tab-panel-conflicting-identifiers" }
        if panel == nil, role == "AXTabPanel" || values[1] as? String == "AXTabPanel",
           let label = element(item, "AXTitleUIElement") {
            let prefix = "app-shell-tab-fullscreen-primary:"
            for attr in ["AXDOMIdentifier", "AXIdentifier"] {
                if let id = attribute(label, attr) as? String, id.hasPrefix(prefix) {
                    panel = "app-shell-tab-panel-fullscreen-primary:" + id.dropFirst(prefix.count)
                    break
                }
            }
        }
        let parent = CFGetTypeID(values[4]) == AXUIElementGetTypeID() ? (values[4] as! AXUIElement) : nil
        return (role, panel, parent)
    }

    nonisolated static func primaryPanelKey(identifier: String) -> String? {
        let prefix = "app-shell-tab-panel-fullscreen-primary:"
        guard identifier.hasPrefix(prefix),
              let id = UUID(uuidString: String(identifier.dropFirst(prefix.count))) else { return nil }
        return "thread:" + id.uuidString.lowercased()
    }

    nonisolated static func agreedChatKey(_ candidates: [String?]) -> String? {
        let unique = Set(candidates.compactMap { $0 })
        return unique.count == 1 ? unique.first : nil
    }

    nonisolated static func copiedChatKey(_ url: URL) -> String? {
        guard url.scheme?.lowercased() == "codex", url.host?.lowercased() == "threads",
              url.user == nil, url.password == nil, url.port == nil, url.fragment == nil,
              url.pathComponents.count == 2,
              let id = UUID(uuidString: url.lastPathComponent) else { return nil }
        let fields = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard fields.allSatisfy({ ($0.name == "hostId" && $0.value == "local")
                                   || ($0.name == "threadAccess" && $0.value == "shared") }) else { return nil }
        return "thread:" + id.uuidString.lowercased()
    }

    private func remember(_ context: CodexRowContext, as key: String) {
        rowBindings.removeAll { $0.context.sameNode(context) }
        rowBindings.append((context, key))
        if rowBindings.count > 128 { rowBindings.removeFirst() }
    }

    private func knownKey(for context: CodexRowContext) -> String? {
        // A recycled or renamed row cannot inherit its former binding.
        rowBindings.removeAll { $0.context.sameNode(context) && !$0.context.matches(context) }
        return rowBindings.first(where: { $0.context.matches(context) })?.key
    }

    private func sidebarKeys(in web: AXUIElement, window: AXUIElement, freshScan: Bool) -> Set<String> {
        // Cache element handles only. The current flag, owning window, label
        // fingerprint, and DOM membership are checked even on the fast path.
        let cachedNav = navigation.flatMap { nav -> AXUIElement? in
            guard let owner = element(nav, "AXWindow"), CFEqual(owner, window),
                  isChatNavigation(nav), isDescendant(nav, of: web) else { return nil }
            return nav
        }
        if !freshScan, Date().timeIntervalSince(scannedAt) < 4,
           let nav = cachedNav, let item = currentRow,
           let context = context(for: item, in: nav, window: window) {
            selectedRow = context
            return Set([currentLinkKey(item)].compactMap { $0 })
        }
        scannedAt = Date()
        currentRow = nil
        let navs: [AXUIElement]
        if !freshScan, let nav = cachedNav {
            navs = [nav]
        } else {
            navigation = nil
            let landmarks = search(in: web, key: "AXLandmarkSearchKey", limit: 48)
                ?? descendants(of: web, matching: "AXLandmarkNavigation", budget: 180, limit: 8)
            navs = landmarks.filter(isChatNavigation)
        }
        var keys = Set<String>()
        var matches: [CodexRowContext] = []
        for nav in navs {
            let links = search(in: nav, key: "AXLinkSearchKey", limit: 512) ?? []
            let buttons = search(in: nav, key: "AXButtonSearchKey", limit: 768) ?? []
            let candidates = links.isEmpty && buttons.isEmpty
                ? descendants(of: nav, matching: "sidebarControl", budget: 1200, limit: 768) : links + buttons
            for item in candidates {
                guard attribute(item, "AXARIACurrent") as? String == "page" else { continue }
                if attribute(item, "AXRole") as? String == "AXLink",
                   let url = url(on: item, name: "AXURL"), Self.identifiesForeignRoute(url) {
                    isForeignContext = true
                    return []
                }
                if let context = context(for: item, in: nav, window: window) {
                    if let key = currentLinkKey(item) { keys.insert(key) }
                    matches.append(context)
                }
            }
        }
        // Two competing active rows during navigation cannot be bound by Copy.
        if matches.count == 1, let match = matches.first {
            navigation = match.navigation
            currentRow = match.row
            selectedRow = match
        } else if matches.count > 1 {
            isForeignContext = true
        } else if navs.count == 1 {
            navigation = navs[0]
        }
        return keys
    }

    private func context(for item: AXUIElement, in nav: AXUIElement, window: AXUIElement) -> CodexRowContext? {
        guard attribute(item, "AXARIACurrent") as? String == "page" else { return nil }
        let role = attribute(item, "AXRole") as? String
        if role == "AXButton" {
            // The desktop's title row is a button; its React data-* values
            // aren't available to AX. This styling class distinguishes it
            // from selected tabs, sidebar destinations, and project headings.
            let classes = attribute(item, "AXDOMClassList") as? [String] ?? []
            guard classes.contains("data-[app-action-sidebar-thread-selected=true]:bg-secondary-ghost-hover")
                else { return nil }
        } else if role != "AXLink" || currentLinkKey(item) == nil {
            return nil
        }
        guard isDescendant(item, of: nav) else { return nil }
        let name = ["AXTitle", "AXDescription"].compactMap { attribute(item, $0) as? String }
        guard name.contains(where: { !$0.isEmpty }) else { return nil }
        return CodexRowContext(window: window, navigation: nav, row: item, label: name)
    }

    private func currentLinkKey(_ item: AXUIElement) -> String? {
        guard attribute(item, "AXARIACurrent") as? String == "page",
              attribute(item, "AXRole") as? String == "AXLink" else { return nil }
        return threadKey(on: item, name: "AXURL")
    }

    private func isChatNavigation(_ item: AXUIElement) -> Bool {
        guard attribute(item, "AXSubrole") as? String == "AXLandmarkNavigation"
                || attribute(item, "AXRole") as? String == "AXLandmarkNavigation" else { return false }
        let classes = attribute(item, "AXDOMClassList") as? [String] ?? []
        if classes.contains(where: { $0.hasPrefix("Navigation-") }) { return true }
        return ["AXDescription", "AXTitle"].contains {
            (attribute(item, $0) as? String)?.lowercased() == "chat history"
        }
    }

    private func isDescendant(_ item: AXUIElement, of ancestor: AXUIElement) -> Bool {
        var node: AXUIElement? = item
        for _ in 0..<32 {
            guard let next = node else { return false }
            if CFEqual(next, ancestor) { return true }
            node = element(next, "AXParent")
        }
        return false
    }

    private func search(in item: AXUIElement, key: String, limit: Int) -> [AXUIElement]? {
        let query: [String: Any] = ["AXSearchKey": key, "AXResultsLimit": limit, "AXDirection": "AXDirectionNext"]
        var result: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(
            item, "AXUIElementsForSearchPredicate" as CFString, query as CFDictionary, &result)
        guard status == .success else { return nil }
        guard let elements = result as? [AXUIElement], !elements.isEmpty else { return nil }
        return elements
    }

    private func descendants(of root: AXUIElement, matching target: String,
                             budget: Int, limit: Int) -> [AXUIElement] {
        var queue = [root], matches: [AXUIElement] = []
        var position = 0
        while position < queue.count && matches.count < limit {
            let node = queue[position]
            position += 1
            let role = attribute(node, "AXRole") as? String ?? ""
            if role == target || (target == "sidebarControl" && ["AXLink", "AXButton"].contains(role))
                || (target == "AXLandmarkNavigation" &&
                                  attribute(node, "AXSubrole") as? String == target) {
                matches.append(node)
                continue
            }
            if position != 1 && ["AXWebArea", "AXStaticText", "AXTextArea", "AXTextField",
                                  "AXButton", "AXLink", "AXImage"].contains(role) { continue }
            let room = budget - queue.count
            if room > 0, let children = attribute(node, "AXChildren") as? [AXUIElement] {
                queue.append(contentsOf: children.prefix(room))
            }
        }
        return matches
    }

    private func threadKey(on element: AXUIElement, name: String) -> String? {
        url(on: element, name: name).flatMap(Self.threadKey)
    }

    private func url(on element: AXUIElement, name: String) -> URL? {
        let raw = attribute(element, name)
        return (raw as? URL) ?? (raw as? String).flatMap(URL.init(string:))
    }

    nonisolated static func identifiesForeignRoute(_ url: URL) -> Bool {
        guard ["app", "codex", "chatgpt", "file"].contains(url.scheme?.lowercased() ?? "") else { return false }
        func isForeign(_ components: URLComponents) -> Bool {
            if components.queryItems?.contains(where: { $0.name == "hostId" && $0.value != "local" }) == true {
                return true
            }
            let first = components.path.split(separator: "/").first
            return first == "remote" || first == "work" || first == "dot"
        }
        guard let main = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        if isForeign(main) { return true }
        return main.fragment.flatMap(URLComponents.init(string:)).map(isForeign) ?? false
    }

    nonisolated static func threadKey(for url: URL) -> String? {
        // Deep links use codex://threads/<id>. Internal routing may put the
        // same path in the URL or hash. Ignore arbitrary external pages.
        guard ["app", "codex", "chatgpt", "file"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if query.contains(where: { $0.name == "hostId" && $0.value != "local" }) { return nil }
        var paths = [url.path]
        if let host = url.host { paths.append("/" + host + url.path) }
        if let fragment = url.fragment { paths.append(fragment) }
        for path in paths {
            if let mark = path.firstIndex(of: "?") {
                var fragment = URLComponents()
                fragment.query = String(path[path.index(after: mark)...])
                if fragment.queryItems?.contains(where: { $0.name == "hostId" && $0.value != "local" }) == true {
                    continue
                }
            }
            let parts = path.components(separatedBy: "?")[0].split(separator: "/")
            guard parts.count >= 2,
                  ["thread", "threads", "local", "conversation", "conversations"].contains(parts[parts.count - 2].lowercased()),
                  let id = UUID(uuidString: String(parts.last!)) else { continue }
            return "thread:" + id.uuidString.lowercased()
        }
        return nil
    }

    private func settable(_ item: AXUIElement, _ name: String) -> Bool {
        var yes = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(item, name as CFString, &yes) == .success && yes.boolValue
    }

}

/// Window/editor handles cancel an interrupted gesture. Neither can identify a chat.
struct CodexLinkContext {
    fileprivate let pid: pid_t
    fileprivate let window: AXUIElement?
    fileprivate let windowNumber: CGWindowID?
    fileprivate let editor: AXUIElement?
    fileprivate let button: AXUIElement?
    fileprivate let row: CodexRowContext?
    fileprivate let panel: String?
    fileprivate let evidence: Set<String>
}

enum LinkScope {
    case currentChat, singleAction
}

extension CodexHost {
    func linkContext(for surface: CodexSurface? = nil) -> CodexLinkContext? {
        guard let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == hostID else { return nil }
        guard let (pid, _, window) = focusedHostWindow() else {
            // A fresh user-copied link also works for manual saving without Accessibility.
            guard surface == nil, !AXIsProcessTrusted(), let number = Self.frontWindowNumber(for: front),
                  target.id == number else { return nil }
            return CodexLinkContext(pid: front.processIdentifier, window: nil, windowNumber: number,
                                    editor: nil, button: nil, row: nil, panel: nil, evidence: [])
        }
        if let surface {
            guard surface.process == pid, CFEqual(window, surface.window) else { return nil }
            _ = currentChatKey(in: window, editor: surface.editor, freshScan: true)
        } else {
            _ = currentChatKey()
        }
        let editor = surface?.editor ?? current(freshScan: true)?.editor
        guard !isForeignContext, observedKeys.count <= 1 else { return nil }
        let button = primaryScopeToken == nil && selectedRow == nil
            ? editor.flatMap { CodexComposerWitness.find(from: $0, window: window) } : nil
        return CodexLinkContext(pid: pid, window: window, windowNumber: nil, editor: editor,
                                button: button, row: selectedRow, panel: primaryScopeToken, evidence: observedKeys)
    }

    private func keyForComposer(_ editor: AXUIElement, window: AXUIElement) -> String? {
        guard let index = composerBindings.firstIndex(where: {
            CFEqual($0.window, window) && CFEqual($0.editor, editor)
        }) else { return nil }
        let binding = composerBindings[index]
        // The control can disappear briefly during a redraw. Still require
        // the original handle on every use, but let it be found on a later poll.
        guard let button = CodexComposerWitness.find(from: editor, window: window) else { return nil }
        guard CFEqual(binding.button, button) else {
            composerBindings.remove(at: index)
            return nil
        }
        return binding.key
    }

    private static func frontWindowNumber(for app: NSRunningApplication) -> CGWindowID? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        return windows?.first(where: { item in
            guard item[kCGWindowOwnerPID as String] as? Int32 == app.processIdentifier,
                  item[kCGWindowLayer as String] as? Int == 0,
                  let bounds = item[kCGWindowBounds as String] as? NSDictionary,
                  let box = CGRect(dictionaryRepresentation: bounds) else { return false }
            return box.width > 250 && box.height > 160
        })?[kCGWindowNumber as String] as? CGWindowID
    }

    func inLinkWindow(_ context: CodexLinkContext) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier == hostID, front.processIdentifier == context.pid else { return false }
        if let window = context.window {
            guard let (_, _, current) = focusedHostWindow() else { return false }
            return CFEqual(window, current)
        }
        return context.windowNumber.map { Self.frontWindowNumber(for: front) == $0 } == true
    }

    /// Inspect the current draft at the gesture, even if no passive chat ID is exposed.
    func draftForLink(in context: CodexLinkContext) throws -> String {
        guard inLinkWindow(context), let original = context.editor, let view = current(freshScan: true),
              CFEqual(original, view.editor), !isForeignContext else { throw CaptureError.changed }
        guard let text = readDraft(view.editor), !text.contains("\u{fffc}") else { throw CaptureError.unavailable }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CaptureError.empty }
        return text
    }

    func acceptCopiedChat(_ chat: String, for context: CodexLinkContext) -> LinkScope? {
        guard inLinkWindow(context), context.evidence.allSatisfy({ $0 == chat }) else { return nil }
        guard context.window != nil else { return .singleAction }
        _ = currentChatKey()
        guard !isForeignContext, observedKeys.allSatisfy({ $0 == chat }),
              context.panel == nil || primaryScopeToken == context.panel else { return nil }
        if let row = context.row {
            guard let currentRow = selectedRow, currentRow.matches(row) else { return nil }
            remember(row, as: chat)
        }
        if let panel = context.panel, Self.localPanelKey(identifier: panel) == nil {
            guard rememberCopiedPanel(panel, as: chat) else { return nil }
        }
        if let original = context.button, let editor = context.editor, let window = context.window {
            guard let surface = current(freshScan: true), CFEqual(surface.editor, editor),
                  CFEqual(surface.window, window), !isForeignContext, observedKeys.allSatisfy({ $0 == chat }),
                  let button = CodexComposerWitness.find(from: editor, window: window),
                  CFEqual(button, original) else { return nil }
            composerBindings.removeAll { CFEqual($0.window, window) && CFEqual($0.editor, editor) }
            composerBindings.append((window, editor, button, chat))
            if composerBindings.count > 32 { composerBindings.removeFirst() }
        }
        if let resolved = currentChatKey() { return resolved == chat ? .currentChat : nil }
        guard inLinkWindow(context), !isForeignContext, observedKeys.allSatisfy({ $0 == chat }),
              context.panel == nil || primaryScopeToken == context.panel else { return nil }
        return .singleAction
    }
}

/// All Accessibility calls, chat bindings and SQLite reads share one serial queue.
/// The main thread receives plain geometry and identifiers from display polls.
final class HostAccess: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.composerbubbles.mac.host", qos: .userInitiated)
    private var sessions: [ShelfWindowID: CodexHost] = [:]
    private var latestKeys = Set<String>()

    private func targets(keepingShelvesWhileAXRemounts: Bool = false)
        -> (visible: [WindowTarget], liveIDs: Set<ShelfWindowID>?) {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier == "com.openai.codex", !front.isHidden else { return ([], nil) }
        let pid = front.processIdentifier
        guard let rows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return ([], nil) }
        let live = Set(rows.compactMap { row -> ShelfWindowID? in
            guard row[kCGWindowOwnerPID as String] as? pid_t == pid else { return nil }
            return row[kCGWindowNumber as String] as? ShelfWindowID
        })
        sessions = sessions.filter { live.contains($0.key) && $0.value.target.pid == pid }
        let windows = CodexWindowGeometry.inventory(rows, pid: pid)
        guard !windows.isEmpty else { return ([], live) }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        let trusted = AXIsProcessTrusted()
        let focus = trusted ? element(app, "AXFocusedWindow") : nil
        var all = trusted ? attribute(app, "AXWindows") as? [AXUIElement] ?? [] : []
        if let focus, !all.contains(where: { CFEqual(focus, $0) }) { all.append(focus) }
        let handles = all.compactMap { win -> (window: AXUIElement, frame: CGRect)? in
            guard attribute(win, "AXMinimized") as? Bool != true, let rect = frame(win) else { return nil }
            return (win, rect)
        }
        let focused = focus.flatMap { w in handles.firstIndex { CFEqual(w, $0.window) } }
        let previous = sessions.compactMapValues { session in
            session.knownWindow.flatMap { old in handles.firstIndex { CFEqual(old, $0.window) } }
        }
        let pairs = CodexWindowGeometry.match(windows, axFrames: handles.map(\.frame), focused: focused, previous: previous)
        let claimedHandles = Set(pairs.values)
        let now = ProcessInfo.processInfo.systemUptime
        let visible: [WindowTarget] = windows.compactMap { row in
            let index = pairs[row.id]
            let window = index.map { handles[$0].window }
            // A frame alone can be a secondary Electron surface. Keep a known
            // shelf through a missing handle, never a handle now paired elsewhere.
            let lastPair = keepingShelvesWhileAXRemounts ? sessions[row.id]?.lastPairedAt : nil
            guard row.isEligible(trusted: trusted, paired: window != nil,
                                 subrole: window.flatMap { attribute($0, "AXSubrole") as? String },
                                 missingPairAge: lastPair.map { now - $0 },
                                 previousHandleClaimed: previous[row.id].map(claimedHandles.contains) ?? false)
            else { return nil }
            return WindowTarget(id: row.id, pid: pid, app: app, window: window, frame: row.frame,
                                focused: trusted ? (index != nil && index == focused) : row.id == windows.first?.id,
                                occludingQuartzFrames: row.occludingQuartzFrames)
        }
        return (visible, live)
    }

    private func session(for target: WindowTarget) -> CodexHost {
        let session: CodexHost
        if let existing = sessions[target.id], existing.matches(target) {
            session = existing
            session.target = target
        } else {
            session = CodexHost(target: target)
            sessions[target.id] = session
        }
        session.savedChatKeys = latestKeys
        return session
    }

    private func session(for id: ShelfWindowID, activate: Bool) -> CodexHost? {
        guard let target = targets().visible.first(where: { $0.id == id }) else { return nil }
        let scoped = session(for: target)
        return !activate || scoped.focusTarget() ? scoped : nil
    }

    func focusedWindowID() -> ShelfWindowID? {
        queue.sync { targets().visible.first(where: \.focused)?.id }
    }

    func read<T>(in id: ShelfWindowID, activate: Bool = false, _ action: (CodexHost) throws -> T) rethrows -> T? {
        try queue.sync { try session(for: id, activate: activate).map(action) }
    }

    func perform<T: Sendable>(in id: ShelfWindowID, activate: Bool = false,
                              _ action: @Sendable @escaping (CodexHost) -> T,
                              completion: @MainActor @Sendable @escaping (T?) -> Void) {
        queue.async { [self] in
            let result = session(for: id, activate: activate).map(action)
            DispatchQueue.main.async { completion(result) }
        }
    }

    func observeWindows(savedKeys: Set<String>,
                        completion: @MainActor @Sendable @escaping ([WindowShelfObservation], Set<ShelfWindowID>?) -> Void) {
        queue.async { [self] in
            latestKeys = savedKeys
            let (visible, liveIDs) = targets(keepingShelvesWhileAXRemounts: true)
            observeNext(visible[...], results: []) { observations in completion(observations, liveIDs) }
        }
    }

    /// Yield the host queue after each window so explicit saves, drags and previews
    /// don't have to wait behind every background window's Accessibility traversal.
    private func observeNext(_ pending: ArraySlice<WindowTarget>, results: [WindowShelfObservation],
                             completion: @MainActor @Sendable @escaping ([WindowShelfObservation]) -> Void) {
        guard let target = pending.first else {
            DispatchQueue.main.async { completion(results) }
            return
        }
        queue.async { [self] in
            var updated = results
            let observation = session(for: target).shelfObservation()
            updated.append(WindowShelfObservation(id: target.id, focused: target.focused, observation: observation,
                                                   occludingQuartzFrames: target.occludingQuartzFrames))
            observeNext(pending.dropFirst(), results: updated, completion: completion)
        }
    }

    func reset() {
        queue.async { [self] in
            for session in sessions.values { session.clearReturnObservation() }
        }
    }
}

struct ShelfObservation: Sendable {
    let quartzFrame: CGRect?
    let windowQuartzFrame: CGRect?
    let chatKey: String?
    let source: String
    let trusted: Bool

    func placement(on screens: [(frame: CGRect, visibleFrame: CGRect)],
                   fallbackQuartzWindow: @autoclosure () -> CGRect?, fallbackScreen: @autoclosure () -> CGRect?)
        -> (anchor: NSRect, screen: NSRect, realAnchor: Bool)? {
        guard let primary = screens.first else { return nil }
        let raw = quartzFrame ?? windowQuartzFrame ?? fallbackQuartzWindow()
        guard let reference = raw.map({ CGRect(x: $0.minX, y: primary.frame.maxY - $0.maxY,
                                               width: $0.width, height: $0.height) }) ?? fallbackScreen() else { return nil }
        func overlap(_ screen: CGRect) -> CGFloat {
            let rect = screen.intersection(reference)
            return rect.isEmpty || rect.isNull ? 0 : rect.width * rect.height
        }
        let display = screens.max { overlap($0.frame) < overlap($1.frame) } ?? primary
        if quartzFrame != nil { return (reference, display.visibleFrame, true) }
        let railWidth = min(580, reference.width * 0.58)
        let trailing = min(reference.maxX - 55, reference.midX + railWidth * 0.54)
        let estimate = CGRect(x: trailing - railWidth, y: reference.minY + 26, width: railWidth, height: 66)
        return (estimate, display.visibleFrame, false)
    }
}
