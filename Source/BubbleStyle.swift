import Foundation

enum ShelfOrientation: String, CaseIterable {
    case horizontal
    case vertical

    var title: String { self == .horizontal ? "Horizontal" : "Vertical" }

    static func load(from defaults: UserDefaults) -> Self {
        defaults.string(forKey: "shelfOrientation").flatMap(Self.init(rawValue:)) ?? .horizontal
    }

    func save(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: "shelfOrientation")
    }
}

enum BubbleStyle: String, CaseIterable {
    case shortCaptions
    case numbers

    var title: String {
        switch self {
        case .shortCaptions: return "Short captions"
        case .numbers: return "Numbers"
        }
    }

    static func load(from defaults: UserDefaults) -> Self {
        let stored = defaults.string(forKey: "bubbleStyle")
        if stored == "completelyClear" { Self.shortCaptions.save(to: defaults) }
        return stored.flatMap(Self.init(rawValue:)) ?? .shortCaptions
    }

    func save(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: "bubbleStyle")
    }
}

enum SaveButtonStyle: String, CaseIterable {
    case bookmarkAndText
    case bookmarkOnly
    case textOnly

    var title: String {
        switch self {
        case .bookmarkAndText: return "Bookmark + Save"
        case .bookmarkOnly: return "Bookmark only"
        case .textOnly: return "Text only"
        }
    }

    static func load(from defaults: UserDefaults) -> Self {
        defaults.string(forKey: "saveButtonStyle").flatMap(Self.init(rawValue:)) ?? .bookmarkAndText
    }

    func save(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: "saveButtonStyle")
    }
}
