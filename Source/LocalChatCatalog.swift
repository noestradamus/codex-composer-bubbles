import Darwin
import Foundation
import SQLite3

/// Resolves the exact display name of an independently identified local Codex chat.
/// The caller supplies known bubble owners, including the owner of a pending Undo.
final class LocalChatCatalog {
    private struct FileID: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private struct CachedMatch {
        let titleBytes: Data
        let version: Int64
        let savedKeys: Set<String>
        let key: String?
    }

    private let databaseURL: URL
    private var connection: OpaquePointer?
    private var connectedFile: FileID?
    private var cached: CachedMatch?

    // Current Codex titles can omit this marker even when thread.name still
    // includes it. Match the displayed spelling byte for byte and test it
    // against every catalog row, including titles already stored that way.
    private static let namedTitleMatches = """
        (name COLLATE BINARY = ?1 OR replace(name, '</system-reminder>', '') COLLATE BINARY = ?1)
        """

    init(databaseURL: URL? = nil) {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"]
            .flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        self.databaseURL = databaseURL ?? home.appendingPathComponent("state_5.sqlite")
    }

    deinit {
        if let connection { sqlite3_close(connection) }
    }

    enum Lookup: Equatable {
        case unique(String), noMatch, unavailable, busy(lastVerified: String?)
    }

    func uniqueKey(for displayTitle: String, among savedKeys: Set<String>) -> String? {
        guard case .unique(let key) = lookup(displayTitle, among: savedKeys) else { return nil }
        return key
    }

    func lookup(_ displayTitle: String, among savedKeys: Set<String>) -> Lookup {
        guard !savedKeys.isEmpty, !displayTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !displayTitle.utf8.contains(0), displayTitle.utf8.count < Int(Int32.max) else { return .noMatch }
        guard let file = currentFileID() else {
            disconnect()
            return .unavailable
        }
        if connectedFile != file { disconnect() }
        guard let database = open(file) else { return .unavailable }
        let titleBytes = Data(displayTitle.utf8)
        func failedRead() -> Lookup {
            let code = sqlite3_errcode(database)
            guard (code == SQLITE_BUSY || code == SQLITE_LOCKED), currentFileID() == file else { return .unavailable }
            let previous = cached.flatMap { $0.titleBytes == titleBytes && $0.savedKeys == savedKeys ? $0.key : nil }
            return .busy(lastVerified: previous)
        }
        guard sqlite3_exec(database, "BEGIN", nil, nil, nil) == SQLITE_OK else { return failedRead() }
        defer { sqlite3_exec(database, "ROLLBACK", nil, nil, nil) }
        guard let version = dataVersion(database) else { return failedRead() }
        // Swift String equality is canonically equivalent; SQLite's BINARY comparison is byte-exact.
        if cached?.titleBytes != titleBytes || cached?.version != version || cached?.savedKeys != savedKeys {
            // Resolve candidates and detect all duplicates against one read snapshot. A commit
            // by an unrelated active Codex session is visible on the next observation.
            guard let match = readMatch(in: database, title: displayTitle, titleBytes: titleBytes,
                                        version: version, savedKeys: savedKeys) else { return failedRead() }
            guard currentFileID() == file else { return .unavailable }
            cached = match
        }
        guard let key = cached?.key, savedKeys.contains(key) else { return .noMatch }
        return .unique(key)
    }

    private func currentFileID() -> FileID? {
        var info = stat()
        guard stat(databaseURL.path, &info) == 0 else { return nil }
        return FileID(device: info.st_dev, inode: info.st_ino)
    }

    private func disconnect() {
        if let connection { sqlite3_close(connection) }
        connection = nil
        connectedFile = nil
        cached = nil
    }

    private func open(_ file: FileID) -> OpaquePointer? {
        if let connection { return connection }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            return nil
        }
        // A busy catalog can be retried on the next refresh. Never delay foreground typing for a writer.
        sqlite3_busy_timeout(handle, 15)
        connection = handle
        connectedFile = file
        return handle
    }

    private func dataVersion(_ database: OpaquePointer) -> Int64? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA data_version", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    private func hasSavedCandidate(in database: OpaquePointer, title: String, savedKeys: Set<String>) -> Bool? {
        // Codex's primary key is indexed. Avoid scanning the catalog for a chat with no bubbles.
        let sql = "SELECT 1 FROM threads WHERE id = ?2 AND \(Self.namedTitleMatches)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, title, Int32(title.utf8.count), transient) == SQLITE_OK else { return nil }
        for key in savedKeys where key.hasPrefix("thread:") {
            let id = String(key.dropFirst("thread:".count))
            guard sqlite3_reset(statement) == SQLITE_OK,
                  sqlite3_bind_text(statement, 2, id, -1, transient) == SQLITE_OK else { return nil }
            switch sqlite3_step(statement) {
            case SQLITE_ROW: return true
            case SQLITE_DONE: continue
            default: return nil
            }
        }
        return false
    }

    private func readMatch(in database: OpaquePointer, title: String, titleBytes: Data,
                           version: Int64, savedKeys: Set<String>) -> CachedMatch? {
        let miss = CachedMatch(titleBytes: titleBytes, version: version, savedKeys: savedKeys, key: nil)
        guard let candidate = hasSavedCandidate(in: database, title: title, savedKeys: savedKeys) else { return nil }
        guard candidate else { return miss }
        // The desktop hydrates its explicit thread title from thread.name. A nameless row's
        // fallback title/preview can veto a collision but is never positive identity evidence.
        // Include other creators, archives and unsaved IDs before intersecting the unique result.
        let sql = """
            SELECT id, \(Self.namedTitleMatches)
            FROM threads
            WHERE \(Self.namedTitleMatches)
               OR ((name IS NULL OR name = '') AND (
                    title COLLATE BINARY = ?1 OR replace(title, '</system-reminder>', '') COLLATE BINARY = ?1
                    OR preview COLLATE BINARY = ?1 OR replace(preview, '</system-reminder>', '') COLLATE BINARY = ?1
               ))
            LIMIT 2
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, title, Int32(titleBytes.count), transient) == SQLITE_OK else { return nil }
        switch sqlite3_step(statement) {
        case SQLITE_DONE: return miss
        case SQLITE_ROW:
            guard sqlite3_column_int(statement, 1) == 1, sqlite3_column_bytes(statement, 0) == 36,
                  let raw = sqlite3_column_text(statement, 0),
                  let id = UUID(uuidString: String(cString: raw)) else { return miss }
            switch sqlite3_step(statement) {
            case SQLITE_DONE: return CachedMatch(titleBytes: titleBytes, version: version,
                                                savedKeys: savedKeys, key: "thread:" + id.uuidString.lowercased())
            case SQLITE_ROW: return miss
            default: return nil
            }
        default: return nil
        }
    }
}
