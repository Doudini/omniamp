import Foundation
import SQLite3

/// A small wrapper over the system SQLite: one connection, prepared statements cached by their SQL.
/// A connection is not shared between threads: the library keeps one for writing (on its own queue) and
/// one for reading (main thread). WAL lets them work at the same time.
final class SQLiteDB {
    struct Failure: Error, CustomStringConvertible {
        let code: Int32
        let message: String
        var description: String { "SQLite \(code): \(message)" }
    }

    private var db: OpaquePointer?
    private var cache: [String: Statement] = [:]

    init(path: String, readOnly: Bool = false) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        let rc = sqlite3_open_v2(path, &db, flags | SQLITE_OPEN_NOMUTEX, nil)
        guard rc == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            db = nil
            throw Failure(code: rc, message: msg)
        }
        sqlite3_busy_timeout(db, 5000)
    }

    deinit {
        cache.removeAll()   // statements finalize first
        sqlite3_close_v2(db)
    }

    var lastInsertID: Int64 { sqlite3_last_insert_rowid(db) }
    var changes: Int { Int(sqlite3_changes(db)) }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? ""
            sqlite3_free(err)
            throw Failure(code: rc, message: msg)
        }
    }

    /// A prepared statement, reused (reset, bindings cleared) the next time the same SQL comes along.
    func prepare(_ sql: String) throws -> Statement {
        if let s = cache[sql] { s.reset(); return s }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v3(db, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw Failure(code: rc, message: String(cString: sqlite3_errmsg(db))) }
        let s = Statement(stmt, db: db)
        cache[sql] = s
        return s
    }

    /// Run `sql` with `args` and hand each result row over.
    func query(_ sql: String, _ args: [SQLValue?] = [], row: (Statement) throws -> Void) throws {
        let s = try prepare(sql)
        defer { s.reset() }   // also when a row throws: an unreset statement holds an old read snapshot open
        try s.bind(args)
        while try s.step() { try row(s) }
    }

    /// Run a statement that returns nothing.
    func run(_ sql: String, _ args: [SQLValue?] = []) throws {
        let s = try prepare(sql)
        defer { s.reset() }
        try s.bind(args)
        while try s.step() {}
    }

    /// The first column of the first row.
    func scalar(_ sql: String, _ args: [SQLValue?] = []) throws -> Int64? {
        var out: Int64?
        try query(sql, args) { s in if out == nil { out = s.isNull(0) ? nil : s.int64(0) } }
        return out
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let r = try body()
            try exec("COMMIT")
            return r
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
}

/// A value bound to a statement parameter.
protocol SQLValue {}
extension Int: SQLValue {}
extension Int64: SQLValue {}
extension Double: SQLValue {}
extension String: SQLValue {}
extension Bool: SQLValue {}

final class Statement {
    private let stmt: OpaquePointer
    private let db: OpaquePointer?
    /// SQLite copies bound text right away (SQLITE_TRANSIENT).
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    fileprivate init(_ stmt: OpaquePointer, db: OpaquePointer?) {
        self.stmt = stmt
        self.db = db
    }

    deinit { sqlite3_finalize(stmt) }

    func reset() {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
    }

    func bind(_ args: [SQLValue?]) throws {
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch a {
            case nil: rc = sqlite3_bind_null(stmt, idx)
            case let v as Int: rc = sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Int64: rc = sqlite3_bind_int64(stmt, idx, v)
            case let v as Bool: rc = sqlite3_bind_int64(stmt, idx, v ? 1 : 0)
            case let v as Double: rc = sqlite3_bind_double(stmt, idx, v)
            case let v as String: rc = sqlite3_bind_text(stmt, idx, v, -1, Self.transient)
            default: rc = SQLITE_MISUSE
            }
            guard rc == SQLITE_OK else { throw SQLiteDB.Failure(code: rc, message: String(cString: sqlite3_errmsg(db))) }
        }
    }

    /// Next row: true while there are rows.
    func step() throws -> Bool {
        switch sqlite3_step(stmt) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        case let rc: throw SQLiteDB.Failure(code: rc, message: String(cString: sqlite3_errmsg(db)))
        }
    }

    func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
    func int64(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(stmt, i)) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    func text(_ i: Int32) -> String { sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
    func optText(_ i: Int32) -> String? { isNull(i) ? nil : text(i) }
    func optInt(_ i: Int32) -> Int? { isNull(i) ? nil : int(i) }
    func optDouble(_ i: Int32) -> Double? { isNull(i) ? nil : double(i) }
}
