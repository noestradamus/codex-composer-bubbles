import Foundation

// Compile alongside the shipping BubbleStore.swift; all records and directories are fixtures.
@main
struct StoreIsolationChecks {
    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static func check(_ condition: @autoclosure () -> Bool, _ description: String) throws {
        if !condition() { throw Failure(description) }
    }

    static func requireRejection<T>(_ description: String, _ operation: () throws -> T) throws {
        do { _ = try operation() } catch { return }
        throw Failure(description)
    }

    static func sameIDs(_ bubbles: [SavedBubble], _ ids: Set<UUID>, _ description: String) throws {
        try check(bubbles.count == ids.count && Set(bubbles.map(\.id)) == ids, description)
    }

    static func main() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("composer-scope-qa-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("bubbles.json")
        let a = "thread:aaaaaaaa-0000-4000-8000-000000000001"
        let b = "thread:bbbbbbbb-0000-4000-8000-000000000002"
        let c = "thread:cccccccc-0000-4000-8000-000000000003"
        let wild: [String?] = [nil, "", "   ", "shared", "thread:", "thread:malformed"]
        let aOld = UUID(), bOld = UUID(), legacyOmitted = UUID(), legacyNull = UUID(), legacyShared = UUID()
        let legacyText = "  \nCompare the two versions. ☕️\n言い回しを残す。  "
        let duplicateText = "Keep both examples."
        // v1 Encodable omitted nil optional keys, but manually imported files can also use null or "shared".
        let rows: [[String: Any]] = [
            ["id": aOld.uuidString, "text": "Only A", "chatKey": "thread:" + a.dropFirst(7).uppercased()],
            ["id": bOld.uuidString, "text": "Only B", "chatKey": b],
            ["id": legacyOmitted.uuidString, "text": legacyText],
            ["id": legacyNull.uuidString, "text": duplicateText, "chatKey": NSNull()],
            ["id": legacyShared.uuidString, "text": "Unclaimed example", "chatKey": "shared"]
        ]
        let payload = try JSONSerialization.data(withJSONObject: ["version": 1, "bubbles": rows])
        try payload.write(to: file)
        let storage = BubbleStore(directory: dir)
        let otherProcess = BubbleStore(directory: dir)
        try storage.reload()
        try otherProcess.reload()
        let legacyIDs: Set<UUID> = [legacyOmitted, legacyNull, legacyShared]
        try sameIDs(storage.unassigned, legacyIDs, "v1 records with no reliable chat can all be recovered")
        try sameIDs(storage.visible(in: a), [aOld], "A shows only its keyed v1 record")
        try sameIDs(storage.visible(in: b), [bOld], "B shows only its keyed v1 record")
        try sameIDs(storage.visible(in: c), [], "An unrelated chat starts empty")

        let beforeInvalidWrites = try Data(contentsOf: file)
        for unresolved in wild {
            try sameIDs(storage.visible(in: unresolved), [], "Unresolved scopes must have no bubbles")
            try requireRejection("An invalid scope must refuse new bubbles") { try storage.save("must never be global", in: unresolved) }
            try requireRejection("An invalid scope must refuse a legacy assignment") { try storage.assign(legacyOmitted, to: unresolved) }
        }
        let afterInvalidWrites = try Data(contentsOf: file)
        try check(beforeInvalidWrites == afterInvalidWrites, "Invalid saves or assignments rewrote the shelf")
        try requireRejection("A disappeared bubble cannot be assigned") { try storage.assign(UUID(), to: a) }
        try requireRejection("B must never claim an existing keyed A bubble") { try storage.assign(aOld, to: b) }
        try requireRejection("Whitespace-only bubble was accepted") { try storage.save(" \n\t", in: a) }

        let inA = try storage.save(duplicateText, in: a)
        let inB = try otherProcess.save(duplicateText, in: b) // other still has its stale snapshot
        try storage.reload()
        try check(inA.id != inB.id && inA.id != legacyNull && inB.id != legacyNull,
                  "Deduplication incorrectly crossed chat or unassigned boundaries")
        let again = try storage.save(duplicateText, in: a)
        try check(again.id == inA.id, "Same-chat save was not idempotent")
        try sameIDs(storage.unassigned, legacyIDs, "Saving keyed text must not automatically claim an older copy")
        let assigned = try storage.assign(legacyOmitted, to: b)
        try check(assigned.id == legacyOmitted && assigned.chatKey == b && assigned.text == legacyText,
                  "Explicit assignment should preserve original ID and exact Unicode/multiline text")
        let deduped = try otherProcess.assign(legacyNull, to: a)
        try check(deduped.id == inA.id && deduped.chatKey == a && deduped.text == duplicateText,
                  "Explicit assignment to a chat with a duplicate must coalesce into that chat’s existing bubble")
        try storage.reload()
        try sameIDs(storage.unassigned, [legacyShared], "Only the deliberately unclaimed record should remain")
        let idsA: Set<UUID> = [aOld, inA.id]
        let idsB: Set<UUID> = [bOld, inB.id, assigned.id]
        let schedule: [(String?, Set<UUID>)] = [(a, idsA), (nil, []), (b, idsB), ("shared", []), (a, idsA), (c, []), (b, idsB), (a, idsA)]
        for _ in 0..<50 {
            for (key, expected) in schedule {
                try sameIDs(storage.visible(in: key), expected, "A changing active chat leaked or omitted a bubble")
            }
        }
        // A stale recovery menu selection can race another process assigning the same legacy bubble.
        let previous = try storage.assign(legacyShared, to: b)
        try check(previous.chatKey == b, "Initial explicit assignment failed")
        try requireRejection("A stale recovery menu silently reassigned B's item into A") {
            try otherProcess.assign(legacyShared, to: a)
        }
        let restarted = BubbleStore(directory: dir)
        try restarted.reload()
        try sameIDs(restarted.visible(in: a), idsA, "A changed after relaunch")
        try sameIDs(restarted.visible(in: b), idsB.union([legacyShared]), "B changed after relaunch")
        try sameIDs(restarted.visible(in: nil), [], "Missing identity exposed data after relaunch")
        try sameIDs(restarted.unassigned, [], "Resolved legacy records reappeared after relaunch")
        try check(!restarted.bubbles.contains { $0.id == legacyNull }, "Deduped legacy record was not retired")

        let composed = "Filename: caf\u{e9}", decomposed = "Filename: cafe\u{301}"
        let firstForm = try storage.save(composed, in: c)
        let secondForm = try storage.save(decomposed, in: c)
        let duplicate = try otherProcess.save(decomposed, in: c)
        try check(firstForm.id != secondForm.id && duplicate.id == secondForm.id, "Only byte-identical drafts coalesce")
        let changedText = SavedBubble(id: firstForm.id, text: decomposed, chatKey: c, number: firstForm.number)
        try check(firstForm != changedText, "Rendered bubble equality preserves exact draft bytes")
        try restarted.reload()
        try check(restarted.visible(in: c).contains { $0.id == secondForm.id && $0.text.utf8.elementsEqual(decomposed.utf8) },
                  "A decomposed Unicode draft must round-trip exactly through storage")
        let wrongChat = try otherProcess.remove(secondForm.id, from: b)
        try check(wrongChat == nil && otherProcess.visible(in: c).count == 2, "A linked snapshot can remove only its own bubbles")
        let removed = try otherProcess.remove(secondForm.id, from: c)
        let staleRemoval = try storage.remove(secondForm.id, from: c)
        try check(removed == secondForm && staleRemoval == nil, "A stale removal must not invent an Undo item")

        print("PASS v1 migration, nil/null/shared recovery, strict visibility and refusal to save without identity")
        print("PASS original ID/text preservation, per-chat deduplication, stale-process writes, explicit assignment and racing reassignment")
        print("PASS 400 A/unknown/B/C visibility transitions, restart, and no live UI access")
        print("PASS exact Unicode draft bytes, scoped removal and stale snapshot actions")
    }
}
