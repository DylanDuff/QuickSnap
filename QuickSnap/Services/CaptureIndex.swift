//
//  CaptureIndex.swift
//  QuickSnap
//

import Foundation
import SQLite3

/// One capture as the index knows it.
nonisolated struct CaptureIndexEntry: Sendable {
    let url: URL
    let name: String
    let appName: String?
    let windowTitle: String?
    /// The AI description, when there is one. Nil is normal.
    let caption: String?
    /// Everything the capture says, from OCR. May be empty.
    let transcript: String
    let modifiedAt: Date
}

/// A hit, with enough to draw a row without touching the database again.
nonisolated struct CaptureSearchResult: Sendable, Identifiable, Equatable {
    let url: URL
    let name: String
    let appName: String?
    let windowTitle: String?
    let caption: String?
    /// The matching stretch of transcript, with an ellipsis where it was
    /// cut. Empty when the match was in the name or caption instead.
    let snippet: String
    let modifiedAt: Date

    var id: URL { url }
}

nonisolated enum CaptureIndexError: LocalizedError {
    case cannotOpenDatabase(String)
    case sqlite(String)

    var errorDescription: String? {
        switch self {
        case .cannotOpenDatabase(let detail): return "Couldn't open the capture index: \(detail)"
        case .sqlite(let detail): return detail
        }
    }
}

/// Full-text index of the save folder, so a screenshot can be found by what
/// it says or what it shows rather than by scrolling a grid of thumbnails.
///
/// **SQLite FTS5 through the system `libsqlite3`** — `import SQLite3`, no
/// package and no dependency. macOS ships FTS5 compiled in (verified), and
/// the alternative of a JSON file re-read and re-scanned on every keystroke
/// gives up ranking and falls over once a folder has a few thousand
/// captures.
///
/// **The database lives in Application Support, not the save folder.** It is
/// derived data that QuickSnap can rebuild from the captures at any time;
/// the save folder belongs to the user, who may sync it, and a stray
/// `.sqlite` in there would be QuickSnap's mess in someone else's drawer.
///
/// An `actor` rather than the usual stateless enum: it owns a database
/// connection, which is exactly the mutable state Services normally avoid.
/// Actor isolation is what makes that connection safe to use from the
/// capture path, the backfill and the search field at once.
actor CaptureIndex {
    static let shared = CaptureIndex()

    private var database: OpaquePointer?

    /// Column order matters twice below: `bm25` takes one weight per column
    /// in this order, and `snippet` takes a column index.
    private static let transcriptColumnIndex: Int32 = 4

    /// Ranking weights, in column order. The name and the caption say what a
    /// capture *is*; the transcript is everything that happened to be on
    /// screen, so a stray word in it shouldn't outrank a capture actually
    /// named for the thing. The two unindexed columns take 0.
    private static let rankWeights = "8.0, 4.0, 4.0, 6.0, 1.0, 0.0, 0.0"

    private init() {}

    // MARK: - Writing

    /// Adds or replaces `entry`. FTS5 has no unique constraint, so a replace
    /// is a delete followed by an insert.
    func index(_ entry: CaptureIndexEntry) throws {
        let database = try openDatabase()
        try deleteRows(forPath: entry.url.path, in: database)

        let sql = """
            INSERT INTO captures (name, app, window, caption, transcript, path, modified)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """
        let statement = try prepare(sql, in: database)
        defer { sqlite3_finalize(statement) }

        bind(entry.name, to: statement, at: 1)
        bind(entry.appName ?? "", to: statement, at: 2)
        bind(entry.windowTitle ?? "", to: statement, at: 3)
        bind(entry.caption ?? "", to: statement, at: 4)
        bind(entry.transcript, to: statement, at: 5)
        bind(entry.url.path, to: statement, at: 6)
        sqlite3_bind_double(statement, 7, entry.modifiedAt.timeIntervalSince1970)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw CaptureIndexError.sqlite(lastErrorMessage(in: database))
        }
    }

    func remove(_ urls: [URL]) throws {
        guard !urls.isEmpty else { return }
        let database = try openDatabase()
        for url in urls {
            try deleteRows(forPath: url.path, in: database)
        }
    }

    /// Moves a row with the file, so a `{describe}` rename doesn't orphan
    /// the entry it just indexed.
    func move(from oldURL: URL, to newURL: URL) throws {
        let database = try openDatabase()
        let statement = try prepare("UPDATE captures SET path = ?, name = ? WHERE path = ?", in: database)
        defer { sqlite3_finalize(statement) }
        bind(newURL.path, to: statement, at: 1)
        bind(newURL.deletingPathExtension().lastPathComponent, to: statement, at: 2)
        bind(oldURL.path, to: statement, at: 3)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw CaptureIndexError.sqlite(lastErrorMessage(in: database))
        }
    }

    func removeAll() throws {
        let database = try openDatabase()
        try execute("DELETE FROM captures", in: database)
    }

    /// Drops rows whose file is no longer in `existingPaths`, returning how
    /// many went. The user can move, rename or delete captures outside the
    /// app, and a hit that opens nothing is worse than no hit.
    @discardableResult
    func reconcile(against existingPaths: Set<String>) throws -> Int {
        let database = try openDatabase()
        let stale = try indexedPaths().subtracting(existingPaths)
        for path in stale {
            try deleteRows(forPath: path, in: database)
        }
        return stale.count
    }

    // MARK: - Reading

    /// Every indexed path with the modification date it was indexed at — the
    /// backfill's work list, so a file that hasn't changed is skipped.
    func fingerprints() throws -> [String: Date] {
        let database = try openDatabase()
        let statement = try prepare("SELECT path, modified FROM captures", in: database)
        defer { sqlite3_finalize(statement) }

        var result: [String: Date] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let path = string(from: statement, at: 0) else { continue }
            result[path] = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
        }
        return result
    }

    func count() throws -> Int {
        let database = try openDatabase()
        let statement = try prepare("SELECT count(*) FROM captures", in: database)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// Ranked matches for `query`, best first. Rows whose file has since
    /// disappeared are dropped *and* deleted, so the index self-heals as
    /// it's used rather than only when a reconcile runs.
    func search(_ query: String, limit: Int = 40) throws -> [CaptureSearchResult] {
        guard let expression = Self.matchExpression(for: query) else { return [] }
        let database = try openDatabase()

        let sql = """
            SELECT path, name, app, window, caption, modified,
                   snippet(captures, \(Self.transcriptColumnIndex), '', '', '…', 12)
            FROM captures
            WHERE captures MATCH ?
            ORDER BY bm25(captures, \(Self.rankWeights))
            LIMIT ?
            """
        let statement = try prepare(sql, in: database)
        defer { sqlite3_finalize(statement) }
        bind(expression, to: statement, at: 1)
        sqlite3_bind_int(statement, 2, Int32(max(1, limit)))

        var results: [CaptureSearchResult] = []
        var missingPaths: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let path = string(from: statement, at: 0) else { continue }
            guard FileManager.default.fileExists(atPath: path) else {
                missingPaths.append(path)
                continue
            }
            results.append(CaptureSearchResult(
                url: URL(fileURLWithPath: path),
                name: string(from: statement, at: 1) ?? "",
                appName: nonEmptyString(from: statement, at: 2),
                windowTitle: nonEmptyString(from: statement, at: 3),
                caption: nonEmptyString(from: statement, at: 4),
                snippet: Self.flattened(string(from: statement, at: 6)),
                modifiedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
            ))
        }

        for path in missingPaths {
            try? deleteRows(forPath: path, in: database)
        }
        return results
    }

    /// A transcript is OCR output, one line per observation, so a snippet cut
    /// from it arrives as a vertical column of fragments — unreadable in a
    /// one-line list row and needless bulk in an MCP response. Collapsing to
    /// single spaces is done here rather than in either consumer, since
    /// neither wants the line breaks.
    private static func flattened(_ snippet: String?) -> String {
        (snippet ?? "")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Turns whatever was typed into an FTS5 MATCH expression.
    ///
    /// Everything that isn't a letter or digit is a separator, which is
    /// deliberately blunt: it means no part of the user's text can reach
    /// FTS5's own query syntax, where a stray `"` or `*` is a syntax error
    /// and `NOT`/`NEAR` would quietly change the search. Each term is
    /// quoted and prefix-matched, and terms are ANDed — typing more words
    /// narrows, which is what a search field is expected to do.
    ///
    /// Returns nil when there's nothing searchable, so callers can show
    /// their empty state rather than run a query matching everything.
    static func matchExpression(for query: String) -> String? {
        let terms = query
            .split { !$0.isLetter && !$0.isNumber }
            .map { $0.lowercased() }
        guard !terms.isEmpty else { return nil }
        return terms.map { "\"\($0)\"*" }.joined(separator: " AND ")
    }

    // MARK: - Database

    static var databaseURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent("QuickSnap", isDirectory: true)
            .appendingPathComponent("index.sqlite")
    }

    private func openDatabase() throws -> OpaquePointer {
        if let database { return database }

        let url = Self.databaseURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var handle: OpaquePointer?
        let status = sqlite3_open_v2(
            url.path,
            &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard status == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "status \(status)"
            sqlite3_close_v2(handle)
            throw CaptureIndexError.cannotOpenDatabase(message)
        }

        // `remove_diacritics 2` folds accents, so "café" is found by "cafe".
        try execute(
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS captures USING fts5(
                name, app, window, caption, transcript,
                path UNINDEXED, modified UNINDEXED,
                tokenize = 'unicode61 remove_diacritics 2'
            )
            """,
            in: handle
        )

        database = handle
        return handle
    }

    private func indexedPaths() throws -> Set<String> {
        let database = try openDatabase()
        let statement = try prepare("SELECT path FROM captures", in: database)
        defer { sqlite3_finalize(statement) }

        var paths: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let path = string(from: statement, at: 0) { paths.insert(path) }
        }
        return paths
    }

    private func deleteRows(forPath path: String, in database: OpaquePointer) throws {
        let statement = try prepare("DELETE FROM captures WHERE path = ?", in: database)
        defer { sqlite3_finalize(statement) }
        bind(path, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw CaptureIndexError.sqlite(lastErrorMessage(in: database))
        }
    }

    private func execute(_ sql: String, in database: OpaquePointer) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(error)
            throw CaptureIndexError.sqlite(message)
        }
    }

    private func prepare(_ sql: String, in database: OpaquePointer) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw CaptureIndexError.sqlite(lastErrorMessage(in: database))
        }
        return statement
    }

    private func lastErrorMessage(in database: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(database))
    }

    /// `SQLITE_TRANSIENT` — tells SQLite to copy the bytes, since the Swift
    /// string's storage isn't guaranteed to outlive the call.
    private func bind(_ value: String, to statement: OpaquePointer?, at index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, Self.transient)
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func string(from statement: OpaquePointer?, at column: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: text)
    }

    private func nonEmptyString(from statement: OpaquePointer?, at column: Int32) -> String? {
        let value = string(from: statement, at: column)
        return value?.isEmpty == false ? value : nil
    }
}
