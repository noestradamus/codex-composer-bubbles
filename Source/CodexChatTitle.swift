import AppKit
import ApplicationServices

/// The installed Codex local-conversation page publishes its plain display
/// title to its native window. Titles are observations, never storage keys.
final class CodexChatTitle {
    private var lastWindow: AXUIElement?
    private var lastNative: String?
    private var buttons: [AXUIElement] = []
    private var probedAt = Date.distantPast

    static func validated(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.utf16.count <= 512,
              !title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !genericTitles.contains(title.lowercased()) else { return nil }
        // The app sets the title verbatim. Removing suffixes, punctuation,
        // qualifiers or truncation marks would introduce inexact matches.
        return title
    }

    static func agreed(native: String?, document: String?, headers: [String]) -> String? {
        let windowTitle = validated(native)
        let headerTitles = headers.compactMap { validated($0) }
        var result = windowTitle
        for title in headerTitles {
            if let result, !title.utf8.elementsEqual(result.utf8) { return nil }
            result = title
        }
        guard let doc = validated(document) else { return result }
        if let result, doc.utf8.elementsEqual(result.utf8) { return result }
        // The webview starts with "ChatGPT". Some product pages decorate
        // document.title while the native title and visible button stay plain.
        let appDecorated = ["ChatGPT", "Codex"].contains { app in
            [" - ", " – ", " — "].contains { doc.hasPrefix(app + $0) || doc.hasSuffix($0 + app) }
        }
        if appDecorated { return windowTitle != nil && !headerTitles.isEmpty ? result : nil }
        return result == nil ? doc : nil
    }

    static func existingCodexEditor(labels: [String]) -> Bool {
        labels.contains { existingComposerLabels.contains($0) }
    }

    /// Requires the actual visible Codex editor supplied by the host resolver.
    /// ChatGPT, Work and new-chat composers have different accessible names.
    func current(in window: AXUIElement, editor: AXUIElement,
                                   web: AXUIElement? = nil) -> String? {
        guard Self.isExistingEditor(editor, in: window) else { return nil }
        return displayed(in: window, web: web)
    }

    struct Continuity {
        let title: String
        let anchored: Bool
    }

    /// Verify the current chat surface independently of a screen-position hit.
    /// Native title alone can lag when switching a workspace or creating a chat.
    func continuing(in window: AXUIElement, web: AXUIElement?, editor: AXUIElement?,
                                      priorEditor: AXUIElement?, sameNavigation: Bool) -> Continuity? {
        let anchored: Bool
        if let editor {
            guard Self.isExistingEditor(editor, in: window) else { return nil }
            anchored = sameNavigation || priorEditor.map { CFEqual($0, editor) } == true
            // A new editor requires a fresh matching visible chat header too.
            // Its native window title alone may still name the departing chat.
        } else {
            anchored = sameNavigation || priorEditor.map { Self.stillMounted($0, in: window, web: web) } == true
        }
        guard let title = displayed(in: window, web: web, forContinuity: true, requireHeader: !anchored)
        else { return nil }
        return Continuity(title: title, anchored: anchored)
    }

    private static func isExistingEditor(_ editor: AXUIElement, in window: AXUIElement) -> Bool {
        guard let owner = element(editor, "AXWindow"), CFEqual(owner, window),
              ["AXTextArea", "AXTextField"].contains(value(editor, "AXRole") as? String ?? "")
        else { return false }
        return existingCodexEditor(labels: ["AXTitle", "AXDescription", "AXPlaceholderValue"].compactMap {
            value(editor, $0) as? String
        })
    }

    private static func stillMounted(_ editor: AXUIElement, in window: AXUIElement, web: AXUIElement?) -> Bool {
        guard isExistingEditor(editor, in: window),
              let bounds = frame(editor), let windowBounds = frame(window), bounds.intersects(windowBounds) else { return false }
        var item = editor
        var passedHostWeb = false
        for _ in 0..<48 {
            guard (value(item, "AXHidden") as? NSNumber)?.boolValue != true,
                  (value(item, "AXVisible") as? NSNumber)?.boolValue != false else { return false }
            if let web, CFEqual(item, web) { return true }
            if value(item, "AXRole") as? String == "AXWebArea" {
                guard web == nil, !passedHostWeb, let raw = value(item, "AXURL"),
                      let url = (raw as? URL) ?? (raw as? String).flatMap(URL.init(string:)),
                      ["app", "file", "codex", "chatgpt"].contains(url.scheme?.lowercased() ?? "") else { return false }
                passedHostWeb = true
            }
            if CFEqual(item, window) { return passedHostWeb }
            // Stale Chromium nodes can keep their old AXParent, AXWindow and
            // bounds. Check both directions of each link in the active tree.
            guard let parent = element(item, "AXParent"), containsChild(item, in: parent) else { return false }
            item = parent
        }
        return false
    }

    private static func containsChild(_ item: AXUIElement, in parent: AXUIElement) -> Bool {
        var count = 0
        guard AXUIElementGetAttributeValueCount(parent, "AXChildren" as CFString, &count) == .success,
              count > 0, count <= 128 else { return false }
        var values: CFArray?
        guard AXUIElementCopyAttributeValues(parent, "AXChildren" as CFString, 0, count, &values) == .success,
              let children = values as? [AXUIElement] else { return false }
        return children.contains { CFEqual($0, item) }
    }

    private func displayed(in window: AXUIElement, web: AXUIElement?,
                                              forContinuity: Bool = false, requireHeader: Bool = false) -> String? {
        guard Self.value(window, "AXSubrole") as? String != "AXDialog", (Self.value(window, "AXModal") as? Bool) != true,
              (Self.value(window, "AXSheets") as? [AXUIElement] ?? []).isEmpty else { return nil }
        let raw = Self.value(window, "AXTitle") as? String
        let native = Self.validated(raw)
        if forContinuity && native == nil { return nil }
        let trustedWeb = web.flatMap { item -> AXUIElement? in
            guard Self.value(item, "AXRole") as? String == "AXWebArea",
                  let owner = Self.element(item, "AXWindow"), CFEqual(owner, window) else { return nil }
            return item
        }
        let document = trustedWeb.flatMap { Self.value($0, "AXTitle") as? String }
        if lastWindow.map({ CFEqual($0, window) }) != true {
            lastWindow = window
            buttons.removeAll()
            probedAt = .distantPast
        }
        let changed = lastNative != native
        lastNative = native
        guard let bounds = Self.frame(window) else { return requireHeader ? nil : Self.agreed(native: native, document: document, headers: []) }
        let header = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: min(118, bounds.height / 4))
        buttons = buttons.filter { Self.isTitleButton($0, in: window, header: header) }
        if requireHeader || changed || Date().timeIntervalSince(probedAt) >= (buttons.isEmpty ? 1.5 : 4) {
            buttons = Self.titleButtons(in: window, header: header)
            probedAt = Date()
        }
        guard buttons.count <= 1 else { return nil }
        let titles = buttons.compactMap { button -> String? in
            let name = Self.value(button, "AXTitle") as? String
            if let name, !name.isEmpty { return name }
            return Self.value(button, "AXDescription") as? String
        }
        if requireHeader && titles.compactMap(Self.validated).isEmpty { return nil }
        return Self.agreed(native: native, document: document, headers: titles)
    }

    /// Probe the visible titlebar only. Sidebar rows, message contents and
    /// hidden controls are never enumerated to discover a title.
    private static func titleButtons(in window: AXUIElement, header: CGRect) -> [AXUIElement] {
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success else { return [] }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.12)
        var found: [AXUIElement] = []
        let xs: [CGFloat] = [0.10, 0.22, 0.33, 0.43, 0.53, 0.65, 0.76]
        for offset: CGFloat in [25, 58] {
            for fraction in xs {
                var hit: AXUIElement?
                guard AXUIElementCopyElementAtPosition(app, Float(header.minX + header.width * fraction),
                                                       Float(header.minY + offset), &hit) == .success else { continue }
                for _ in 0..<5 {
                    guard let node = hit else { break }
                    let role = value(node, "AXRole") as? String
                    if ["AXWindow", "AXWebArea", "AXToolbar"].contains(role) { break }
                    if ["AXButton", "AXPopUpButton", "AXMenuButton"].contains(role) {
                        if !found.contains(where: { CFEqual(node, $0) }),
                           isTitleButton(node, in: window, header: header) { found.append(node) }
                        break
                    }
                    hit = element(node, "AXParent")
                }
            }
        }
        return found
    }

    private static func isTitleButton(_ node: AXUIElement, in window: AXUIElement, header: CGRect) -> Bool {
        let classes = Set(value(node, "AXDOMClassList") as? [String] ?? [])
        let menu = classes.isSuperset(of: ["text-conversation-title", "px-conversation-title-inline", "select-none"])
        let rename = classes.isSuperset(of: ["max-w-[320px]", "min-h-token-button-composer", "px-button-toolbar-inline",
                                             "cursor-interaction", "text-base", "font-medium"])
        guard menu || rename, (value(node, "AXHidden") as? NSNumber)?.boolValue != true,
              (value(node, "AXVisible") as? NSNumber)?.boolValue != false, let bounds = frame(node), header.contains(CGPoint(x: bounds.midX, y: bounds.midY)),
              let owner = element(node, "AXWindow"), CFEqual(owner, window) else { return false }
        return true
    }

    private static func value(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, name as CFString, &result) == .success else { return nil }
        return result
    }

    private static func element(_ node: AXUIElement, _ name: String) -> AXUIElement? {
        guard let result = value(node, name), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return (result as! AXUIElement)
    }

    private static func frame(_ node: AXUIElement) -> CGRect? {
        guard let pos = value(node, "AXPosition"), CFGetTypeID(pos) == AXValueGetTypeID(),
              let size = value(node, "AXSize"), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(pos as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &extent), extent.width > 0, extent.height > 0 else { return nil }
        return CGRect(origin: point, size: extent)
    }

    // This build gives each product mode a separate existing-conversation label.
    private static let existingComposerLabels: Set<String> = [
        "Arbejd med Codex", "Arbeta med Codex", "Bekerja bersama Codex", "Bekerja dengan Codex",
        "Codex ile çalış", "Codex ke saath kaam karein", "Codex کے ساتھ کام کریں", "Codex के साथ काम करें",
        "Codex सोबत काम करा", "Codex ਨਾਲ ਕੰਮ ਕਰੋ", "Codex સાથે કામ કરો", "Codex ಜೊತೆಗೆ ಕೆಲಸ ಮಾಡಿ",
        "Codex ဖြင့် အလုပ်လုပ်ပါ", "Codex と一緒に作業を進める", "Codex-пен жұмыс істеңіз", "Codex-тэй ажиллаарай",
        "Codex-এর সঙ্গে কাজ করুন", "Codex-உடன் பணியாற்றுங்கள்", "Codex-നൊപ്പം പ്രവർത്തിക്കുക",
        "Codexతో పని చేయండి", "Codex와 함께 작업하세요", "Delajte z orodjem Codex", "Dirbkite su „Codex“",
        "Dolgozz a Codex segítségével", "Fanya kazi kwa kutumia Codex", "Jobb med Codex", "La shaqee Codex",
        "Lavora con Codex", "Lucrează cu Codex", "Làm việc với Codex", "Makipagtulungan sa Codex",
        "Mit Codex arbeiten", "Pracuj s Codexom", "Pracuj s nástrojem Codex", "Pracuj z Codex",
        "Puno me Codex", "Radi uz Codex", "Radite uz Codex", "Strādā ar Codex", "Trabaja con Codex",
        "Trabalhe com o Codex", "Travaillez avec Codex", "Treballa amb Codex", "Työskentele Codexilla",
        "Tööta tööriistaga Codex", "Vinna með Codex", "Werk met Codex", "Work with Codex",
        "Δουλέψτε με το Codex", "Працюйте разом із Codex", "Работайте с Codex", "Работете с Codex",
        "Работи со Codex", "Ради уз Codex", "Աշխատեք Codex-ի հետ", "اعمل مع Codex", "با Codex کار کنید",
        "ทำงานร่วมกับ Codex", "იმუშავეთ Codex-თან ერთად", "ከCodex ጋር ይሥሩ", "和 Codex 一起工作", "與 Codex 協作",
    ]
    private static let genericTitles: Set<String> = [
        "bagong chat", "bisedë", "bisedë e re", "chat", "chat nou", "chat nuevo", "chat အသစ်", "chatgpt",
        "chatgpt codex", "chatgpt work", "clavardage", "codex", "conversa nova", "gumzo jipya", "home",
        "jauna tērzēšana", "klepet", "naujas pokalbis", "neuer chat", "new chat", "new thread", "nieuwe chat",
        "nouveau chat", "nouveau clavardage", "nov klepet", "novi razgovor", "novo chat", "nový chat",
        "nový čet", "nowy czat", "nuevo chat", "nuova chat", "ny chat", "ny chatt", "nýtt spjall",
        "obrolan baru", "preferences", "sembang", "sembang baharu", "settings", "sohbet", "spjall",
        "trò chuyện", "trò chuyện mới", "uus vestlus", "uusi keskustelu", "wada-sheekeysi",
        "wada-sheekeysi cusub", "yeni sohbet", "új csevegés", "νέα συνομιλία", "жаңа чат", "нов разговор",
        "нов чат", "ново ћаскање", "новый чат", "разговор",
        "створити гілку цього чату в новому робочому дереві", "чат", "шинэ чат", "ћаскање", "զրույց",
        "նոր զրույց", "الدردشة", "دردشة جديدة", "نئی چَیٹ", "چت", "چت جدید", "چَیٹ", "चॅट", "चैट", "नई चैट",
        "नवीन चॅट", "চ্যাট", "নতুন চ্যাট", "ਚੈਟ", "ਨਵੀਂ ਚੈਟ", "ચૅટ", "નવી ચૅટ", "அரட்டை", "புதிய அரட்டை",
        "కొత్త చాట్", "చాట్", "ಚಾಟ್", "ಹೊಸ ಚಾಟ್", "ചാറ്റ്", "പുതിയ ചാറ്റ്", "แชตใหม่", "ახალი ჩატი", "ჩატი",
        "አዲስ ውይይት", "ውይይት", "對話", "チャット", "新しいチャット", "新對話", "新聊天", "聊天", "새 채팅",
    ]
}
