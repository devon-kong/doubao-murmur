import Darwin
import Foundation
import SQLite3

struct PasteOrderIdentity: Codable, Equatable, Hashable {
    let requestId: UUID
    let controllerSessionId: UUID
    let sequence: Int64
}

struct PasteOrderEvent: Equatable {
    let identity: PasteOrderIdentity
    let side: String
    let processInstanceId: UUID
    let event: String
    let eventAtUTCMilliseconds: Int64
    let eventAtMonotonicNanoseconds: UInt64
    let protocolVersion: Int
    let textLength: Int?
    let textSHA256: String?
    let targetProcessIdentifier: Int32?
    let targetBundleIdentifier: String?
    let pasteboardChangeCount: Int?
    let httpStatus: Int?
    let errorCode: Int32?
    let durationMilliseconds: Double?
    let detailsJSON: String?

    static func capture(
        identity: PasteOrderIdentity,
        side: String,
        processInstanceId: UUID,
        event: String,
        protocolVersion: Int,
        textLength: Int? = nil,
        textSHA256: String? = nil,
        targetProcessIdentifier: Int32? = nil,
        targetBundleIdentifier: String? = nil,
        pasteboardChangeCount: Int? = nil,
        httpStatus: Int? = nil,
        errorCode: Int32? = nil,
        durationMilliseconds: Double? = nil,
        detailsJSON: String? = nil
    ) -> PasteOrderEvent {
        PasteOrderEvent(
            identity: identity,
            side: side,
            processInstanceId: processInstanceId,
            event: event,
            eventAtUTCMilliseconds: Int64((Date().timeIntervalSince1970 * 1_000).rounded()),
            eventAtMonotonicNanoseconds: DispatchTime.now().uptimeNanoseconds,
            protocolVersion: protocolVersion,
            textLength: textLength,
            textSHA256: textSHA256,
            targetProcessIdentifier: targetProcessIdentifier,
            targetBundleIdentifier: targetBundleIdentifier,
            pasteboardChangeCount: pasteboardChangeCount,
            httpStatus: httpStatus,
            errorCode: errorCode,
            durationMilliseconds: durationMilliseconds,
            detailsJSON: detailsJSON
        )
    }
}

/// Append-only diagnostic event writer. Event timestamps are captured by the
/// caller before this class dispatches SQLite work to its private queue.
final class PasteOrderEventLogger {
    private static let queueKey = DispatchSpecificKey<UUID>()
    struct StoredEventSummary: Equatable {
        let event: String
        let eventAtUTCMilliseconds: Int64
        let eventAtMonotonicNanoseconds: Int64
        let textSHA256: String?
        let detailsJSON: String?
    }
    static let schemaVersion = 1
    static let defaultMaximumRows = 50_000

    let side: String
    let processInstanceId: UUID
    let databaseURL: URL
    private let queue: DispatchQueue
    private let queueIdentifier = UUID()
    private let maximumRows: Int
    private var database: OpaquePointer?
    private var insertedSincePrune = 0

    init(
        side: String,
        databaseURL: URL,
        processInstanceId: UUID = UUID(),
        maximumRows: Int = PasteOrderEventLogger.defaultMaximumRows
    ) {
        self.side = side
        self.databaseURL = databaseURL
        self.processInstanceId = processInstanceId
        self.maximumRows = max(100, maximumRows)
        queue = DispatchQueue(label: "com.doubao.murmur.paste-order-events.\(side)", qos: .utility)
        queue.setSpecific(key: Self.queueKey, value: queueIdentifier)
        queue.async { self.openAndPrepareDatabase() }
    }

    static func defaultDatabaseURL(side: String) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support
            .appendingPathComponent("Doubao Murmur", isDirectory: true)
            .appendingPathComponent("paste-orders-\(side).sqlite3")
    }

    func capture(
        identity: PasteOrderIdentity,
        event: String,
        protocolVersion: Int,
        textLength: Int? = nil,
        targetProcessIdentifier: Int32? = nil,
        targetBundleIdentifier: String? = nil,
        pasteboardChangeCount: Int? = nil,
        httpStatus: Int? = nil,
        errorCode: Int32? = nil,
        durationMilliseconds: Double? = nil,
        detailsJSON: String? = nil
    ) {
        // Production intentionally never supplies textSHA256. Short dictated
        // strings are guessable even when only an unsalted hash is retained.
        let snapshot = PasteOrderEvent.capture(
            identity: identity,
            side: side,
            processInstanceId: processInstanceId,
            event: event,
            protocolVersion: protocolVersion,
            textLength: textLength,
            targetProcessIdentifier: targetProcessIdentifier,
            targetBundleIdentifier: targetBundleIdentifier,
            pasteboardChangeCount: pasteboardChangeCount,
            httpStatus: httpStatus,
            errorCode: errorCode,
            durationMilliseconds: durationMilliseconds,
            detailsJSON: detailsJSON
        )
        record(snapshot)
    }

    private func record(_ event: PasteOrderEvent) {
        queue.async { self.insert(event) }
    }

    /// Test/diagnostic synchronization only; production event recording never
    /// waits for SQLite.
    func flush() {
        guard DispatchQueue.getSpecific(key: Self.queueKey) != queueIdentifier else { return }
        queue.sync {}
    }

    func storedEventSummaries() -> [StoredEventSummary] {
        queue.sync {
            guard let database else { return [] }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                database,
                "SELECT event, event_at_utc_ms, event_at_monotonic_ns, text_sha256, details_json FROM paste_order_events ORDER BY row_id;",
                -1,
                &statement,
                nil
            ) == SQLITE_OK, let statement else { return [] }
            defer { sqlite3_finalize(statement) }
            var result: [StoredEventSummary] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let hash = sqlite3_column_text(statement, 3).map { String(cString: $0) }
                let details = sqlite3_column_text(statement, 4).map { String(cString: $0) }
                result.append(
                    StoredEventSummary(
                        event: String(cString: sqlite3_column_text(statement, 0)),
                        eventAtUTCMilliseconds: sqlite3_column_int64(statement, 1),
                        eventAtMonotonicNanoseconds: sqlite3_column_int64(statement, 2),
                        textSHA256: hash,
                        detailsJSON: details
                    )
                )
            }
            return result
        }
    }

    func schemaColumnNames() -> Set<String> {
        queue.sync {
            guard let database else { return [] }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "PRAGMA table_info(paste_order_events);", -1, &statement, nil) == SQLITE_OK,
                  let statement else { return [] }
            defer { sqlite3_finalize(statement) }
            var names: Set<String> = []
            while sqlite3_step(statement) == SQLITE_ROW,
                  let value = sqlite3_column_text(statement, 1) {
                names.insert(String(cString: value))
            }
            return names
        }
    }

    private func openAndPrepareDatabase() {
        do {
            try FileManager.default.createDirectory(
                at: databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            fputs("Paste order log directory failed: \(error.localizedDescription)\n", stderr)
            return
        }
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK else {
            fputs("Paste order log database open failed.\n", stderr)
            if let database { sqlite3_close(database) }
            database = nil
            return
        }
        _ = chmod(databaseURL.path, S_IRUSR | S_IWUSR)
        execute("PRAGMA journal_mode=WAL;")
        execute("PRAGMA synchronous=NORMAL;")
        execute("PRAGMA user_version=\(Self.schemaVersion);")
        execute("""
        CREATE TABLE IF NOT EXISTS paste_order_events (
          row_id INTEGER PRIMARY KEY AUTOINCREMENT,
          request_id TEXT NOT NULL,
          controller_session_id TEXT NOT NULL,
          sequence INTEGER NOT NULL,
          process_instance_id TEXT NOT NULL,
          side TEXT NOT NULL,
          event TEXT NOT NULL,
          event_at_utc_ms INTEGER NOT NULL,
          event_at_monotonic_ns INTEGER NOT NULL,
          protocol_version INTEGER NOT NULL,
          text_length INTEGER,
          text_sha256 TEXT,
          target_pid INTEGER,
          target_bundle_id TEXT,
          pasteboard_change_count INTEGER,
          http_status INTEGER,
          error_code INTEGER,
          duration_ms REAL,
          details_json TEXT
        );
        """)
        execute("CREATE INDEX IF NOT EXISTS idx_paste_order_identity ON paste_order_events(controller_session_id, sequence, request_id);")
        enforceFilePermissions()
        pruneIfNeeded(force: true)
    }

    private func insert(_ event: PasteOrderEvent) {
        guard let database else { return }
        let sql = """
        INSERT INTO paste_order_events (
          request_id, controller_session_id, sequence, process_instance_id,
          side, event, event_at_utc_ms, event_at_monotonic_ns,
          protocol_version, text_length, text_sha256, target_pid,
          target_bundle_id, pasteboard_change_count, http_status, error_code,
          duration_ms, details_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        func bindText(_ index: Int32, _ value: String?) {
            if let value { sqlite3_bind_text(statement, index, value, -1, transient) }
            else { sqlite3_bind_null(statement, index) }
        }
        func bindInt(_ index: Int32, _ value: Int64?) {
            if let value { sqlite3_bind_int64(statement, index, value) }
            else { sqlite3_bind_null(statement, index) }
        }
        bindText(1, event.identity.requestId.uuidString)
        bindText(2, event.identity.controllerSessionId.uuidString)
        bindInt(3, event.identity.sequence)
        bindText(4, event.processInstanceId.uuidString)
        bindText(5, event.side)
        bindText(6, event.event)
        bindInt(7, event.eventAtUTCMilliseconds)
        bindInt(8, Int64(bitPattern: event.eventAtMonotonicNanoseconds))
        bindInt(9, Int64(event.protocolVersion))
        bindInt(10, event.textLength.map(Int64.init))
        bindText(11, event.textSHA256)
        bindInt(12, event.targetProcessIdentifier.map(Int64.init))
        bindText(13, event.targetBundleIdentifier)
        bindInt(14, event.pasteboardChangeCount.map(Int64.init))
        bindInt(15, event.httpStatus.map(Int64.init))
        bindInt(16, event.errorCode.map(Int64.init))
        if let duration = event.durationMilliseconds { sqlite3_bind_double(statement, 17, duration) }
        else { sqlite3_bind_null(statement, 17) }
        bindText(18, event.detailsJSON)
        guard sqlite3_step(statement) == SQLITE_DONE else { return }
        enforceFilePermissions()
        insertedSincePrune += 1
        pruneIfNeeded(force: false)
    }

    private func pruneIfNeeded(force: Bool) {
        guard force || insertedSincePrune >= 512 else { return }
        insertedSincePrune = 0
        execute("DELETE FROM paste_order_events WHERE row_id NOT IN (SELECT row_id FROM paste_order_events ORDER BY row_id DESC LIMIT \(maximumRows));")
    }

    private func execute(_ sql: String) {
        guard let database else { return }
        var message: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(database, sql, nil, nil, &message) != SQLITE_OK {
            if let message { fputs("Paste order log SQLite error: \(String(cString: message))\n", stderr) }
            sqlite3_free(message)
        }
    }

    private func enforceFilePermissions() {
        for path in [databaseURL.path, databaseURL.path + "-wal", databaseURL.path + "-shm"] {
            if FileManager.default.fileExists(atPath: path) {
                _ = chmod(path, S_IRUSR | S_IWUSR)
            }
        }
    }

    deinit {
        let closeDatabase = { [database] in
            if let database { sqlite3_close(database) }
        }
        if DispatchQueue.getSpecific(key: Self.queueKey) == queueIdentifier {
            closeDatabase()
        } else {
            queue.sync(execute: closeDatabase)
        }
    }
}
