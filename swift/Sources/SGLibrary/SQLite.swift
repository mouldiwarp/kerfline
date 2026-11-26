// A small wrapper over the system SQLite (libsqlite3, no dependency). The library actor owns one
// connection and uses it from its own isolation only.

import Foundation
import SQLite3

public struct LibraryError: Error, LocalizedError, CustomStringConvertible, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
    public var errorDescription: String? { message }
}

/// A value read from a row.
enum SQLValue: Equatable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
}

struct Row {
    var values: [String: SQLValue]
    func string(_ c: String) -> String? {
        if case let .text(s) = values[c] { return s }
        return nil
    }
    func int(_ c: String) -> Int? {
        switch values[c] {
        case let .int(i): Int(i)
        case let .double(d): Int(d)
        default: nil
        }
    }
    func double(_ c: String) -> Double? {
        switch values[c] {
        case let .int(i): Double(i)
        case let .double(d): d
        default: nil
        }
    }
    func int64(_ c: String) -> Int64? {
        if case let .int(i) = values[c] { return i }
        return nil
    }
}

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class Database {
    private var db: OpaquePointer?
    private var depth = 0

    init(path: String) throws {
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) != SQLITE_OK {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            throw LibraryError("Couldn't open the library database: \(msg)")
        }
        sqlite3_busy_timeout(db, 2000)
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
    }

    deinit { sqlite3_close(db) }

    var userVersion: Int {
        get { (try? query("PRAGMA user_version").first?.int("user_version")) ?? 0 }
    }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(err)
            throw LibraryError("Database error: \(msg)")
        }
    }

    /// Run a statement that returns no rows.
    @discardableResult
    func run(_ sql: String, _ args: [Any?] = []) throws -> Int {
        _ = try query(sql, args)
        return Int(sqlite3_changes(db))
    }

    func query(_ sql: String, _ args: [Any?] = []) throws -> [Row] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw error(sql) }
        defer { sqlite3_finalize(stmt) }
        for (i, arg) in args.enumerated() {
            let n = Int32(i + 1)
            switch arg {
            case nil: sqlite3_bind_null(stmt, n)
            case let v as String: sqlite3_bind_text(stmt, n, v, -1, transient)
            case let v as Int: sqlite3_bind_int64(stmt, n, Int64(v))
            case let v as Int64: sqlite3_bind_int64(stmt, n, v)
            case let v as Bool: sqlite3_bind_int64(stmt, n, v ? 1 : 0)
            case let v as Double: sqlite3_bind_double(stmt, n, v)
            default: throw LibraryError("Can't store a \(type(of: arg!)) in the database")
            }
        }
        var rows: [Row] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw error(sql) }
            var values: [String: SQLValue] = [:]
            for c in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, c))
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: values[name] = .int(sqlite3_column_int64(stmt, c))
                case SQLITE_FLOAT: values[name] = .double(sqlite3_column_double(stmt, c))
                case SQLITE_TEXT: values[name] = .text(String(cString: sqlite3_column_text(stmt, c)))
                default: values[name] = .null
                }
            }
            rows.append(Row(values: values))
        }
        return rows
    }

    /// All or nothing. Nested calls join the outer transaction.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        if depth > 0 {
            depth += 1
            defer { depth -= 1 }
            return try body()
        }
        try exec("BEGIN IMMEDIATE")
        depth = 1
        do {
            let r = try body()
            depth = 0
            try exec("COMMIT")
            return r
        } catch {
            depth = 0
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func error(_ sql: String) -> LibraryError {
        LibraryError("Database error: \(String(cString: sqlite3_errmsg(db))) in \(sql.prefix(60))")
    }
}
