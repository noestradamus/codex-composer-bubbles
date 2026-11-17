import AppKit
import ApplicationServices

/// The standard Codex editor mounts its Add Context button in a React subtree
/// keyed by the local client thread ID. The concrete button is a short-lived
/// corroborating handle after an explicit link. Compact layouts can omit it.
enum CodexComposerWitness {
    static func find(from editor: AXUIElement, window: AXUIElement) -> AXUIElement? {
        guard let owner = element(editor, "AXWindow"), CFEqual(owner, window),
              let box = frame(editor),
              ["AXTextArea", "AXTextField"].contains(value(editor, "AXRole") as? String ?? "") else { return nil }
        let vicinity = searchBounds(for: box)
        var parent = element(editor, "AXParent")
        for _ in 0..<10 {
            guard let group = parent, !CFEqual(group, window),
                  let role = value(group, "AXRole") as? String,
                  !["AXWebArea", "AXWindow", "AXSplitGroup", "AXTabGroup"].contains(role)
            else { return nil }
            if let groupBox = frame(group) {
                guard vicinity.contains(groupBox) else { return nil }
                if role == "AXGroup", let button = matchingButton(in: group, editor: editor, bounds: vicinity),
                   let owner = element(button, "AXWindow"), CFEqual(owner, window) { return button }
            }
            parent = element(group, "AXParent")
        }
        return nil
    }

    static func searchBounds(for editor: CGRect) -> CGRect {
        editor.insetBy(dx: -90, dy: -76)
    }

    private static func matchingButton(in group: AXUIElement, editor: AXUIElement, bounds: CGRect) -> AXUIElement? {
        var nodes = [group]
        var index = 0
        var foundEditor = false
        var button: AXUIElement?
        while index < nodes.count {
            let item = nodes[index]
            index += 1
            guard let role = value(item, "AXRole") as? String else { return nil }
            switch role {
            case "AXTextArea", "AXTextField":
                guard CFEqual(item, editor) else { return nil }
                foundEditor = true
            case "AXButton", "AXMenuButton", "AXPopUpButton":
                let classes = value(item, "AXDOMClassList") as? [String] ?? []
                guard classes.contains("h-token-button-composer"),
                      ["AXTitle", "AXDescription"].contains(where: {
                          guard let label = value(item, $0) as? String else { return false }
                          return addContextLabels.contains(label)
                      }) else { continue }
                guard button == nil, let box = frame(item), bounds.contains(box) else { return nil }
                button = item
            case "AXGroup", "AXToolbar", "AXScrollArea":
                guard let children = value(item, "AXChildren") as? [AXUIElement],
                      nodes.count + children.count <= 72 else { return nil }
                nodes.append(contentsOf: children)
            case "AXWebArea", "AXWindow", "AXTabGroup", "AXSplitGroup":
                return nil
            default:
                // Never inspect control values or message text.
                continue
            }
        }
        return foundEditor ? button : nil
    }

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
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(origin as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &extent),
              extent.width > 0, extent.height > 0 else { return nil }
        return CGRect(origin: point, size: extent)
    }

    // Exact accessible names for composer.contextButton.ariaLabel in the host.
    private static let addContextLabels: Set<String> = [
        "Add files and more", "ファイルなどを追加", "Adicionar arquivos e mais",
        "Adicionar ficheiros e mais", "Afegeix fitxers i més", "Aggiungi file e altro",
        "Agregar archivos y más", "Añadir archivos y más", "Ajouter des fichiers et plus encore",
        "Bestanden en meer toevoegen", "Dateien und mehr hinzufügen", "Dodaj pliki i nie tylko",
        "Dosyaları ve daha fazlasını ekle", "Lägg till filer med mera", "Legg til filer og mer",
        "Tilføj filer og mere", "Lisää tiedostoja ja muuta", "Adaugă fișiere și altele",
        "Bæta við skrám og fleira", "Dodaj datoteke i drugo", "Dodaj datoteke i još mnogo toga",
        "Dodaj datoteke in več", "Files aur aur bhi jodein", "Fájlok és egyéb hozzáadása",
        "I-add ang mga file at higit pa", "Ku dar faylal iyo wax kale", "Lisa faile ja muud",
        "Ongeza faili na zaidi", "Pievienot failus un vēl", "Pridať súbory a ďalší obsah",
        "Pridėti failų ir daugiau", "Přidat soubory a další", "Shto skedarë dhe më shumë",
        "Tambah fail dan banyak lagi", "Tambahkan file dan lainnya", "Thêm tệp và nội dung khác",
        "Προσθήκη αρχείων και άλλων", "Добавить файлы и другое", "Добавяне на файлове и още",
        "Додати файли й інше", "Додај датотеке и друго", "Додај датотеки и повеќе",
        "Файл болон бусад зүйлийг нэмэх", "Файлдар мен басқаны қосу", "Ավելացնել ֆայլեր և ավելին",
        "إضافة الملفات والمزيد", "افزودن فایل‌ها و موارد دیگر", "فائلیں اور مزید شامل کریں",
        "फ़ाइलें और अन्य चीज़ें जोड़ें", "फाइल्स आणि बरेच काही जोडा", "ফাইল ও আরও কিছু যোগ করুন",
        "ਫ਼ਾਈਲਾਂ ਅਤੇ ਹੋਰ ਸ਼ਾਮਲ ਕਰੋ", "ફાઇલો અને વધુ ઉમેરો", "கோப்புகள் மற்றும் பலவற்றைச் சேர்க்கும்",
        "ఫైళ్లు ఇంకా ఇతర అంశాలను జోడించు", "ಫೈಲ್‌ಗಳು ಮತ್ತು ಇನ್ನಷ್ಟು ಸೇರಿಸಿ", "ഫയലുകളും മറ്റും ചേർക്കുക",
        "เพิ่มไฟล์และอื่นๆ", "ဖိုင်များနှင့် အခြားအရာများကို ထည့်ပါ", "ფაილების დამატება და სხვა",
        "ፋይሎችን እና ሌሎችን ለማከል", "加入檔案及更多內容", "新增檔案和更多內容", "添加文件等内容", "파일 등 추가"
    ]
}
