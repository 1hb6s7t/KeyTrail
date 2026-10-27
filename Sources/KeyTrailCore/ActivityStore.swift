import Foundation
import CSQLite

public enum ActivityStoreError: Error, LocalizedError {
    case database(String)
    case invalidInput(String)
    public var errorDescription: String? {
        switch self { case .database(let message), .invalidInput(let message): return message }
    }
}

/// A single-caller store. Only minute counters, physical-key histograms and activity
/// second masks reach disk. Pending activity expires with this instance.
public final class ActivityStore {
    private var db: OpaquePointer?
    private let idleThreshold: TimeInterval
    private struct Window { var start: TimeInterval; var end: TimeInterval }
    private var keyboardWindows: [Window] = []
    private var mouseWindows: [Window] = []
    private var lastObserved: TimeInterval?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(url: URL, idleThreshold: TimeInterval = 30) throws {
        guard idleThreshold.isFinite, idleThreshold > 0, idleThreshold <= 3600 else {
            throw ActivityStoreError.invalidInput("活动窗口必须介于 0 与 3600 秒之间。")
        }
        self.idleThreshold = idleThreshold
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        let result = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开数据库"
            if let db { sqlite3_close(db) }; db = nil
            throw ActivityStoreError.database(message)
        }
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            sqlite3_busy_timeout(db, 5000)
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA secure_delete = ON")
            try execute("PRAGMA journal_mode = DELETE")
            try execute("PRAGMA synchronous = FULL")
            let version = try scalar("PRAGMA user_version")
            guard version == 0 || version == 1 else { throw ActivityStoreError.database("数据库版本不受支持。") }
            try transaction {
                try execute("""
                    CREATE TABLE IF NOT EXISTS minutes (
                        minute INTEGER PRIMARY KEY,
                        keys INTEGER NOT NULL DEFAULT 0,
                        left_clicks INTEGER NOT NULL DEFAULT 0,
                        right_clicks INTEGER NOT NULL DEFAULT 0,
                        middle_clicks INTEGER NOT NULL DEFAULT 0,
                        distance REAL NOT NULL DEFAULT 0,
                        scroll REAL NOT NULL DEFAULT 0,
                        keyboard_mask INTEGER NOT NULL DEFAULT 0,
                        mouse_mask INTEGER NOT NULL DEFAULT 0
                    )
                    """)
                try execute("""
                    CREATE TABLE IF NOT EXISTS key_histograms (
                        minute INTEGER NOT NULL REFERENCES minutes(minute) ON DELETE CASCADE,
                        label TEXT NOT NULL,
                        count INTEGER NOT NULL,
                        PRIMARY KEY (minute, label)
                    ) WITHOUT ROWID
                    """)
                try execute("PRAGMA user_version = 1")
            }
        } catch {
            sqlite3_close(db); db = nil; throw error
        }
    }

    deinit { if let db { sqlite3_close(db) } }

    public func ingest(_ samples: [InputSample], observedThrough: Date) throws {
        let now = try validatedObservation(observedThrough)
        for sample in samples {
            let timestamp = sample.timestamp.timeIntervalSince1970
            guard timestamp.isFinite, abs(timestamp) < 1e12, timestamp <= now,
                  sample.distancePoints.isFinite, sample.distancePoints >= 0,
                  sample.scrollDelta.isFinite else {
                throw ActivityStoreError.invalidInput("输入样本包含未来时间或无效数值。")
            }
        }
        var keyboard = keyboardWindows
        var mouse = mouseWindows
        for sample in samples {
            let window = Window(start: sample.timestamp.timeIntervalSince1970,
                                end: sample.timestamp.timeIntervalSince1970 + idleThreshold)
            if sample.kind == .keyPress { keyboard.append(window) } else { mouse.append(window) }
        }
        keyboard = merged(keyboard); mouse = merged(mouse)
        try transaction {
            for sample in samples { try persistCounter(sample) }
            try persistActivity(keyboard, through: now, keyboard: true)
            try persistActivity(mouse, through: now, keyboard: false)
        }
        keyboardWindows = remainder(keyboard, after: now)
        mouseWindows = remainder(mouse, after: now)
        lastObserved = now
    }

    public func advance(to: Date) throws {
        let now = try validatedObservation(to)
        try transaction {
            try persistActivity(keyboardWindows, through: now, keyboard: true)
            try persistActivity(mouseWindows, through: now, keyboard: false)
        }
        keyboardWindows = remainder(keyboardWindows, after: now)
        mouseWindows = remainder(mouseWindows, after: now)
        lastObserved = now
    }

    public func endActivity(at: Date) throws {
        try advance(to: at)
        keyboardWindows.removeAll(); mouseWindows.removeAll()
    }

    public func summary(in interval: DateInterval) throws -> ActivitySummary {
        var total = ActivitySummary()
        try readMinutes(in: interval) { _, value in
            total.keyPresses += value.keyPresses
            total.leftClicks += value.leftClicks; total.rightClicks += value.rightClicks
            total.middleClicks += value.middleClicks
            total.mouseDistancePoints += value.mouseDistancePoints; total.scrollUnits += value.scrollUnits
            total.keyboardActiveSeconds += value.keyboardActiveSeconds
            total.mouseActiveSeconds += value.mouseActiveSeconds
            total.totalActiveSeconds += value.totalActiveSeconds
            total.minuteCount += 1
            total.peakKeysPerMinute = max(total.peakKeysPerMinute, value.keyPresses)
        }
        let bounds = try validatedBounds(interval)
        if bounds.end > bounds.start {
            let statement = try prepare("SELECT label, SUM(count) FROM key_histograms WHERE minute >= ? AND minute < ? GROUP BY label")
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, minute(bounds.start)); sqlite3_bind_double(statement, 2, bounds.end)
            while try next(statement) {
                if let label = sqlite3_column_text(statement, 0) {
                    total.keyCounts[String(cString: label)] = Int(sqlite3_column_int64(statement, 1))
                }
            }
        }
        return total
    }

    /// Counter precision is a natural UTC minute. Start is rounded down; end is
    /// exclusive. Activity uses complete seconds inside the exact query interval.
    /// Querying never advances the collector clock or changes stored results.
    public func buckets(in interval: DateInterval) throws -> [MinuteBucket] {
        let bounds = try validatedBounds(interval)
        guard bounds.end > bounds.start else { return [] }
        // Two queries for any range length, never one histogram query per minute.
        let statement = try prepare("SELECT minute, label, count FROM key_histograms WHERE minute >= ? AND minute < ? ORDER BY minute, label")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, minute(bounds.start)); sqlite3_bind_double(statement, 2, bounds.end)
        var histograms: [Int64: [String: Int]] = [:]
        while try next(statement) {
            if let label = sqlite3_column_text(statement, 1) {
                histograms[sqlite3_column_int64(statement, 0), default: [:]][String(cString: label)] = Int(sqlite3_column_int64(statement, 2))
            }
        }
        var result: [MinuteBucket] = []
        try readMinutes(in: interval) { start, summary in
            var value = summary
            value.keyCounts = histograms[start] ?? [:]
            result.append(MinuteBucket(start: Date(timeIntervalSince1970: Double(start)), summary: value))
        }
        return result
    }

    private func readMinutes(in interval: DateInterval, visit: (Int64, ActivitySummary) -> Void) throws {
        let bounds = try validatedBounds(interval)
        guard bounds.end > bounds.start else { return }
        let statement = try prepare("""
            SELECT minute, keys, left_clicks, right_clicks, middle_clicks, distance, scroll,
                   keyboard_mask, mouse_mask FROM minutes WHERE minute >= ? AND minute < ? ORDER BY minute
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, minute(bounds.start)); sqlite3_bind_double(statement, 2, bounds.end)
        while try next(statement) {
            let start = sqlite3_column_int64(statement, 0)
            var value = ActivitySummary()
            value.keyPresses = Int(sqlite3_column_int64(statement, 1))
            value.leftClicks = Int(sqlite3_column_int64(statement, 2))
            value.rightClicks = Int(sqlite3_column_int64(statement, 3))
            value.middleClicks = Int(sqlite3_column_int64(statement, 4))
            value.mouseDistancePoints = sqlite3_column_double(statement, 5)
            value.scrollUnits = sqlite3_column_double(statement, 6)
            let queryMask = secondMask(start: max(Double(start), bounds.start),
                                       end: min(Double(start + 60), bounds.end), minute: start)
            let keyboard = UInt64(sqlite3_column_int64(statement, 7)) & queryMask
            let mouse = UInt64(sqlite3_column_int64(statement, 8)) & queryMask
            value.keyboardActiveSeconds = keyboard.nonzeroBitCount
            value.mouseActiveSeconds = mouse.nonzeroBitCount
            value.totalActiveSeconds = (keyboard | mouse).nonzeroBitCount
            value.minuteCount = 1; value.peakKeysPerMinute = value.keyPresses
            visit(start, value)
        }
    }

    /// Deletes every intersecting minute, including histogram rows. Pending
    /// windows are cut over the same interval to prevent later resurrection.
    public func delete(in interval: DateInterval) throws {
        let bounds = try validatedBounds(interval)
        guard bounds.end > bounds.start else { return }
        let lower = Double(minute(bounds.start)), upper = ceil(bounds.end / 60) * 60
        try transaction {
            let statement = try prepare("DELETE FROM minutes WHERE minute >= ? AND minute < ?")
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, lower); sqlite3_bind_double(statement, 2, upper)
            try finish(statement)
        }
        keyboardWindows = subtract(lower..<upper, from: keyboardWindows)
        mouseWindows = subtract(lower..<upper, from: mouseWindows)
    }

    public func clear() throws {
        try transaction { try execute("DELETE FROM minutes") }
        keyboardWindows.removeAll(); mouseWindows.removeAll()
    }

    public func exportCSV(in interval: DateInterval) throws -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        var lines = ["# KeyTrail minute aggregates; timestamps=UTC; cursor_distance=display_points; scroll=absolute_event_delta; activity=complete_seconds; peak=natural_minute",
                     "# range_start=\(formatter.string(from: interval.start)); range_end_exclusive=\(formatter.string(from: interval.end))",
                     "minute_utc,key_presses,left_clicks,right_clicks,middle_clicks,cursor_distance_points,scroll_units,keyboard_active_seconds,mouse_active_seconds,total_active_seconds,key_histogram"]
        for bucket in try buckets(in: interval) {
            let s = bucket.summary
            let histogram = s.keyCounts.keys.sorted().map { "\($0):\(s.keyCounts[$0]!)" }.joined(separator: ";")
            lines.append([formatter.string(from: bucket.start), String(s.keyPresses), String(s.leftClicks),
                          String(s.rightClicks), String(s.middleClicks), String(s.mouseDistancePoints),
                          String(s.scrollUnits), String(s.keyboardActiveSeconds), String(s.mouseActiveSeconds),
                          String(s.totalActiveSeconds), csvField(histogram)].joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    private func persistCounter(_ sample: InputSample) throws {
        let start = minute(sample.timestamp.timeIntervalSince1970)
        let statement = try prepare("""
            INSERT INTO minutes(minute, keys, left_clicks, right_clicks, middle_clicks, distance, scroll)
            VALUES(?, ?, ?, ?, ?, ?, ?) ON CONFLICT(minute) DO UPDATE SET
            keys=keys+excluded.keys, left_clicks=left_clicks+excluded.left_clicks,
            right_clicks=right_clicks+excluded.right_clicks, middle_clicks=middle_clicks+excluded.middle_clicks,
            distance=distance+excluded.distance, scroll=scroll+excluded.scroll
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, start)
        sqlite3_bind_int(statement, 2, sample.kind == .keyPress ? 1 : 0)
        sqlite3_bind_int(statement, 3, sample.kind == .leftClick ? 1 : 0)
        sqlite3_bind_int(statement, 4, sample.kind == .rightClick ? 1 : 0)
        sqlite3_bind_int(statement, 5, sample.kind == .middleClick ? 1 : 0)
        sqlite3_bind_double(statement, 6, sample.kind == .mouseMove ? sample.distancePoints : 0)
        sqlite3_bind_double(statement, 7, sample.kind == .scroll ? abs(sample.scrollDelta) : 0)
        try finish(statement)
        if sample.kind == .keyPress {
            let histogram = try prepare("""
                INSERT INTO key_histograms(minute, label, count) VALUES(?, ?, 1)
                ON CONFLICT(minute, label) DO UPDATE SET count=count+1
                """)
            defer { sqlite3_finalize(histogram) }
            sqlite3_bind_int64(histogram, 1, start)
            sqlite3_bind_text(histogram, 2, physicalLabel(sample.keyLabel), -1, transient)
            try finish(histogram)
        }
    }

    private func persistActivity(_ windows: [Window], through now: Double, keyboard: Bool) throws {
        for window in windows {
            let end = min(window.end, now)
            guard floor(end) > ceil(window.start) else { continue }
            var start = minute(window.start)
            while Double(start) < end {
                let mask = secondMask(start: window.start, end: end, minute: start)
                if mask != 0 {
                    let column = keyboard ? "keyboard_mask" : "mouse_mask"
                    let statement = try prepare("INSERT INTO minutes(minute, \(column)) VALUES(?, ?) ON CONFLICT(minute) DO UPDATE SET \(column)=\(column) | excluded.\(column)")
                    sqlite3_bind_int64(statement, 1, start); sqlite3_bind_int64(statement, 2, Int64(mask))
                    do { try finish(statement) } catch { sqlite3_finalize(statement); throw error }
                    sqlite3_finalize(statement)
                }
                start += 60
            }
        }
    }

    private func secondMask(start: Double, end: Double, minute: Int64) -> UInt64 {
        let lower = max(0, min(60, Int(ceil(start - Double(minute)))))
        let upper = max(0, min(60, Int(floor(end - Double(minute)))))
        guard upper > lower else { return 0 }
        return ((UInt64(1) << (upper - lower)) - 1) << lower
    }

    private func merged(_ windows: [Window]) -> [Window] {
        var result: [Window] = []
        for window in windows.sorted(by: { $0.start < $1.start }) {
            if let last = result.last, window.start <= last.end {
                result[result.count - 1].end = max(last.end, window.end)
            } else { result.append(window) }
        }
        return result
    }

    private func remainder(_ windows: [Window], after now: Double) -> [Window] {
        windows.compactMap { window in
            guard window.end > now else { return nil }
            return Window(start: max(window.start, floor(now)), end: window.end)
        }
    }

    private func subtract(_ range: Range<Double>, from windows: [Window]) -> [Window] {
        windows.flatMap { window -> [Window] in
            guard window.start < range.upperBound, window.end > range.lowerBound else { return [window] }
            var result: [Window] = []
            if window.start < range.lowerBound { result.append(Window(start: window.start, end: range.lowerBound)) }
            if window.end > range.upperBound { result.append(Window(start: range.upperBound, end: window.end)) }
            return result
        }
    }

    private func physicalLabel(_ input: String?) -> String {
        guard let input else { return "Other" }
        let labels: Set<String> = ["Space", "Return", "Enter", "Tab", "Escape", "Esc", "Delete", "Backspace", "Forward Delete", "ForwardDelete", "Caps Lock", "CapsLock", "NumLock", "ScrollLock", "Insert", "PrintScreen", "Caps", "Shift", "Control", "Ctrl", "Option", "Alt", "Windows", "Command", "Cmd", "Fn", "Left", "Right", "Up", "Down", "Home", "End", "Page Up", "Page Down", "PageUp", "PageDown", "Clear", "Help", "Other", "-", "=", "[", "]", "\\", ";", "'", ",", ".", "/", "`", "+", "*", "←", "→", "↑", "↓"]
        if labels.contains(input) { return input }
        if input.hasPrefix("Num "), Set(["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", ".", "*", "+", "/", "Enter", "-", "="]).contains(String(input.dropFirst(4))) { return input }
        if input.count == 1, let scalar = input.unicodeScalars.first,
           (65...90).contains(scalar.value) || (48...57).contains(scalar.value) { return input }
        if input.first == "F", let number = Int(input.dropFirst()), (1...20).contains(number) { return "F\(number)" }
        return "Other"
    }

    private func validatedObservation(_ date: Date) throws -> Double {
        let timestamp = date.timeIntervalSince1970
        guard timestamp.isFinite, abs(timestamp) < 1e12 else { throw ActivityStoreError.invalidInput("无效观察时间。") }
        guard lastObserved.map({ timestamp >= $0 }) ?? true else {
            throw ActivityStoreError.invalidInput("观察时间不得倒退；系统时间改变后请重新启动采集。")
        }
        return timestamp
    }

    private func validatedBounds(_ interval: DateInterval) throws -> (start: Double, end: Double) {
        let start = interval.start.timeIntervalSince1970, end = interval.end.timeIntervalSince1970
        guard start.isFinite, end.isFinite, abs(start) < 1e12, abs(end) < 1e12, end >= start else {
            throw ActivityStoreError.invalidInput("无效查询区间。")
        }
        return (start, end)
    }

    private func minute(_ seconds: Double) -> Int64 { Int64(floor(seconds / 60) * 60) }
    private func csvField(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    private func failure() -> ActivityStoreError { .database(String(cString: sqlite3_errmsg(db))) }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        return statement
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func finish(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }
    private func next(_ statement: OpaquePointer) throws -> Bool {
        switch sqlite3_step(statement) { case SQLITE_ROW: return true; case SQLITE_DONE: return false; default: throw failure() }
    }
    private func scalar(_ sql: String) throws -> Int {
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
        return try next(statement) ? Int(sqlite3_column_int64(statement, 0)) : 0
    }
    private func transaction(_ operation: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try operation(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }
}
