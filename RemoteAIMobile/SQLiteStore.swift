import Foundation
import SQLite3

actor SQLiteStore {
    static let maxKVBytes = 256 * 1024
    static let maxMessageBytes = 512 * 1024
    static let fileProtection = FileProtectionType.complete

    private var db: OpaquePointer?
    private let protectionURL: URL?
    private let encoder = JSONEncoder.remoteAI
    private let decoder = JSONDecoder.remoteAI
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        self.protectionURL = url
        try open(path: url.path)
    }

    private init(sqlitePath: String) throws {
        self.protectionURL = nil
        try open(path: sqlitePath)
    }

    private func open(path: String) throws {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            db = nil
            throw StoreError.openFailed
        }
        do {
            try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA secure_delete=ON; PRAGMA trusted_schema=OFF; PRAGMA foreign_keys=ON; PRAGMA temp_store=MEMORY; PRAGMA busy_timeout=5000; PRAGMA journal_size_limit=4194304; CREATE TABLE IF NOT EXISTS kv(key TEXT PRIMARY KEY,value BLOB NOT NULL); CREATE TABLE IF NOT EXISTS messages(id TEXT PRIMARY KEY,session_id TEXT NOT NULL,sequence INTEGER NOT NULL,created_at REAL NOT NULL,json BLOB NOT NULL); CREATE INDEX IF NOT EXISTS idx_messages_session_sequence ON messages(session_id,sequence); CREATE INDEX IF NOT EXISTS idx_messages_session_created ON messages(session_id,created_at,id);")
            protectDatabaseFiles()
        } catch {
            if let db { sqlite3_close(db) }
            db = nil
            throw error
        }
    }

    deinit { sqlite3_close(db) }

    static func appStore() throws -> SQLiteStore {
        let fm = FileManager.default
        let root = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("RemoteAI", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.setAttributes([.protectionKey: fileProtection], ofItemAtPath: root.path)
        return try SQLiteStore(url: root.appendingPathComponent("cache.sqlite3"))
    }

    static func inMemory() throws -> SQLiteStore {
        try SQLiteStore(sqlitePath: ":memory:")
    }

    func put<T: Encodable>(_ value: T, key: String) throws {
        try putData(encoder.encode(value), key: key)
    }

    func get<T: Decodable>(_ type: T.Type, key: String) throws -> T? {
        guard let data = try getData(key: key) else { return nil }
        do { return try decoder.decode(T.self, from: data) }
        catch { throw StoreError.corruptData }
    }

    func setLastSequence(_ value: Int64) throws { try put(String(value), key: "sync.lastSequence") }
    func lastSequence() throws -> Int64 { Int64(try get(String.self, key: "sync.lastSequence") ?? "0") ?? 0 }
    func saveDraft(_ text: String, sessionId: String) throws { try put(text, key: "draft.\(sessionId)") }
    func draft(sessionId: String) throws -> String { try get(String.self, key: "draft.\(sessionId)") ?? "" }
    func saveUIState(_ value: String, key: String) throws { try put(value, key: "ui.\(key)") }

    func upsertMessages(_ messages: [ChatMessage]) throws {
        guard !messages.isEmpty else { return }
        let sql = "INSERT OR REPLACE INTO messages(id,session_id,sequence,created_at,json) VALUES(?,?,?,?,?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw StoreError.prepareFailed }
        defer { sqlite3_finalize(stmt) }

        try exec("BEGIN IMMEDIATE;")
        do {
            for message in messages {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                let data = try encoder.encode(message)
                guard data.count <= Self.maxMessageBytes else { throw StoreError.valueTooLarge }
                bindText(stmt, 1, message.id)
                bindText(stmt, 2, message.sessionId)
                sqlite3_bind_int64(stmt, 3, message.sequence ?? 0)
                sqlite3_bind_double(stmt, 4, message.createdAt.timeIntervalSince1970)
                data.withUnsafeBytes { ptr in
                    _ = sqlite3_bind_blob(stmt, 5, ptr.baseAddress, Int32(data.count), transient)
                }
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw StoreError.stepFailed }
            }
            try exec("COMMIT;")
            protectDatabaseFiles()
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    func recentMessages(sessionId: String, limit: Int) throws -> [ChatMessage] {
        Array(try queryMessages(sql: "SELECT json FROM messages WHERE session_id=? ORDER BY created_at DESC,id DESC LIMIT ?", sessionId: sessionId, cursor: nil, limit: limit).reversed())
    }

    func messagesBefore(sessionId: String, before: MessageCursor, limit: Int) throws -> [ChatMessage] {
        Array(try queryMessages(sql: "SELECT json FROM messages WHERE session_id=? AND (created_at<? OR (created_at=? AND id<?)) ORDER BY created_at DESC,id DESC LIMIT ?", sessionId: sessionId, cursor: before, limit: limit).reversed())
    }

    func messageCount(sessionId: String) throws -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM messages WHERE session_id=?", -1, &stmt, nil) == SQLITE_OK else { throw StoreError.prepareFailed }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, sessionId)
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw StoreError.stepFailed }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    func deleteMessage(id: String) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM messages WHERE id=?", -1, &stmt, nil) == SQLITE_OK else { throw StoreError.prepareFailed }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw StoreError.stepFailed }
        protectDatabaseFiles()
    }

    func clearAll() throws {
        try exec("BEGIN IMMEDIATE;")
        do {
            try exec("DELETE FROM messages; DELETE FROM kv; COMMIT;")
            try exec("PRAGMA wal_checkpoint(TRUNCATE);")
            protectDatabaseFiles()
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    func integrityCheck() throws -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA quick_check;", -1, &stmt, nil) == SQLITE_OK else { throw StoreError.prepareFailed }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else { throw StoreError.stepFailed }
        return String(cString: text) == "ok"
    }

    private func queryMessages(sql: String, sessionId: String, cursor: MessageCursor?, limit: Int) throws -> [ChatMessage] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw StoreError.prepareFailed }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, sessionId)
        var idx: Int32 = 2
        if let cursor {
            sqlite3_bind_double(stmt, idx, cursor.createdAt.timeIntervalSince1970); idx += 1
            sqlite3_bind_double(stmt, idx, cursor.createdAt.timeIntervalSince1970); idx += 1
            bindText(stmt, idx, cursor.messageId); idx += 1
        }
        sqlite3_bind_int(stmt, idx, Int32(max(1, min(limit, 100))))
        var result: [ChatMessage] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw StoreError.stepFailed }
            let count = Int(sqlite3_column_bytes(stmt, 0))
            guard count >= 0, count <= Self.maxMessageBytes, let blob = sqlite3_column_blob(stmt, 0) else { throw StoreError.corruptData }
            let data = Data(bytes: blob, count: count)
            do { result.append(try decoder.decode(ChatMessage.self, from: data)) }
            catch { throw StoreError.corruptData }
        }
        return result
    }

    private func putData(_ data: Data, key: String) throws {
        guard data.count <= Self.maxKVBytes else { throw StoreError.valueTooLarge }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO kv(key,value) VALUES(?,?)", -1, &stmt, nil) == SQLITE_OK else { throw StoreError.prepareFailed }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, key)
        data.withUnsafeBytes { ptr in
            _ = sqlite3_bind_blob(stmt, 2, ptr.baseAddress, Int32(data.count), transient)
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw StoreError.stepFailed }
        protectDatabaseFiles()
    }

    private func getData(key: String) throws -> Data? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM kv WHERE key=?", -1, &stmt, nil) == SQLITE_OK else { throw StoreError.prepareFailed }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, key)
        let step = sqlite3_step(stmt)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW else { throw StoreError.stepFailed }
        let count = Int(sqlite3_column_bytes(stmt, 0))
        guard count >= 0, count <= Self.maxKVBytes, let blob = sqlite3_column_blob(stmt, 0) else { throw StoreError.corruptData }
        return Data(bytes: blob, count: count)
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, (value as NSString).utf8String, -1, transient)
    }

    private func exec(_ sql: String) throws {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK { throw StoreError.stepFailed }
    }

    private func protectDatabaseFiles() {
        guard let protectionURL else { return }
        let fm = FileManager.default
        for path in [protectionURL.path, protectionURL.path + "-wal", protectionURL.path + "-shm"] where fm.fileExists(atPath: path) {
            try? fm.setAttributes([.protectionKey: Self.fileProtection], ofItemAtPath: path)
        }
    }
}

enum StoreError: Error, Equatable {
    case openFailed
    case prepareFailed
    case stepFailed
    case corruptData
    case valueTooLarge
}
