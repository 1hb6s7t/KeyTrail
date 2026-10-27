import XCTest
import CSQLite
@testable import KeyTrailCore

final class ActivityStoreTests: XCTestCase {
    private var directory: URL!
    private var url: URL { directory.appendingPathComponent("activity.sqlite") }
    private let origin: TimeInterval = 1_735_689_600 // 2025-01-01 00:00 UTC, minute aligned
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: origin + seconds) }
    private func interval(_ start: Double, _ end: Double) -> DateInterval { DateInterval(start: date(start), end: date(end)) }
    private func key(_ seconds: Double, _ label: String = "A") -> InputSample { InputSample(timestamp: date(seconds), kind: .keyPress, keyLabel: label) }

    func testActiveWindowsUnionWithoutFutureOrQueryAccrual() throws {
        let store = try ActivityStore(url: url)
        try store.ingest([key(0), key(10), InputSample(timestamp: date(5), kind: .leftClick)], observedThrough: date(15))
        var result = try store.summary(in: interval(0, 3600))
        XCTAssertEqual(result.keyboardActiveSeconds, 15)
        XCTAssertEqual(result.mouseActiveSeconds, 10)
        XCTAssertEqual(result.totalActiveSeconds, 15)
        XCTAssertEqual(try store.summary(in: interval(0, 3600)).totalActiveSeconds, 15)
        try store.advance(to: date(100))
        result = try store.summary(in: interval(0, 3600))
        XCTAssertEqual(result.keyboardActiveSeconds, 40)
        XCTAssertEqual(result.mouseActiveSeconds, 30)
        XCTAssertEqual(result.totalActiveSeconds, 40)
        XCTAssertEqual(result.keyPresses, 2)
    }

    func testPauseCutsWindowsAndResumeDoesNotCountGap() throws {
        let store = try ActivityStore(url: url)
        try store.ingest([key(0)], observedThrough: date(0))
        try store.endActivity(at: date(9))
        try store.advance(to: date(300))
        XCTAssertEqual(try store.summary(in: interval(0, 600)).totalActiveSeconds, 9)
        try store.ingest([key(300)], observedThrough: date(310))
        XCTAssertEqual(try store.summary(in: interval(0, 600)).totalActiveSeconds, 19)
    }

    func testRestartPersistsCountsAndCannotAccrueOfflineTime() throws {
        var store: ActivityStore? = try ActivityStore(url: url)
        try store!.ingest([key(0)], observedThrough: date(8))
        store = nil
        let reopened = try ActivityStore(url: url)
        try reopened.advance(to: date(3600))
        let result = try reopened.summary(in: interval(0, 7200))
        XCTAssertEqual(result.keyPresses, 1)
        XCTAssertEqual(result.totalActiveSeconds, 8)
        XCTAssertEqual(result.keyCounts, ["A": 1])
    }

    func testHalfOpenRangesSplitCrossMidnightWindowAndCounters() throws {
        let store = try ActivityStore(url: url)
        try store.ingest([key(-10), key(0, "B"), key(60, "C")], observedThrough: date(70))
        let previous = try store.summary(in: interval(-60, 0))
        let first = try store.summary(in: interval(0, 60))
        let second = try store.summary(in: interval(60, 120))
        XCTAssertEqual(previous.keyPresses, 1); XCTAssertEqual(previous.totalActiveSeconds, 10)
        XCTAssertEqual(first.keyPresses, 1); XCTAssertEqual(first.keyCounts, ["B": 1])
        XCTAssertEqual(first.totalActiveSeconds, 30)
        XCTAssertEqual(second.keyPresses, 1); XCTAssertEqual(second.totalActiveSeconds, 10)
    }

    func testDeletingMinuteRemovesHistogramAndPendingActivity() throws {
        let store = try ActivityStore(url: url)
        try store.ingest([key(50)], observedThrough: date(55))
        try store.delete(in: interval(0, 60))
        try store.advance(to: date(100))
        XCTAssertEqual(try store.summary(in: interval(0, 60)).totalActiveSeconds, 0)
        XCTAssertEqual(try store.summary(in: interval(0, 60)).keyPresses, 0)
        XCTAssertEqual(try store.summary(in: interval(0, 120)).keyCounts, [:])
        // The non-deleted next minute keeps its already-open tail.
        XCTAssertEqual(try store.summary(in: interval(60, 120)).totalActiveSeconds, 20)
    }

    func testDeletionRoundsOutwardAndClearClosesEveryPendingWindow() throws {
        let store = try ActivityStore(url: url)
        try store.ingest([key(1), key(61), key(121)], observedThrough: date(125))
        try store.delete(in: interval(59, 61))
        XCTAssertEqual(try store.summary(in: interval(0, 180)).keyPresses, 1)
        try store.clear()
        try store.advance(to: date(1000))
        let summary = try store.summary(in: interval(0, 1200))
        XCTAssertEqual(summary.keyPresses, 0); XCTAssertEqual(summary.totalActiveSeconds, 0)
        XCTAssertTrue(summary.keyCounts.isEmpty)
        XCTAssertTrue(try store.buckets(in: interval(0, 1200)).isEmpty)
    }

    func testFractionalObservationOnlyCountsFullyElapsedSeconds() throws {
        let store = try ActivityStore(url: url)
        try store.ingest([key(0.2)], observedThrough: date(1.9))
        XCTAssertEqual(try store.summary(in: interval(0, 60)).totalActiveSeconds, 0)
        try store.advance(to: date(2.1))
        XCTAssertEqual(try store.summary(in: interval(0, 60)).totalActiveSeconds, 1)
        try store.advance(to: date(3.9))
        XCTAssertEqual(try store.summary(in: interval(0, 2.9)).totalActiveSeconds, 1)
        XCTAssertEqual(try store.summary(in: interval(0, 60)).totalActiveSeconds, 2)
    }

    func testBatchOrderDoesNotChangeUnionOrCounts() throws {
        let store = try ActivityStore(url: url)
        let other = try ActivityStore(url: directory.appendingPathComponent("second.sqlite"))
        let events = [key(2), key(29), key(25), key(65)]
        try store.ingest(events, observedThrough: date(90))
        try other.ingest(Array(events.reversed()), observedThrough: date(90))
        XCTAssertEqual(try store.exportCSV(in: interval(0, 120)), try other.exportCSV(in: interval(0, 120)))
        XCTAssertEqual(try store.summary(in: interval(0, 120)).totalActiveSeconds, 82)
    }

    func testInvalidBatchIsAtomic() throws {
        let store = try ActivityStore(url: url)
        XCTAssertThrowsError(try store.ingest([key(0), key(100)], observedThrough: date(10)))
        XCTAssertEqual(try store.summary(in: interval(0, 120)).keyPresses, 0)
        try store.ingest([key(0)], observedThrough: date(10))
        XCTAssertThrowsError(try store.advance(to: date(5)))
        XCTAssertEqual(try store.summary(in: interval(0, 120)).totalActiveSeconds, 10)
    }

    func testPhysicalLabelsMouseUnitsAndCSVPrivacy() throws {
        let store = try ActivityStore(url: url)
        try store.ingest([key(0, "my secret password"), key(1, "Cmd"), key(2, "Num 7"),
                          InputSample(timestamp: date(3), kind: .mouseMove, distancePoints: 17.5),
                          InputSample(timestamp: date(4), kind: .scroll, scrollDelta: -2.5),
                          InputSample(timestamp: date(5), kind: .rightClick),
                          InputSample(timestamp: date(6), kind: .middleClick)], observedThrough: date(10))
        let summary = try store.summary(in: interval(0, 60))
        XCTAssertEqual(summary.keyCounts, ["Other": 1, "Cmd": 1, "Num 7": 1])
        XCTAssertEqual(summary.mouseDistancePoints, 17.5); XCTAssertEqual(summary.scrollUnits, 2.5)
        XCTAssertEqual(summary.totalClicks, 2)
        let csv = try store.exportCSV(in: interval(0, 60))
        XCTAssertTrue(csv.contains("display_points")); XCTAssertTrue(csv.contains("range_end_exclusive"))
        XCTAssertFalse(csv.contains("my secret password"))
        XCTAssertFalse(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("my secret password"))
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testWindowsPhysicalLabelWhitelistKeepsKeypadCountsSeparateAndRejectsText() throws {
        let store = try ActivityStore(url: url)
        let labels = ["0", "1", ".", "-", "=", "/", "Return", "Enter", "*", "+",
                      "Num 0", "Num 1", "Num 2", "Num 3", "Num 4", "Num 5", "Num 6", "Num 7", "Num 8", "Num 9",
                      "Num .", "Num *", "Num +", "Num /", "Num Enter", "Num -", "Num =",
                      "NumLock", "ScrollLock", "Insert", "PrintScreen", "Alt", "Windows"]
        let invalid = ["Num 10", "NumLock secret", "ScrollLock secret", "Insert secret", "PrintScreen secret", "Num private text"]
        try store.ingest((labels + invalid).enumerated().map { key(Double($0.offset), $0.element) }, observedThrough: date(40))
        var expected = Dictionary(uniqueKeysWithValues: labels.map { ($0, 1) })
        expected["Other"] = invalid.count
        let summary = try store.summary(in: interval(0, 60))
        XCTAssertEqual(summary.keyCounts, expected)
        XCTAssertEqual(summary.keyPresses, labels.count + invalid.count)
        let csv = try store.exportCSV(in: interval(0, 60))
        for value in invalid { XCTAssertFalse(csv.contains(value)) }
        // Reopening preserves existing literal IDs and requires no schema migration.
        let reopened = try ActivityStore(url: url)
        XCTAssertEqual(try reopened.summary(in: interval(0, 60)).keyCounts, expected)
    }

    func testPersistedSchemaContainsOnlyMinuteAggregatesAndHistograms() throws {
        let store = try ActivityStore(url: url)
        try store.ingest([key(0, "DO NOT PERSIST TEXT"), key(1, "B")], observedThrough: date(10))
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(database) }
        func textColumn(_ query: String, index: Int32) -> Set<String> {
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(database, query, -1, &statement, nil), SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            var values = Set<String>()
            while sqlite3_step(statement) == SQLITE_ROW {
                if let value = sqlite3_column_text(statement, index) { values.insert(String(cString: value)) }
            }
            return values
        }
        // Explicit storage privacy boundary: no event/sample/text/coordinate table
        // and no finer timestamp or event-order field can silently be introduced.
        XCTAssertEqual(textColumn("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'", index: 0), ["minutes", "key_histograms"])
        let allowedMinuteFields: Set<String> = ["minute", "keys", "left_clicks", "right_clicks", "middle_clicks", "distance", "scroll", "keyboard_mask", "mouse_mask"]
        XCTAssertEqual(textColumn("PRAGMA table_info(minutes)", index: 1), allowedMinuteFields)
        XCTAssertEqual(textColumn("PRAGMA table_info(key_histograms)", index: 1), ["minute", "label", "count"])
    }

    func testNaturalMinutePeakAndEmptyPeriod() throws {
        let store = try ActivityStore(url: url)
        try store.ingest([key(58), key(59), key(60), key(61), key(62)], observedThrough: date(70))
        let result = try store.summary(in: interval(0, 120))
        XCTAssertEqual(result.peakKeysPerMinute, 3)
        XCTAssertEqual(result.minuteCount, 2)
        let empty = try store.summary(in: interval(120, 180))
        XCTAssertEqual(empty.totalActiveSeconds, 0); XCTAssertEqual(empty.averageKeysPerMinute, 0)
        XCTAssertTrue(try store.buckets(in: interval(60, 60)).isEmpty)
    }

    func testLocalCalendarDayIncludesDSTLengthWithoutFixedDayAssumption() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let localNoon = calendar.date(from: DateComponents(year: 2025, month: 3, day: 9, hour: 12))!
        let day = calendar.dateInterval(of: .day, for: localNoon)!
        XCTAssertEqual(day.duration, 23 * 3600)
        let store = try ActivityStore(url: url)
        try store.ingest([InputSample(timestamp: day.start, kind: .keyPress, keyLabel: "A"),
                          InputSample(timestamp: day.end, kind: .keyPress, keyLabel: "B")], observedThrough: day.end)
        XCTAssertEqual(try store.summary(in: day).keyCounts, ["A": 1])
    }
}
