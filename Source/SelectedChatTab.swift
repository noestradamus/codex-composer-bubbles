import AppKit
import ApplicationServices

/// The special pinned Chat button in Codex's workspace tab strip has a DOM
/// identifier built from the same client thread ID as its controlled panel.
final class CodexSelectedChatTab {
    private static let tabPrefix = "app-shell-tab-fullscreen-primary:"
    private static let panelPrefix = "app-shell-tab-panel-fullscreen-primary:"
    private static let tabLimit = 40
    private struct HeaderScan {
        let web: AXUIElement
        let window: AXUIElement
        let editor: AXUIElement?
        let bounds: CGRect
        let groups: [AXUIElement]
        let at: TimeInterval
    }
    private var previousScan: HeaderScan?

    func primaryToken(in web: AXUIElement, window: AXUIElement, editor: AXUIElement?) -> String? {
        guard Self.string(web, "AXRole") == "AXWebArea", Self.owned(web, by: window),
              Self.isHostDocument(web, window: window),
              let bounds = Self.frame(window), let webBounds = Self.frame(web),
              !bounds.intersection(webBounds).isEmpty else { return nil }
        if let editor, !Self.owned(editor, by: window) { return nil }
        let visible = bounds.intersection(webBounds)
        var tabs: [AXUIElement]
        if let listed = Self.array(web, "AXTabs", limit: Self.tabLimit), !listed.isEmpty {
            guard listed.count <= Self.tabLimit else { return nil }
            tabs = listed
        } else {
            tabs = headerTabs(in: web, window: window, bounds: visible, editor: editor)
        }
        return Self.resolve(tabs, web: web, window: window, editor: editor, visible: visible)
    }

    private static func resolve(_ tabs: [AXUIElement], web: AXUIElement, window: AXUIElement,
                                editor: AXUIElement?, visible: CGRect) -> String? {
        var selected: [(tab: AXUIElement, id: String, group: AXUIElement?)] = []
        for tab in tabs {
            guard string(tab, "AXSubrole") == "AXTabButton",
                  string(tab, "AXRole") == "AXRadioButton",
                  isSelected(tab),
                  (value(tab, "AXEnabled") as? NSNumber)?.boolValue == true,
                  (value(tab, "AXHidden") as? NSNumber)?.boolValue != true,
                  (value(tab, "AXVisible") as? NSNumber)?.boolValue != false,
                  let box = frame(tab), visible.contains(CGPoint(x: box.midX, y: box.midY)),
                  belongs(tab, to: web, window: window) else { continue }
            let ids = shellIDs(tab)
            guard ids.count <= 1 else { return nil }
            if !selected.contains(where: { CFEqual($0.tab, tab) }) {
                selected.append((tab, ids.first ?? "", tabGroup(of: tab, web: web)))
            }
        }
        let primary = selected.filter { $0.id.hasPrefix(tabPrefix) }
        guard primary.count == 1, let choice = primary.first,
              let token = panelToken(forTab: choice.id) else { return nil }
        if let group = choice.group, selected.contains(where: { other in
            !CFEqual(other.tab, choice.tab) && other.group.map { CFEqual($0, group) } == true
        }) { return nil }

        // A Chromium controls relation may also list radio peers. Inspect
        // only panel IDs. Any contradictory controlled panel disqualifies the tab.
        if let links = array(choice.tab, "AXLinkedUIElements", limit: tabLimit) {
            guard links.count <= tabLimit else { return nil }
            for target in links {
                let ids = shellIDs(target).filter { $0.hasPrefix("app-shell-tab-panel-") }
                if ids.isEmpty {
                    if string(target, "AXSubrole") == "AXTabPanel" { return nil }
                    continue
                }
                guard ids.count == 1, ids.first == token, belongs(target, to: web, window: window),
                      (value(target, "AXHidden") as? NSNumber)?.boolValue != true,
                      (value(target, "AXVisible") as? NSNumber)?.boolValue != false else { return nil }
                if let editor, !contains(target, editor: editor, web: web) { return nil }
            }
        }
        if let editor {
            var current: AXUIElement? = editor
            for _ in 0..<48 {
                guard let node = current else { return nil }
                if CFEqual(node, web) { return token }
                if string(node, "AXRole") == "AXWebArea" { return nil }
                let ids = shellIDs(node).filter { $0.hasPrefix("app-shell-tab-panel-") }
                if !ids.isEmpty && (ids.count != 1 || ids.first != token) { return nil }
                current = element(node, "AXParent")
            }
            return nil
        }
        return token
    }

    private static func isHostDocument(_ web: AXUIElement, window: AXUIElement) -> Bool {
        if let raw = value(web, "AXURL"),
           let url = (raw as? URL) ?? (raw as? String).flatMap(URL.init(string:)),
           !["app", "file", "codex", "chatgpt"].contains(url.scheme?.lowercased() ?? "") { return false }
        var current = element(web, "AXParent")
        for _ in 0..<32 {
            guard let node = current else { return false }
            if CFEqual(node, window) { return true }
            if string(node, "AXRole") == "AXWebArea" { return false }
            current = element(node, "AXParent")
        }
        return false
    }

    private static func isSelected(_ tab: AXUIElement) -> Bool {
        let states = ["AXSelected", "AXValue"].compactMap { (value(tab, $0) as? NSNumber)?.boolValue }
        return !states.isEmpty && states.allSatisfy { $0 }
    }

    private static func panelToken(forTab id: String) -> String? {
        guard id.hasPrefix(tabPrefix) else { return nil }
        let scope = String(id.dropFirst(tabPrefix.count))
        let localPrefix = "local:", clientPrefix = "client-new-thread:"
        let uuid: String
        if scope.hasPrefix(localPrefix) { uuid = String(scope.dropFirst(localPrefix.count)) }
        else if scope.hasPrefix(clientPrefix) { uuid = String(scope.dropFirst(clientPrefix.count)) }
        else { uuid = scope }
        guard let parsed = UUID(uuidString: uuid), parsed.uuidString.lowercased() == uuid.lowercased()
        else { return nil }
        return panelPrefix + scope
    }

    private static func shellIDs(_ item: AXUIElement) -> Set<String> {
        Set(["AXDOMIdentifier", "AXIdentifier"].compactMap { string(item, $0) }
            .filter { $0.hasPrefix("app-shell-tab-") })
    }

    private static func tabGroup(of item: AXUIElement, web: AXUIElement) -> AXUIElement? {
        var current = element(item, "AXParent")
        for _ in 0..<10 {
            guard let node = current, !CFEqual(node, web) else { return nil }
            if string(node, "AXRole") == "AXTabGroup" { return node }
            current = element(node, "AXParent")
        }
        return nil
    }

    private static func contains(_ panel: AXUIElement, editor: AXUIElement, web: AXUIElement) -> Bool {
        var current: AXUIElement? = editor
        for _ in 0..<48 {
            guard let node = current else { break }
            if CFEqual(node, panel) { return true }
            if CFEqual(node, web) { break }
            current = element(node, "AXParent")
        }
        // Chromium can flatten a panel out of the editor's accessible ancestry.
        guard let panelBox = frame(panel), let editorBox = frame(editor) else { return false }
        return panelBox.contains(editorBox)
    }

    private static func belongs(_ item: AXUIElement, to web: AXUIElement, window: AXUIElement) -> Bool {
        guard owned(item, by: window) else { return false }
        var current: AXUIElement? = item
        for _ in 0..<48 {
            guard let node = current else { return false }
            if CFEqual(node, web) { return true }
            if string(node, "AXRole") == "AXWebArea" { return false }
            current = element(node, "AXParent")
        }
        return false
    }

    // Some AX providers expose AXTabs only on an actual tab group. Read the
    // window's header at bounded points and ask any hit group for its tab handles.
    private func headerTabs(in web: AXUIElement, window: AXUIElement, bounds: CGRect,
                                   editor: AXUIElement?) -> [AXUIElement] {
        let now = ProcessInfo.processInfo.systemUptime
        let groups: [AXUIElement]
        if let scan = previousScan, now - scan.at < 2, CFEqual(scan.web, web),
           CFEqual(scan.window, window), scan.bounds == bounds, Self.same(scan.editor, editor),
           scan.groups.allSatisfy({ Self.belongs($0, to: web, window: window) }) {
            groups = scan.groups
        } else {
            groups = Self.headerGroups(in: web, window: window, bounds: bounds, editor: editor)
            previousScan = HeaderScan(web: web, window: window, editor: editor,
                                      bounds: bounds, groups: groups, at: now)
        }
        var tabs: [AXUIElement] = []
        for group in groups {
            guard let groupTabs = Self.array(group, "AXTabs", limit: Self.tabLimit),
                  tabs.count + groupTabs.count <= Self.tabLimit else { return [] }
            tabs.append(contentsOf: groupTabs)
        }
        return tabs
    }

    private static func same(_ left: AXUIElement?, _ right: AXUIElement?) -> Bool {
        if let left, let right { return CFEqual(left, right) }
        return left == nil && right == nil
    }

    private static func headerGroups(in web: AXUIElement, window: AXUIElement, bounds: CGRect,
                                     editor: AXUIElement?) -> [AXUIElement] {
        var groups: [AXUIElement] = []
        var xPositions = stride(from: 0.08, through: 0.98, by: 0.10).map { bounds.minX + $0 * bounds.width }
        if let editor, let box = frame(editor) { xPositions.append(contentsOf: [box.minX + 16, box.midX]) }
        for yOffset in [19.0, 52.0] where yOffset < bounds.height {
            for x in xPositions where bounds.minX <= x && x <= bounds.maxX {
                guard let hit = hitTest(window, x, bounds.minY + yOffset) else { continue }
                let role = string(hit, "AXRole")
                let group = role == "AXTabGroup" ? hit : tabGroup(of: hit, web: web)
                guard let group, !groups.contains(where: { CFEqual($0, group) }),
                      belongs(group, to: web, window: window) else { continue }
                groups.append(group)
            }
        }
        return groups
    }

    private static func hitTest(_ window: AXUIElement, _ x: CGFloat, _ y: CGFloat) -> AXUIElement? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success else { return nil }
        var result: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateApplication(pid), Float(x), Float(y),
                                               &result) == .success else { return nil }
        return result
    }

    private static func array(_ item: AXUIElement, _ name: String, limit: Int) -> [AXUIElement]? {
        var result: CFArray?
        guard AXUIElementCopyAttributeValues(item, name as CFString, 0, limit + 1, &result) == .success
        else { return nil }
        return result as? [AXUIElement]
    }

    private static func owned(_ item: AXUIElement, by window: AXUIElement) -> Bool {
        element(item, "AXWindow").map { CFEqual($0, window) } == true
    }

    private static func string(_ item: AXUIElement, _ name: String) -> String? { value(item, name) as? String }

    private static func value(_ item: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(item, name as CFString, &result) == .success else { return nil }
        return result
    }

    private static func element(_ item: AXUIElement, _ name: String) -> AXUIElement? {
        guard let raw = value(item, name), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    private static func frame(_ item: AXUIElement) -> CGRect? {
        guard let origin = value(item, "AXPosition"), CFGetTypeID(origin) == AXValueGetTypeID(),
              let size = value(item, "AXSize"), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(origin as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &extent),
              extent.width > 0, extent.height > 0 else { return nil }
        return CGRect(origin: point, size: extent)
    }
}
