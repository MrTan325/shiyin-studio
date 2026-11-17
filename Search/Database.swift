import Foundation
import SQLite3

final class Database {
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private(set) var hasTrigrams = false
    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw NSError(domain: "Database", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法打开索引数据库"] ) }
        sqlite3_busy_timeout(db, 5000)
        try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY, root TEXT NOT NULL, name TEXT NOT NULL, folded TEXT NOT NULL, ext TEXT, kind TEXT, size INTEGER, modified REAL, generation TEXT, duration REAL DEFAULT 0, bpm TEXT DEFAULT '', musical_key TEXT DEFAULT '', bitrate REAL DEFAULT 0, resolution TEXT DEFAULT '', fps REAL DEFAULT 0, state TEXT DEFAULT 'pending'); CREATE INDEX IF NOT EXISTS files_root ON files(root); CREATE INDEX IF NOT EXISTS files_kind ON files(kind);")
        do {
            try execute("CREATE VIRTUAL TABLE IF NOT EXISTS names USING fts5(folded, content='files', content_rowid='rowid', tokenize='trigram'); CREATE TRIGGER IF NOT EXISTS names_ai AFTER INSERT ON files BEGIN INSERT INTO names(rowid, folded) VALUES(new.rowid,new.folded); END; CREATE TRIGGER IF NOT EXISTS names_ad AFTER DELETE ON files BEGIN INSERT INTO names(names,rowid,folded) VALUES('delete',old.rowid,old.folded); END; CREATE TRIGGER IF NOT EXISTS names_au AFTER UPDATE OF folded ON files WHEN old.folded != new.folded BEGIN INSERT INTO names(names,rowid,folded) VALUES('delete',old.rowid,old.folded); INSERT INTO names(rowid,folded) VALUES(new.rowid,new.folded); END;")
            hasTrigrams = true
        } catch { hasTrigrams = false }
    }
    deinit { sqlite3_close(db) }
    private func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "数据库错误"
            sqlite3_free(error)
            throw NSError(domain: "Database", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
    private func statement(_ sql: String, _ values: [Any] = []) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        for (i, value) in values.enumerated() {
            let index = Int32(i + 1)
            if let value = value as? String { sqlite3_bind_text(stmt, index, value, -1, transient) }
            else if let value = value as? Int64 { sqlite3_bind_int64(stmt, index, value) }
            else if let value = value as? Double { sqlite3_bind_double(stmt, index, value) }
        }
        return stmt
    }
    @discardableResult private func run(_ sql: String, _ values: [Any] = []) -> Bool {
        guard let stmt = statement(sql, values) else { return false }; defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_DONE
    }
    func upsert(_ files: [FileRecord], root: String, generation: String) {
        lock.lock(); defer { lock.unlock() }
        try? execute("BEGIN IMMEDIATE")
        for f in files {
            run("INSERT INTO files(path,root,name,folded,ext,kind,size,modified,generation) VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(path) DO UPDATE SET root=excluded.root,name=excluded.name,folded=excluded.folded,ext=excluded.ext,kind=excluded.kind,size=excluded.size,modified=excluded.modified,generation=excluded.generation,state=CASE WHEN files.modified != excluded.modified OR files.size != excluded.size THEN 'pending' ELSE files.state END", [f.path,root,f.name,folded(f.name),f.ext,f.kind,f.size,f.modified,generation])
        }
        try? execute("COMMIT")
    }
    func finishScan(root: String, subtree: String, generation: String) {
        lock.lock(); defer { lock.unlock() }
        run("DELETE FROM files WHERE root=? AND (path=? OR path LIKE ? ESCAPE '\\') AND generation!=?", [root, subtree, likeEscape(subtree == "/" ? "/" : subtree + "/") + "%", generation])
    }
    func remove(path: String) {
        lock.lock(); defer { lock.unlock() }
        run("DELETE FROM files WHERE path=? OR path LIKE ? ESCAPE '\\'", [path,likeEscape(path == "/" ? "/" : path + "/") + "%"])
    }
    func retainRoots(_ roots: [String]) {
        lock.lock(); defer { lock.unlock() }
        if roots.isEmpty { run("DELETE FROM files"); return }
        run("DELETE FROM files WHERE root NOT IN (\(roots.map { _ in "?" }.joined(separator: ",")))", roots)
    }
    func updateMedia(path: String, modified: Double, size: Int64, info: MediaInfo) {
        lock.lock(); defer { lock.unlock() }
        run("UPDATE files SET duration=?,bpm=?,musical_key=?,bitrate=?,resolution=?,fps=?,state=? WHERE path=? AND modified=? AND size=?", [info.duration,info.bpm,info.key,info.bitrate,info.resolution,info.fps,info.state,path,modified,size])
    }
    func pending(limit: Int = 80) -> [FileRecord] {
        lock.lock(); defer { lock.unlock() }
        return rows("SELECT path,name,ext,kind,size,modified,duration,bpm,musical_key,bitrate,resolution,fps,state FROM files WHERE kind IN ('audio','video') AND state='pending' LIMIT \(limit)")
    }
    func retryMedia() { lock.lock(); defer { lock.unlock() }; run("UPDATE files SET state='pending' WHERE kind IN ('audio','video')") }
    private func likeEscape(_ text: String) -> String { text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") }
    func search(_ query: String, kind: String = "all", root: String? = nil, sort: String = "name", ascending: Bool = true, limit: Int = 2000) -> SearchResult {
        let start = Date(); lock.lock(); defer { lock.unlock() }
        let tokens = folded(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var conditions = [String](); var values = [Any]()
        let longTokens = tokens.filter { $0.count >= 3 }
        if hasTrigrams && !longTokens.isEmpty {
            conditions.append("rowid IN (SELECT rowid FROM names WHERE names MATCH ?)")
            values.append(longTokens.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " AND "))
        }
        for token in tokens { conditions.append("folded LIKE ? ESCAPE '\\'"); values.append("%" + likeEscape(token) + "%") }
        if kind != "all" { conditions.append("kind=?"); values.append(kind) }
        if let root { conditions.append("root=?"); values.append(root) }
        let clause = conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")
        var count = 0
        if let stmt = statement("SELECT COUNT(*) FROM files" + clause, values) { if sqlite3_step(stmt) == SQLITE_ROW { count = Int(sqlite3_column_int64(stmt, 0)) }; sqlite3_finalize(stmt) }
        let columns = ["name":"folded", "size":"size", "duration":"duration", "bpm":"CAST(bpm AS REAL)", "key":"musical_key", "bitrate":"bitrate", "fps":"fps", "path":"path", "ext":"ext", "resolution":"resolution"]
        let order = columns[sort] ?? "folded"
        let files = rows("SELECT path,name,ext,kind,size,modified,duration,bpm,musical_key,bitrate,resolution,fps,state FROM files" + clause + " ORDER BY \(order) \(ascending ? "ASC" : "DESC"),path ASC LIMIT \(max(1, min(limit,10000)))", values)
        return SearchResult(files: files, total: count, elapsed: Date().timeIntervalSince(start))
    }
    private func rows(_ sql: String, _ values: [Any] = []) -> [FileRecord] {
        guard let stmt = statement(sql,values) else { return [] }; defer { sqlite3_finalize(stmt) }
        func str(_ index: Int32) -> String { sqlite3_column_text(stmt,index).map { String(cString: $0) } ?? "" }
        var result = [FileRecord]()
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(FileRecord(path:str(0),name:str(1),ext:str(2),kind:str(3),size:sqlite3_column_int64(stmt,4),modified:sqlite3_column_double(stmt,5),duration:sqlite3_column_double(stmt,6),bpm:str(7),key:str(8),bitrate:sqlite3_column_double(stmt,9),resolution:str(10),fps:sqlite3_column_double(stmt,11),metadataState:str(12)))
        }
        return result
    }
}
