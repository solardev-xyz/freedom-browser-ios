#if DEBUG
import Foundation
import OSLog
import SQLite3

private let log = Logger(subsystem: "com.browser.Freedom", category: "AgentEngine")

/// The agent engine's storage: one SQLite connection, on its own queue, to a
/// file in Application Support/Agent. The engine's Pi runtime keeps its
/// conversations, tool calls and pending approvals here (AgentEngine/src/sqlite.js
/// sends each statement over the `sql` service), so they outlive the web view
/// and the app process.
///
/// WAL with `synchronous = NORMAL`, as Pi configures its own SQLite: a commit
/// survives the app being killed; the newest may be lost if the device loses power.
nonisolated final class AgentDatabase: @unchecked Sendable {
    enum Value: Sendable {
        case null, int(Int64), real(Double), text(String), blob(Data)
    }

    enum Operation: Sendable {
        case open(name: String)
        case wipe(name: String)
        case exec(sql: String)
        case run(sql: String, params: [Value])
        case all(sql: String, params: [Value], limit: Int?)
        case close
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// A reply for the engine: JSON-like values only.
    struct Reply: @unchecked Sendable {
        let value: Any?
    }

    private let queue = DispatchQueue(label: "com.browser.Freedom.agent-database")
    // Touched only on `queue`.
    private var db: OpaquePointer?
    private var openName: String?
    private var statements: [String: OpaquePointer] = [:]

    private static let statementCacheLimit = 256
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "Agent", directoryHint: .isDirectory)
    }

    /// Runs `operation` on the database queue.
    func perform(_ operation: Operation, completion: @escaping @Sendable (Result<Reply, Error>) -> Void) {
        queue.async {
            do {
                completion(.success(Reply(value: try self.execute(operation))))
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// Closes the connection; for the engine's teardown.
    func close() {
        queue.async { self.closeConnection() }
    }

    // MARK: - On `queue`

    private func execute(_ operation: Operation) throws -> Any? {
        switch operation {
        case .open(let name):
            try openConnection(name)
            return nil
        case .wipe(let name):
            if openName == name { closeConnection() }
            let file = try Self.file(name)
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(at: URL(filePath: file.path + suffix))
            }
            log.notice("[db] wiped \(name, privacy: .public)")
            return nil
        case .exec(let sql):
            try check(sqlite3_exec(try connection(), sql, nil, nil, nil))
            return nil
        case .run(let sql, let params):
            let statement = try prepared(sql, params)
            defer { sqlite3_reset(statement) }
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { break }
                guard code == SQLITE_ROW else { try check(code); break }
            }
            return Int(sqlite3_changes(db))
        case .all(let sql, let params, let limit):
            let statement = try prepared(sql, params)
            defer { sqlite3_reset(statement) }
            var rows: [[String: Any]] = []
            while limit.map({ rows.count < $0 }) ?? true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { break }
                guard code == SQLITE_ROW else { try check(code); break }
                rows.append(Self.row(statement))
            }
            return rows
        case .close:
            closeConnection()
            return nil
        }
    }

    private func openConnection(_ name: String) throws {
        if openName == name, let db {
            // A web view that died mid-transaction left it open: Pi's commit never happened.
            if sqlite3_get_autocommit(db) == 0 { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
            return
        }
        closeConnection()
        let file = try Self.file(name)
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let code = sqlite3_open_v2(file.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil)
        guard code == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(code)"
            sqlite3_close(handle)
            throw Failure(message: "Can't open the agent database: \(message)")
        }
        db = handle
        openName = name
        sqlite3_busy_timeout(handle, 5_000)
        for pragma in ["PRAGMA journal_mode = WAL", "PRAGMA synchronous = NORMAL", "PRAGMA wal_autocheckpoint = 1000"] {
            try check(sqlite3_exec(handle, pragma, nil, nil, nil))
        }
        log.notice("[db] opened \(name, privacy: .public)")
    }

    private func closeConnection() {
        for statement in statements.values { sqlite3_finalize(statement) }
        statements.removeAll()
        if let db {
            sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)
            sqlite3_close(db)
        }
        db = nil
        openName = nil
    }

    private func connection() throws -> OpaquePointer {
        guard let db else { throw Failure(message: "The agent database isn't open") }
        return db
    }

    private func prepared(_ sql: String, _ params: [Value]) throws -> OpaquePointer {
        let db = try connection()
        let statement: OpaquePointer
        if let cached = statements[sql] {
            statement = cached
            sqlite3_clear_bindings(statement)
        } else {
            var handle: OpaquePointer?
            try check(sqlite3_prepare_v2(db, sql, -1, &handle, nil))
            guard let handle else { throw Failure(message: "Empty SQL statement") }
            if statements.count >= Self.statementCacheLimit {
                for old in statements.values { sqlite3_finalize(old) }
                statements.removeAll()
            }
            statements[sql] = handle
            statement = handle
        }
        for (offset, value) in params.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32 = switch value {
            case .null: sqlite3_bind_null(statement, index)
            case .int(let n): sqlite3_bind_int64(statement, index, n)
            case .real(let x): sqlite3_bind_double(statement, index, x)
            case .text(let s): sqlite3_bind_text(statement, index, s, -1, Self.transient)
            case .blob(let data):
                data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), Self.transient) }
            }
            try check(code)
        }
        return statement
    }

    private func check(_ code: Int32) throws {
        guard code != SQLITE_OK, code != SQLITE_DONE, code != SQLITE_ROW else { return }
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite error \(code)"
        throw Failure(message: message)
    }

    private static func row(_ statement: OpaquePointer) -> [String: Any] {
        var row: [String: Any] = [:]
        for column in 0..<sqlite3_column_count(statement) {
            let name = String(cString: sqlite3_column_name(statement, column))
            switch sqlite3_column_type(statement, column) {
            case SQLITE_INTEGER:
                row[name] = NSNumber(value: sqlite3_column_int64(statement, column))
            case SQLITE_FLOAT:
                row[name] = NSNumber(value: sqlite3_column_double(statement, column))
            case SQLITE_TEXT:
                let bytes = sqlite3_column_text(statement, column)
                let count = Int(sqlite3_column_bytes(statement, column))
                row[name] = bytes.map { String(decoding: UnsafeBufferPointer(start: $0, count: count), as: UTF8.self) } ?? ""
            case SQLITE_BLOB:
                let count = Int(sqlite3_column_bytes(statement, column))
                let data = sqlite3_column_blob(statement, column).map { Data(bytes: $0, count: count) } ?? Data()
                row[name] = ["$blob": data.base64EncodedString()]
            default:
                row[name] = NSNull()
            }
        }
        return row
    }

    private static func file(_ name: String) throws -> URL {
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
            throw Failure(message: "Bad database name: \(name)")
        }
        return directory.appending(path: "\(name).sqlite")
    }
}

extension AgentDatabase.Operation {
    /// Parses one `sql` service message from the engine.
    nonisolated init(method: String, params: [String: Any]) throws {
        let sql = params["sql"] as? String ?? ""
        func values() throws -> [AgentDatabase.Value] {
            try (params["params"] as? [[String: Any]] ?? []).map { tagged in
                let v = tagged["v"]
                switch tagged["t"] as? String {
                case "null": return .null
                case "int":
                    guard let n = (v as? String).flatMap({ Int64($0) }) else { break }
                    return .int(n)
                case "real":
                    guard let x = (v as? NSNumber)?.doubleValue else { break }
                    return .real(x)
                case "text":
                    guard let s = v as? String else { break }
                    return .text(s)
                case "blob":
                    guard let data = (v as? String).flatMap({ Data(base64Encoded: $0) }) else { break }
                    return .blob(data)
                default: break
                }
                throw AgentDatabase.Failure(message: "Bad SQLite parameter: \(tagged)")
            }
        }
        switch method {
        case "open": self = .open(name: params["name"] as? String ?? "")
        case "wipe": self = .wipe(name: params["name"] as? String ?? "")
        case "exec": self = .exec(sql: sql)
        case "run": self = .run(sql: sql, params: try values())
        case "all": self = .all(sql: sql, params: try values(), limit: params["limit"] as? Int)
        case "close": self = .close
        default: throw AgentDatabase.Failure(message: "Unknown SQL operation: \(method)")
        }
    }
}
#endif
