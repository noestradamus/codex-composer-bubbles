import Foundation

@main
struct NumberChecks {
    static let chatA = "thread:aaaaaaaa-0000-4000-8000-000000000001"
    static let chatB = "thread:bbbbbbbb-0000-4000-8000-000000000002"

    static func main() throws {
        if CommandLine.arguments.count == 3 {
            let store = BubbleStore(directory: URL(fileURLWithPath: CommandLine.arguments[1]))
            let worker = CommandLine.arguments[2]
            for index in 1...8 {
                try store.save("Worker \(worker), record \(index)", in: chatA)
                try store.save("Shared between all workers", in: chatB)
            }
            return
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bubble-numbers-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("bubbles.json")
        let aLast = UUID(), bFirst = UUID(), aFirst = UUID(), legacy = UUID()
        let legacyRows = [
            ["id": aLast.uuidString, "text": "Last in A", "chatKey": chatA],
            ["id": bFirst.uuidString, "text": "First in B", "chatKey": chatB],
            ["id": aFirst.uuidString, "text": "First in A", "chatKey": "thread:" + chatA.dropFirst(7).uppercased()],
            ["id": legacy.uuidString, "text": "Unassigned"]
        ]
        let source = try JSONSerialization.data(withJSONObject: ["version": 1, "bubbles": legacyRows])
        try source.write(to: file)
        let store = BubbleStore(directory: directory)
        try store.reload()
        let firstReload = try Data(contentsOf: file)
        precondition(firstReload == source, "A read should not rewrite the user's old shelf.")
        precondition(store.visible(in: chatA).compactMap(\.number) == [2, 1])
        precondition(store.visible(in: chatB).compactMap(\.number) == [1])
        precondition(store.unassigned.first?.id == legacy && store.unassigned.first?.number == nil)
        let other = BubbleStore(directory: directory)
        try other.reload()
        let duplicate = try store.save("First in A", in: chatA)
        precondition(duplicate.id == aFirst && duplicate.number == 1)
        let assigned = try other.assign(legacy, to: chatB)
        precondition(assigned.id == legacy && assigned.number == 2)
        let nextA = try store.save("New in A", in: chatA)
        precondition(nextA.number == 3)
        try other.remove(nextA.id)
        let afterDelete = try store.save("After deleting highest in A", in: chatA)
        precondition(afterDelete.number == 4)
        let undone = try other.restore(nextA)
        let twice = try store.restore(nextA)
        precondition(undone == nextA && twice == nextA)
        let reloaded = BubbleStore(directory: directory)
        try reloaded.reload()
        precondition(reloaded.visible(in: chatA).compactMap(\.number).sorted() == [1, 2, 3, 4])
        for bubble in reloaded.visible(in: chatA) { try reloaded.remove(bubble.id) }
        let afterEmpty = try other.save("After deleting all in A", in: chatA)
        precondition(afterEmpty.number == 5)
        try other.remove(afterEmpty.id)
        let reSaved = try store.save(afterEmpty.text, in: chatA)
        let coalesced = try other.restore(afterEmpty)
        precondition(reSaved.number == 6 && coalesced == reSaved)
        let durable = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        precondition(durable["version"] as? Int == 1)
        precondition((durable["lastNumberByChat"] as? [String: Int]) == [chatA: 6, chatB: 2])
        print("PASS previous shelf numbering, independent chats, duplicate save, assignment, removal, undo, relaunch and no number reuse")

        let mixed: [[String: Any]] = [
            ["id": UUID().uuidString, "text": "Collision", "chatKey": chatA, "number": 7],
            ["id": UUID().uuidString, "text": "Unnumbered", "chatKey": chatA],
            ["id": UUID().uuidString, "text": "Invalid", "chatKey": chatA, "number": 0],
            ["id": UUID().uuidString, "text": "Valid", "chatKey": chatA, "number": 7]
        ]
        let payload = try JSONSerialization.data(withJSONObject: ["version": 1, "bubbles": mixed, "lastNumberByChat": [chatA: 17]])
        try payload.write(to: file)
        try reloaded.reload()
        precondition(reloaded.visible(in: chatA).compactMap(\.number) == [20, 19, 18, 7])
        let afterMixed = try other.save("Mixed-version next", in: chatA)
        precondition(afterMixed.number == 21)
        print("PASS mixed old/new data and deterministic collision recovery")

        let concurrent = directory.appendingPathComponent("concurrent")
        let workers = try (1...4).map { number in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = [concurrent.path, String(number)]
            try process.run()
            return process
        }
        for worker in workers {
            worker.waitUntilExit()
            precondition(worker.terminationStatus == 0)
        }
        let final = BubbleStore(directory: concurrent)
        try final.reload()
        precondition(final.visible(in: chatA).compactMap(\.number).sorted() == Array(1...32))
        precondition(final.visible(in: chatB).compactMap(\.number) == [1])
        print("PASS four concurrent processes, 32 distinct ordinals and one cross-process duplicate")
    }
}
