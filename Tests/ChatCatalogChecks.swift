import Foundation
import SQLite3

@main
enum ChatCatalogChecks {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("state.sqlite")
        let result = try CatalogFixture(file: file)
        let catalog = LocalChatCatalog(databaseURL: file)

        let named = "11111111-1111-4111-8111-111111111111"
        let other = "22222222-2222-4222-8222-222222222222"
        let different = "33333333-3333-4333-8333-333333333333"
        let key = "thread:" + named
        let displayed = "Review café " + String(repeating: "before the update ", count: 27) + "again"
        let stored = displayed.replacingOccurrences(of: "café ", with: "café</system-reminder> ") + "</system-reminder>"
        try result.insert(named, name: stored)
        try result.insert(different, name: displayed + "</other-marker>")

        check(catalog.lookup(displayed, among: [key]) == .unique(key), "match a visible title after the known markers are omitted")
        check(catalog.lookup(displayed, among: ["thread:" + different]) == .noMatch, "require the verified saved owner")
        check(catalog.lookup(displayed.replacingOccurrences(of: "é", with: "e\u{0301}"), among: [key]) == .noMatch,
              "match Unicode bytes exactly")
        check(catalog.lookup(displayed + "</other-marker>", among: [key]) == .noMatch, "preserve unrelated markup")
        check(catalog.lookup(stored, among: [key]) == .unique(key), "support hosts that still show the stored title")

        try result.insert(other, name: displayed)
        check(catalog.lookup(displayed, among: [key]) == .noMatch, "an exact unsaved namesake vetoes the normalized match")
        try result.remove(other)
        try result.insert(other, name: "", preview: stored)
        check(catalog.lookup(displayed, among: [key]) == .noMatch, "a normalized nameless preview vetoes, even after a cached match")
        check(catalog.lookup(displayed, among: ["thread:" + other]) == .noMatch, "a preview alone cannot supply an identity")
        try result.remove(other)
        try result.insert(other, name: displayed + "</system-reminder>")
        check(catalog.lookup(displayed, among: [key]) == .noMatch, "two different stored titles can have the same visible title")
        try result.remove(other)
        check(catalog.lookup(displayed, among: [key]) == .unique(key), "recover on the next read once ambiguity clears")
        print("Passed catalog restoration for visible Codex titles, exact text, and duplicate-title vetoes.")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            FileHandle.standardError.write(Data(("FAIL " + message + "\n").utf8))
            exit(1)
        }
    }
}

private final class CatalogFixture {
    let database: OpaquePointer

    init(file: URL) throws {
        var connection: OpaquePointer?
        guard sqlite3_open(file.path, &connection) == SQLITE_OK, let connection else {
            if let connection { sqlite3_close(connection) }
            throw CocoaError(.fileWriteUnknown)
        }
        database = connection
        try execute("CREATE TABLE threads (id TEXT PRIMARY KEY, name TEXT, title TEXT, preview TEXT)", values: [])
    }

    deinit { sqlite3_close(database) }

    func insert(_ id: String, name: String, preview: String = "") throws {
        try execute("INSERT INTO threads VALUES (?1, ?2, '', ?3)", values: [id, name, preview])
    }

    func remove(_ id: String) throws {
        try execute("DELETE FROM threads WHERE id = ?1", values: [id])
    }

    private func execute(_ sql: String, values: [String]) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            guard sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient) == SQLITE_OK else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw CocoaError(.fileWriteUnknown) }
    }
}
