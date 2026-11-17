import Foundation
import Darwin

struct SavedBubble: Codable, Equatable {
    let id: UUID
    let text: String
    let chatKey: String?
    let number: Int?

    init(id: UUID = UUID(), text: String, chatKey: String? = nil, number: Int? = nil) {
        self.id = id
        self.text = text
        self.chatKey = chatKey
        self.number = number
    }
}

enum ShelfError: LocalizedError {
    case empty, unknownChat, alreadyAssigned, unknownFormat, unavailableDirectory, numberLimit

    var errorDescription: String? {
        switch self {
        case .empty: return "The draft is empty."
        case .unknownChat: return "Open a Codex chat so Composer Bubbles can identify where to save this suggestion."
        case .alreadyAssigned: return "This bubble is no longer available to assign."
        case .unknownFormat: return "This shelf was written by a different version of Composer Bubbles."
        case .unavailableDirectory: return "The local shelf folder is unavailable."
        case .numberLimit: return "This chat has reached its bubble number limit."
        }
    }
}

/// Only a verified Codex thread ID can own a visible bubble.
func canonicalBubbleChat(_ key: String?) -> String? {
    guard let key, key.hasPrefix("thread:"),
          let id = UUID(uuidString: String(key.dropFirst("thread:".count))) else { return nil }
    return "thread:" + id.uuidString.lowercased()
}

final class BubbleStore {
    private struct Shelf: Codable {
        var version = 1
        var bubbles: [SavedBubble] = []
        // Keep the high-water mark even after a chat's last bubble is removed.
        var lastNumberByChat: [String: Int] = [:]

        init() {}

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decode(Int.self, forKey: .version)
            guard version == 1 else { throw ShelfError.unknownFormat }
            bubbles = try values.decode([SavedBubble].self, forKey: .bubbles)
            lastNumberByChat = try values.decodeIfPresent([String: Int].self, forKey: .lastNumberByChat) ?? [:]

            // v1 stored newest first; walk backwards so the earliest saved bubble is 1.
            // Reserve all existing numbers before filling gaps in mixed-version records.
            var used: [String: Set<Int>] = [:]
            var missing: [(index: Int, chat: String)] = []
            for index in bubbles.indices.reversed() {
                let bubble = bubbles[index]
                guard let chat = canonicalBubbleChat(bubble.chatKey) else { continue }
                if let n = bubble.number, n > 0, used[chat, default: []].insert(n).inserted {
                    lastNumberByChat[chat] = max(n, lastNumberByChat[chat] ?? 0)
                } else {
                    missing.append((index, chat))
                }
            }
            for (index, chat) in missing {
                let original = bubbles[index]
                let number = try nextNumber(in: chat)
                bubbles[index] = SavedBubble(id: original.id, text: original.text, chatKey: chat, number: number)
            }
        }

        mutating func nextNumber(in chat: String) throws -> Int {
            let last = max(0, lastNumberByChat[chat] ?? 0)
            guard last < Int.max else { throw ShelfError.numberLimit }
            let next = last + 1
            lastNumberByChat[chat] = next
            return next
        }

        func matching(_ text: String, in chat: String) -> SavedBubble? {
            bubbles.first { $0.text == text && canonicalBubbleChat($0.chatKey) == chat }
        }
    }

    private let directory: URL
    private var file: URL { directory.appendingPathComponent("bubbles.json") }
    private(set) var bubbles: [SavedBubble] = []

    init(directory: URL) {
        self.directory = directory
    }

    func reload() throws {
        bubbles = try read().bubbles
    }

    func visible(in chat: String?) -> [SavedBubble] {
        guard let key = canonicalBubbleChat(chat) else { return [] }
        return bubbles.filter { canonicalBubbleChat($0.chatKey) == key }
    }

    var unassigned: [SavedBubble] {
        bubbles.filter { $0.chatKey == nil || $0.chatKey == "shared" }
    }

    @discardableResult
    func save(_ text: String, in chat: String?) throws -> SavedBubble {
        try insert(SavedBubble(text: text, chatKey: chat))
    }

    @discardableResult
    func restore(_ bubble: SavedBubble) throws -> SavedBubble {
        try insert(bubble)
    }

    private func insert(_ bubble: SavedBubble) throws -> SavedBubble {
        guard let chat = canonicalBubbleChat(bubble.chatKey) else { throw ShelfError.unknownChat }
        guard !bubble.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ShelfError.empty }
        return try update { shelf in
            if let existing = shelf.bubbles.first(where: { $0.id == bubble.id }) {
                guard canonicalBubbleChat(existing.chatKey) == chat else { throw ShelfError.alreadyAssigned }
                return existing
            }
            if let same = shelf.matching(bubble.text, in: chat) { return same }
            let number: Int
            if let previous = bubble.number, previous > 0,
               !shelf.bubbles.contains(where: { $0.number == previous && canonicalBubbleChat($0.chatKey) == chat }) {
                number = previous
                shelf.lastNumberByChat[chat] = max(previous, shelf.lastNumberByChat[chat] ?? 0)
            } else {
                number = try shelf.nextNumber(in: chat)
            }
            let added = SavedBubble(id: bubble.id, text: bubble.text, chatKey: chat, number: number)
            shelf.bubbles.insert(added, at: 0)
            return added
        }
    }

    @discardableResult
    func assign(_ id: UUID, to chat: String?) throws -> SavedBubble {
        guard let chat = canonicalBubbleChat(chat) else { throw ShelfError.unknownChat }
        return try update { shelf in
            guard let index = shelf.bubbles.firstIndex(where: { $0.id == id }),
                  shelf.bubbles[index].chatKey == nil || shelf.bubbles[index].chatKey == "shared" else {
                throw ShelfError.alreadyAssigned
            }
            let text = shelf.bubbles[index].text
            if let same = shelf.matching(text, in: chat) {
                shelf.bubbles.remove(at: index)
                return same
            }
            let assigned = SavedBubble(id: id, text: text, chatKey: chat, number: try shelf.nextNumber(in: chat))
            shelf.bubbles[index] = assigned
            return assigned
        }
    }

    func remove(_ id: UUID) throws {
        try update { shelf in shelf.bubbles.removeAll { $0.id == id } }
    }

    private func read() throws -> Shelf {
        do {
            return try JSONDecoder().decode(Shelf.self, from: Data(contentsOf: file))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return Shelf()
        }
    }

    private func update<T>(_ edit: (inout Shelf) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let lock = open(directory.appendingPathComponent("shelf.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { flock(lock, LOCK_UN) }
        var shelf = try read()
        let result = try edit(&shelf)
        let data = try JSONEncoder().encode(shelf)
        try data.write(to: file, options: .atomic)
        bubbles = shelf.bubbles
        return result
    }
}
