import Foundation
import CryptoKit
import KeyTrailCore
import KeyTrailIPC
import KeyTrailRuntime
import CKeyTrailRust
import CSQLite

struct CheckFailure: Error { let message: String }
func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure(message: message) }
}

@main
struct RuntimeChecks {
    @MainActor static func main() throws {
        // Darwin sockaddr_un permits at most 103 UTF-8 path bytes; the default
        // per-user temporary path plus a UUID can exceed it.
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("keytrail-checks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = Date(timeIntervalSince1970: 1_704_067_200)
        do {
            _ = try RuntimeController(isDemo: false, directory: directory.appendingPathComponent("rejected-real-capture"))
            throw CheckFailure(message: "Real capture accepted a public-key fixture directory")
        } catch is RuntimeError { }
        try require(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("rejected-real-capture").path), "Rejected fixture mode wrote production-like state")
        print("PASS Fixture directory cannot start real capture or use the public demo encryption key")
        do {
            let previous = try ActivityStore(url: directory.appendingPathComponent("activity.sqlite"))
            try previous.ingest([
                InputSample(timestamp: base, kind: .keyPress, keyLabel: "A"),
                InputSample(timestamp: base.addingTimeInterval(1), kind: .keyPress, keyLabel: "B"),
                InputSample(timestamp: base.addingTimeInterval(2), kind: .leftClick)
            ], observedThrough: base.addingTimeInterval(10))
            try previous.endActivity(at: base.addingTimeInterval(10))
            try previous.ingest([InputSample(timestamp: base.addingTimeInterval(60), kind: .keyPress, keyLabel: "C")], observedThrough: base.addingTimeInterval(70))
            try previous.endActivity(at: base.addingTimeInterval(70))
        }
        let runtime = try RuntimeController(isDemo: true, directory: directory)
        defer { runtime.shutdown() }
        let interval: [String: Any] = ["op": "summary", "start": base.timeIntervalSince1970, "end": base.addingTimeInterval(120).timeIntervalSince1970]
        let initial = runtime.handle(interval)
        let summary = initial["result"] as? [String: Any] ?? [:]
        try require(initial["ok"] as? Bool == true && summary["keyPresses"] as? Int == 3 && summary["leftClicks"] as? Int == 1 && summary["totalActiveSeconds"] as? Int == 20, "Existing Swift v1 data changed when loaded by Rust runtime")
        print("PASS Swift SQLite v1 -> Rust runtime preserves exact counts/activity")

        let timeline = runtime.handle(["op": "timeline", "ranges": (0..<3).map { index in
            ["start": base.addingTimeInterval(Double(index * 60)).timeIntervalSince1970,
             "end": base.addingTimeInterval(Double((index + 1) * 60)).timeIntervalSince1970]
        }])
        let cells = timeline["result"] as? [[String: Any]] ?? []
        let counts = cells.map { ($0["summary"] as? [String: Any])?["keyPresses"] as? Int ?? -1 }
        try require(timeline["ok"] as? Bool == true && counts == [2, 1, 0], "Runtime timeline missing, inconsistent, or dropped empty cells")
        print("PASS Rust timeline crosses Swift runtime with exact counts and zero-filled ranges")

        let grouped = runtime.handle(["op": "summaries", "ranges": [
            ["start": base.timeIntervalSince1970, "end": base.addingTimeInterval(86400).timeIntervalSince1970],
            ["start": base.addingTimeInterval(86400).timeIntervalSince1970, "end": base.addingTimeInterval(172800).timeIntervalSince1970]
        ]])
        let groupedCells = grouped["result"] as? [[String: Any]] ?? []
        let groupedCounts = groupedCells.map { ($0["summary"] as? [String: Any])?["keyPresses"] as? Int ?? -1 }
        try require(grouped["ok"] as? Bool == true && groupedCounts == [3, 0], "Long daily summaries routing failed")
        print("PASS Day-length summaries route through runtime without timeline's hourly limit")

        try require(!runtime.status.monitoring && runtime.status.backend == "rust", "Runtime auto-started")
        let ingest = runtime.handle(["op": "ingest", "samples": []])
        let start = runtime.handle(["op": "start"])
        try require(ingest["ok"] as? Bool == false && start["ok"] as? Bool == false && !runtime.status.monitoring, "Demo/IPC collection boundary failed")
        print("PASS Demo cannot monitor; public RPC cannot inject raw samples")

        let savedPreferences = try Data(contentsOf: directory.appendingPathComponent("preferences.json"))
        let beforeResetSummary = try JSONSerialization.data(withJSONObject: runtime.handle(interval), options: [.sortedKeys])
        let resetPose = runtime.handle(["op": "resetPetPose"])
        let neutralPose = resetPose["result"] as? [String: Any] ?? [:]
        try require(resetPose["ok"] as? Bool == true && neutralPose["leftPawHeld"] as? Bool == false && neutralPose["rightPawHeld"] as? Bool == false && (neutralPose["keyboardKeys"] as? [String])?.isEmpty == true, "Reset-pose RPC failed to return a neutral pose")
        let afterResetPreferences = try Data(contentsOf: directory.appendingPathComponent("preferences.json"))
        let afterResetSummary = try JSONSerialization.data(withJSONObject: runtime.handle(interval), options: [.sortedKeys])
        try require(savedPreferences == afterResetPreferences && beforeResetSummary == afterResetSummary && !runtime.status.monitoring, "Reset-pose RPC changed preferences, statistics or monitoring")
        print("PASS Pose reset remains isolated from preferences, stored statistics and collection")

        runtime.screenDidLock(); runtime.systemDidSleep(); runtime.systemDidWake()
        try require(runtime.status.suspended, "Wake cleared screen lock")
        runtime.screenDidUnlock()
        try require(!runtime.status.suspended, "Unlock failed to clear final suspension")
        runtime.systemDidSleep(); runtime.screenDidLock(); runtime.screenDidUnlock()
        try require(runtime.status.suspended, "Unlock cleared sleep suspension")
        runtime.systemDidWake()
        try require(!runtime.status.suspended, "Wake failed to clear final suspension")
        print("PASS Lock and sleep suspend independently in both orders")

        let deletion = runtime.handle(["op": "delete", "start": base.timeIntervalSince1970, "end": base.addingTimeInterval(60).timeIntervalSince1970])
        let remaining = runtime.handle(interval)["result"] as? [String: Any] ?? [:]
        try require(deletion["ok"] as? Bool == true && remaining["keyPresses"] as? Int == 1 && remaining["leftClicks"] as? Int == 0 && remaining["totalActiveSeconds"] as? Int == 10, "Runtime delete altered adjacent minute or retained deleted counts")
        print("PASS Serialized runtime deletion preserves adjacent minute")

        let socket = directory.appendingPathComponent("checks.sock")
        let server = try RuntimeServer(url: socket) { request in ["ok": true, "result": ["echo": request["value"] ?? NSNull()]] }
        server.start(); defer { server.stop() }
        let client = RuntimeClient(socketURL: socket)
        let echo = try client.request(["op": "echo", "value": 42]) as? [String: Any]
        try require(echo?["echo"] as? Int == 42, "IPC round trip failed")
        let permissions = try FileManager.default.attributesOfItem(atPath: socket.path)[.posixPermissions] as? NSNumber
        try require(permissions?.intValue == 0o600, "Socket permissions too broad")
        print("PASS Local JSON socket round trip and owner-only permissions")
        do {
            _ = try RuntimeServer(url: socket) { _ in [:] }
            throw CheckFailure(message: "Second server took ownership")
        } catch is RuntimeError { }
        let afterDuplicate = try client.request(["op": "echo", "value": 99]) as? [String: Any]
        try require(afterDuplicate?["echo"] as? Int == 99, "Duplicate startup broke live socket")
        print("PASS Duplicate server rejected without replacing live socket")

        let cleared = runtime.handle(["op": "clear"])
        let empty = runtime.handle(interval)["result"] as? [String: Any] ?? [:]
        try require(cleared["ok"] as? Bool == true && empty["keyPresses"] as? Int == 0 && !runtime.status.monitoring, "Clear did not stop/reset runtime")
        print("PASS Clear resets derived totals and leaves capture stopped")
        try checkPrivateFileStreaming(directory)
        try checkTextPagingRPC(directory.appendingPathComponent("text-rpc"))
        try checkCSVExporter(directory.appendingPathComponent("csv-export", isDirectory: true))
        try checkCSVRuntimeRPC(directory.appendingPathComponent("csv-rpc", isDirectory: true))
        try checkValidationProfile()
        try checkSuspendedStatusLabels()
        try checkOverviewTrend(runtime: runtime, base: base)
        try checkPreferenceTransactions(directory.appendingPathComponent("preferences-transaction"))
        try checkPreferenceSubmission()
        try checkKeylessStorageMetadata(directory.appendingPathComponent("keyless-metadata"))
        try checkHistoricalCacheRefresh(directory.appendingPathComponent("historical-refresh"))
        try checkCombinedRetentionMaintenance(directory.appendingPathComponent("retention-maintenance"))
        print("Passed 36 runtime integration checks (temporary fixture; no real input monitoring)")
    }

    @MainActor static func checkCombinedRetentionMaintenance(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let statsURL = directory.appendingPathComponent("activity.sqlite"), textURL = directory.appendingPathComponent("text.sqlite")
        var error: UnsafeMutablePointer<CChar>?
        guard let core = keytrail_open(statsURL.path, &error) else {
            if let error { keytrail_string_free(error) }
            throw CheckFailure(message: "Retention fixture core could not open")
        }
        defer { keytrail_close(core) }
        func request(_ value: [String: Any]) throws -> [String: Any] {
            let data = try JSONSerialization.data(withJSONObject: value)
            guard let input = String(data: data, encoding: .utf8), let output = keytrail_request(core, input) else { throw CheckFailure(message: "Retention core response missing") }
            defer { keytrail_string_free(output) }
            let response = try JSONSerialization.jsonObject(with: Data(String(cString: output).utf8)) as! [String: Any]
            try require(response["ok"] as? Bool == true, "Retention core rejected request")
            return response["result"] as? [String: Any] ?? [:]
        }
        func scalar(_ url: URL, _ sql: String) throws -> Int64 {
            var db: OpaquePointer?; try require(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, "Retention fixture metadata open failed")
            defer { sqlite3_close(db) }
            var statement: OpaquePointer?; try require(sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, "Retention fixture metadata prepare failed")
            defer { sqlite3_finalize(statement) }
            try require(sqlite3_step(statement) == SQLITE_ROW, "Retention fixture metadata read failed")
            return sqlite3_column_int64(statement, 0)
        }
        let archive = try TextArchive(url: textURL, key: SymmetricKey(size: .bits256))
        _ = try archive.append(text: "synthetic retention baseline", at: Date(timeIntervalSince1970: 59), applicationBundleID: "fixture")
        _ = try request(["op": "ingest", "samples": [["timestamp": 59.0, "kind": "keyPress", "keyLabel": "A"]], "observedThrough": 60.0])
        var now = 60.0, flags: [Bool] = [], retainCalls = 0, resets = 0
        func apply(_ limit: Int64) throws -> Bool {
            try RuntimeRetentionMaintenance.applyCombinedLimit(maxBytes: limit, flush: { end in
                flags.append(end); _ = try request(["op": end ? "end" : "advance", "time": now])
            }, databaseBytes: {
                let statistics = try request(["op": "storageInfo"])["databaseBytes"] as! Int64
                return try RuntimeRetentionMaintenance.combinedBytes(statistics: statistics, text: archive.storageInfo().bytes)
            }, retain: { beforeDeleting in
                retainCalls += 1
                return try archive.retentionTogetherWithStatistics(at: statsURL, maxBytes: limit, beforeDeleting: beforeDeleting).limitMet
            }, didRetain: { resets += 1 })
        }
        let originalText = try Data(contentsOf: textURL)
        let fits = try apply(1_048_576)
        _ = try request(["op": "advance", "time": 89.0])
        let summary = try request(["op": "summary", "start": 0.0, "end": 120.0])
        let unchangedText = try Data(contentsOf: textURL)
        try require(fits && flags == [false] && retainCalls == 0 && resets == 0 && originalText == unchangedText && summary["totalActiveSeconds"] as? Int == 30,
                    "Under-limit maintenance interrupted 30-second activity, reset baseline or touched text DB")
        _ = try request(["op": "end", "time": 90.0])
        now = 120
        _ = try apply(1_048_576)
        let paused = try request(["op": "summary", "start": 0.0, "end": 180.0])
        try require(paused["totalActiveSeconds"] as? Int == 30, "Maintenance expanded paused/suspended activity after end")
        print("PASS Production joint-retention branch preserves full activity tail and paused cutoff; under-limit checks skip reset/cleanup/text writes")

        flags = []
        do {
            _ = try RuntimeRetentionMaintenance.applyCombinedLimit(maxBytes: 1_048_576, flush: { flags.append($0) }, databaseBytes: {
                try RuntimeRetentionMaintenance.combinedBytes(statistics: Int64.max, text: 1)
            }, retain: { _ in throw CheckFailure(message: "Overflow reached cleanup") }, didRetain: { resets += 1 })
            throw CheckFailure(message: "Overflow was swallowed")
        } catch is RuntimeError { }
        try require(flags == [false] && resets == 0, "Invalid capacity terminated transient activity")
        do {
            _ = try RuntimeRetentionMaintenance.combinedBytes(statistics: -1, text: 1)
            throw CheckFailure(message: "Negative capacity accepted")
        } catch is RuntimeError { }
        print("PASS Capacity overflow/invalid metadata fails before destructive maintenance")

        var inflatedIDs: [String] = []
        for index in 0..<80 {
            inflatedIDs.append(try archive.append(text: String(repeating: "x", count: 16_384), at: Date(timeIntervalSince1970: Double(180 + index * 60)), applicationBundleID: "fixture.freelist").id)
        }
        try archive.delete(ids: inflatedIDs)
        let beforeCompaction = try archive.storageInfo().bytes
        try require(beforeCompaction > 1_048_576, "Compaction fixture did not retain enough freelist pages")
        _ = try request(["op": "ingest", "samples": [["timestamp": 179.0, "kind": "keyPress", "keyLabel": "A"]], "observedThrough": 180.0])
        flags = []; now = 180
        let compacted = try apply(1_048_576)
        _ = try request(["op": "advance", "time": 209.0])
        let compactedSummary = try request(["op": "summary", "start": 120.0, "end": 240.0])
        let afterCompaction = try archive.storageInfo().bytes
        try require(compacted && flags == [false] && retainCalls == 1 && resets == 0 && afterCompaction < beforeCompaction && compactedSummary["totalActiveSeconds"] as? Int == 30,
                    "Freelist-only compaction ended the activity tail or reset collection despite deleting no records")
        print("PASS Actual over-cap freelist compaction preserves activity and baselines when no record deletion is needed")

        for index in 0..<80 {
            let timestamp = 240.0 + Double(index * 60)
            _ = try request(["op": "ingest", "samples": [["timestamp": timestamp, "kind": "keyPress", "keyLabel": "B"]], "observedThrough": timestamp])
            _ = try archive.append(text: String(repeating: "x", count: 16_384), at: Date(timeIntervalSince1970: timestamp), applicationBundleID: "fixture")
        }
        flags = []; now = 240 + 79 * 60 + 1
        let cleaned = try apply(1_048_576)
        let beforeAdvance = try scalar(statsURL, "SELECT COUNT(*) FROM minutes")
        _ = try request(["op": "advance", "time": now + 60])
        let afterwards = try scalar(statsURL, "SELECT COUNT(*) FROM minutes")
        let statsTombstones = try scalar(statsURL, "SELECT COUNT(*) FROM sync_journal WHERE deleted=1")
        let textTombstones = try scalar(textURL, "SELECT COUNT(*) FROM text_sync WHERE deleted=1")
        try require(cleaned && flags == [false, true] && retainCalls == 2 && resets == 1 && statsTombstones > 0 && textTombstones > 0 && beforeAdvance == afterwards,
                    "Real over-limit maintenance failed to end windows, delete jointly or preserve tombstones")
        print("PASS Production over-limit branch ends activity before joint cleanup, retains both tombstones and prevents pending-window row resurrection")
    }

    @MainActor static func checkKeylessStorageMetadata(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let missing = directory.appendingPathComponent("missing.sqlite")
        let missingMetadata = try TextArchive.storageInfo(at: missing)
        try require(missingMetadata == nil, "Missing text archive returned metadata")
        try require(!FileManager.default.fileExists(atPath: missing.path), "Storage lookup created a text archive")
        let textURL = directory.appendingPathComponent("text.sqlite")
        let expected: TextStorageInfo
        do {
            let archive = try TextArchive(url: textURL, key: SymmetricKey(size: .bits256))
            _ = try archive.append(text: "isolated metadata fixture", at: Date(timeIntervalSince1970: 1_700_000_000), applicationBundleID: "fixture")
            expected = try archive.storageInfo()
        }
        let original = try Data(contentsOf: textURL)
        let metadata = try TextArchive.storageInfo(at: textURL)
        try require(metadata?.bytes == expected.bytes && metadata?.records == 1 && metadata?.oldestTime == expected.oldestTime, "Read-only storage differs from existing storage semantics")
        let runtime = try RuntimeController(isDemo: true, directory: directory)
        defer { runtime.shutdown() }
        let details = runtime.handle(["op": "preferences"])
        let storage = (details["result"] as? [String: Any])?["storage"] as? [String: Any]
        try require(details["ok"] as? Bool == true && storage?["textRecordCount"] as? Int == 1 && storage?["textBytes"] as? Int64 == expected.bytes, "Preferences required the unavailable archive encryption key")
        let afterwards = try Data(contentsOf: textURL)
        try require(original == afterwards && !runtime.status.monitoring, "Metadata lookup wrote the encrypted archive or started capture")
        print("PASS Preferences read encrypted archive capacity without its key, mutations or collection")
        var capped = runtime.preferences; capped.storageLimitBytes = 64 * 1024 * 1024
        let cappedResponse = runtime.handle(["op": "setPreferences", "preferences": try JSONSerialization.jsonObject(with: JSONEncoder().encode(capped))])
        let cappedDetails = cappedResponse["result"] as? [String: Any]
        let afterCapacityCheck = try Data(contentsOf: textURL)
        try require(cappedResponse["ok"] as? Bool == true && (cappedDetails?["retentionError"] == nil || cappedDetails?["retentionError"] is NSNull) && original == afterCapacityCheck && !runtime.status.monitoring,
                    "Under-limit runtime retention opened the archive with an unavailable key, changed it, or started capture")
        print("PASS Actual runtime under-limit maintenance skips archive key loading with text disabled")
        let corrupt = directory.appendingPathComponent("corrupt.sqlite")
        try Data("not a database".utf8).write(to: corrupt)
        do {
            _ = try TextArchive.storageInfo(at: corrupt)
            throw CheckFailure(message: "Corrupt archive was silently reported as empty")
        } catch is TextArchiveError { }
        print("PASS Missing archive metadata creates no file; corrupt metadata fails visibly")
    }

    @MainActor static func checkPreferenceTransactions(_ directory: URL) throws {
        func object(_ value: RuntimePreferences) throws -> Any {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
        }
        let savedURL = directory.appendingPathComponent("preferences.json")
        var safe = RuntimePreferences(); safe.floatingWindowEnabled = true
        do {
            let runtime = try RuntimeController(isDemo: true, directory: directory)
            defer { runtime.shutdown() }
            let baseline = runtime.preferences
            let originalBytes = try Data(contentsOf: savedURL)
            var mixed = baseline; mixed.floatingWindowEnabled = true; mixed.launchAtLoginEnabled = true
            let rejected = runtime.handle(["op": "setPreferences", "preferences": try object(mixed)])
            let afterRejectedBytes = try Data(contentsOf: savedURL)
            try require(rejected["ok"] as? Bool == false && runtime.preferences == baseline && originalBytes == afterRejectedBytes,
                        "Unsupported login combined with safe setting partially committed")
            try require(!runtime.status.monitoring, "Rejected preference save started monitoring")
            print("PASS Unsupported login plus safe preference fails atomically without changing persisted state")
            let response = runtime.handle(["op": "setPreferences", "preferences": try object(safe)])
            try require(response["ok"] as? Bool == true && runtime.preferences == safe,
                        "Safe preference save did not roundtrip")
        }
        let reopened = try RuntimeController(isDemo: true, directory: directory)
        defer { reopened.shutdown() }
        try require(reopened.preferences == safe && !reopened.status.monitoring,
                    "Safe preference did not persist across restart or enabled monitoring")
        print("PASS Safe floating preference persists across runtime restart without sensitive side effects")
    }

    static func checkPreferenceSubmission() throws {
        var current = RuntimeDetails(); current.loginStatus = "unavailableInPreview"
        var mixed = current.preferences; mixed.floatingWindowEnabled = true; mixed.launchAtLoginEnabled = true
        do {
            _ = try RuntimePreferencesSubmission.validate(mixed, current: current, isDemo: false)
            throw CheckFailure(message: "Dashboard accepted unsupported login mutation")
        } catch is RuntimeError { }
        var safe = current.preferences; safe.floatingWindowEnabled = true
        let proposed = try RuntimePreferencesSubmission.validate(safe, current: current, isDemo: false)
        try RuntimePreferencesSubmission.confirm(proposed, actual: safe)
        do {
            try RuntimePreferencesSubmission.confirm(proposed, actual: current.preferences)
            throw CheckFailure(message: "Save feedback accepted mismatched readback")
        } catch is RuntimeError { }
        try require(RuntimePaths.profileName(isDemo: false, bundleIdentifier: "com.auriel.keytrail.validation.dashboard.repaired") == "KeyTrail Validation", "Repaired dashboard reads the wrong profile")
        print("PASS Dashboard rejects unsupported login and mismatched save confirmation; repaired profile stays isolated")
    }

    static func checkSuspendedStatusLabels() throws {
        let cases: [(Bool, Bool, String)] = [
            (false, true, "安全输入中 · 采集暂停"), // Start/resume already inside secure input.
            (true, true, "锁屏或休眠 · 采集暂停"),
            (true, false, "锁屏或休眠 · 采集暂停"), // Secure input ends while system remains suspended.
            (false, false, "正在本机记录 · Rust 核心")
        ]
        for (system, secure, expected) in cases {
            try require(RuntimeController.runningStatusText(systemSuspended:system,secureSuspended:secure)==expected,
                        "Running status contradicts system/secure suspension")
        }
        print("PASS Start/tick/wake status gives system and secure suspension priority over recording")
    }

    static func checkValidationProfile() throws {
        let regular="com.auriel.keytrail",preview="com.auriel.keytrail.preview",validation="com.auriel.keytrail.validation"
        try require(RuntimePaths.profileName(isDemo:false,bundleIdentifier:regular)=="KeyTrail" && RuntimePaths.profileName(isDemo:false,bundleIdentifier:preview)=="KeyTrail", "Normal/preview unexpectedly routed to validation profile")
        try require(RuntimePaths.profileName(isDemo:false,bundleIdentifier:validation)=="KeyTrail Validation" && RuntimePaths.profileName(isDemo:false,bundleIdentifier:validation+".dashboard")=="KeyTrail Validation", "Validation agent/dashboard do not share the isolated profile")
        try require(RuntimePaths.profileName(isDemo:true,bundleIdentifier:validation)=="KeyTrail Demo", "Demo must override validation identity")
        let prod=RuntimePaths.keychainService("text",bundleIdentifier:regular),demo=RuntimePaths.keychainService("text",isDemo:true,bundleIdentifier:validation),check=RuntimePaths.keychainService("text",bundleIdentifier:validation)
        try require(Set([prod,demo,check]).count==3 && check==RuntimePaths.keychainService("text",bundleIdentifier:validation+".dashboard"), "Text keychain services cross profile boundaries")
        print("PASS Normal/demo/validation directory names and text keychain services remain isolated")
    }

    @MainActor static func checkOverviewTrend(runtime: RuntimeController,base:Date) throws {
        func calendar(_ zone:String)->Calendar {var c=Calendar(identifier:.gregorian);c.timeZone=TimeZone(identifier:zone)!;return c}
        func date(_ y:Int,_ m:Int,_ d:Int,_ h:Int=0,_ minute:Int=0,in c:Calendar)->Date {c.date(from:DateComponents(year:y,month:m,day:d,hour:h,minute:minute))!}
        let utc=calendar("UTC"),ny=calendar("America/New_York"),lh=calendar("Australia/Lord_Howe")
        let longEnd=Date(timeIntervalSince1970:300000*3600)
        let long=try OverviewTrendPlan(interval:DateInterval(start:Date(timeIntervalSince1970:0),end:longEnd),observedThrough:longEnd,calendar:utc)
        try require(long.component == .year && long.segments.count==35 && long.segments.first?.start==Date(timeIntervalSince1970:0) && long.segments.last?.end==longEnd,"34-year trend did not stay bounded with exact endpoints")
        try require(zip(long.segments,long.segments.dropFirst()).allSatisfy{$0.end==$1.start} && long.segments.allSatisfy{$0.end.timeIntervalSince($0.start)<=367*86400},"Calendar trend lost coverage or exceeded core duration")
        let monthStart=date(2024,1,20,in:utc),monthEnd=date(2024,3,10,in:utc),cutoff=date(2024,2,15,12,34,in:utc).addingTimeInterval(0.5)
        let partial=try OverviewTrendPlan(interval:DateInterval(start:monthStart,end:monthEnd),observedThrough:cutoff,calendar:utc,preferMonthly:true)
        try require(partial.component == .month && partial.segments.count==2 && partial.segments.first?.start==monthStart && partial.segments.last?.end==cutoff && partial.segments.last?.displayStart==date(2024,2,1,in:utc),"Month/now clipping assigned a partial month incorrectly")
        let future=try OverviewTrendPlan(interval:DateInterval(start:monthStart,end:monthEnd),observedThrough:monthStart.addingTimeInterval(-1),calendar:utc)
        try require(future.segments.isEmpty,"Future overview invented zero-observed bars")
        print("PASS Bounded multi-decade calendar trend and partial/future selection clipping")

        for (c,start,end,hour,seconds) in [(ny,date(2026,11,1,in:ny),date(2026,11,2,in:ny),1,7200.0),(lh,date(2026,10,4,in:lh),date(2026,10,5,in:lh),2,1800.0),(lh,date(2026,4,5,in:lh),date(2026,4,6,in:lh),1,5400.0)] {
            let plan=try OverviewTrendPlan(interval:DateInterval(start:start,end:end),observedThrough:end,calendar:c)
            try require(plan.component == .hour && plan.segments.count==24 && plan.segments.filter{c.component(.hour,from:$0.start)==hour}.reduce(0.0){$0+$1.end.timeIntervalSince($1.start)}==seconds,"Repeated or half-hour DST clock cell misassigned")
            try require(plan.segments.reduce(0.0){$0+$1.end.timeIntervalSince($1.start)}==end.timeIntervalSince(start),"DST plan lost elapsed coverage")
            try require(plan.segments.allSatisfy{c.component(.hour,from:$0.displayStart)==c.component(.hour,from:$0.start)} && Set(plan.segments.map(\.displayStart)).count==plan.segments.count,"DST trend labels shifted or duplicated clock cells")
        }
        print("PASS Overview civil hours preserve full and half-hour DST transitions")

        let plan=try OverviewTrendPlan(interval:DateInterval(start:base,end:base.addingTimeInterval(7200)),observedThrough:base.addingTimeInterval(7200),calendar:utc)
        let response=runtime.handle(["op":"trend","ranges":plan.queryRanges])
        try require(response["ok"] as? Bool==true,"Runtime rejected bounded trend operation")
        let decoder=JSONDecoder();decoder.dateDecodingStrategy = .secondsSince1970
        let buckets=try decoder.decode([MinuteBucket].self,from:JSONSerialization.data(withJSONObject:response["result"]!))
        let points=try plan.points(for:buckets)
        try require(points.count==2 && points.allSatisfy{$0.keys==0 && $0.clicks==0},"Empty bounded trend invented rows or dropped zero buckets")
        var mismatch=buckets;mismatch[0].start=mismatch[0].start.addingTimeInterval(60)
        do {_ = try plan.points(for:mismatch);throw CheckFailure(message:"Wrong trend segment accepted")}catch is CheckFailure {throw CheckFailure(message:"Wrong trend segment accepted")}catch{}
        print("PASS Runtime trend returns bounded zero buckets and validates response boundaries")

        let failed=runtime.handle(["op":"trend","ranges":[["start":1,"end":60]]])
        let summary=runtime.handle(["op":"summary","start":base.timeIntervalSince1970,"end":base.addingTimeInterval(120).timeIntervalSince1970])
        try require(failed["ok"] as? Bool==false && summary["ok"] as? Bool==true,"A rejected trend made the independently requested summary unavailable")
        do {_ = try OverviewTrendPlan(interval:DateInterval(start:Date(timeIntervalSince1970:0),duration:101*366*86400),observedThrough:Date(),calendar:utc);throw CheckFailure(message:"Unbounded trend range accepted")}catch is CheckFailure {throw CheckFailure(message:"Unbounded trend range accepted")}catch{}
        print("PASS Invalid/budget-exceeded trends fail separately while summary remains readable")
    }

    static func checkPrivateFileStreaming(_ directory: URL) throws {
        let url = directory.appendingPathComponent("stream.txt")
        try PrivateFile.write(Data("original".utf8), to: url)
        do {
            try PrivateFile.write(to: url) { append in
                try append(Data(repeating: 65, count: 1024 * 1024))
                let temporary = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(".keytrail-") }
                try require(temporary.count == 1, "Streaming temporary file not isolated")
                let mode = try FileManager.default.attributesOfItem(atPath: temporary[0].path)[.posixPermissions] as? NSNumber
                try require(mode?.intValue == 0o600, "Streaming plaintext file not owner-only from creation")
                throw RuntimeError("fixture cancellation")
            }
            throw CheckFailure(message: "Failed producer published export")
        } catch is RuntimeError { }
        let original = try Data(contentsOf: url)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(".keytrail-") }
        try require(original == Data("original".utf8) && leftovers.isEmpty, "Failed export replaced target or leaked partial file")
        do {
            try PrivateFile.write(to: url, beforePublish: { throw RuntimeError("fixture late cancellation") }) { append in try append(Data("replacement".utf8)) }
            throw CheckFailure(message: "Late export cancellation was ignored")
        } catch is RuntimeError { }
        let retained = try Data(contentsOf: url)
        try require(retained == original, "Cancellation after fsync replaced existing target")
        print("PASS Streaming export failure keeps original target and removes owner-only temporary plaintext")
        try PrivateFile.write(to: url) { append in
            for byte in UInt8(0)..<UInt8(10) { try append(Data(repeating: byte, count: 1024 * 1024)) }
        }
        let result = try Data(contentsOf: url)
        try require(result.count == 10 * 1024 * 1024 && (0..<10).allSatisfy { result[$0 * 1024 * 1024] == UInt8($0) }, "Streaming export lost chunks above old 8 MiB limit")
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        try require(mode?.intValue == 0o600, "Final streamed export has broad permissions")
        print("PASS Streaming export atomically publishes all 10 MiB chunks with owner-only permissions")
    }

    @MainActor static func checkTextPagingRPC(_ directory: URL) throws {
        let key = SymmetricKey(data: Data(SHA256.hash(data: Data("KeyTrail public isolated demo text key v1".utf8))))
        let archive = try TextArchive(url: directory.appendingPathComponent("text.sqlite"), key: key)
        for index in 0..<301 { try archive.append(text: "paging fixture \(index)", at: Date(timeIntervalSince1970: 60.5), applicationBundleID: "fixture.paging") }
        let runtime = try RuntimeController(isDemo: true, directory: directory)
        defer { runtime.shutdown() }
        var request: [String: Any] = ["op": "textSearchPage", "start": 60.0, "end": 120.0, "limit": 100]
        var ids = Set<String>(), count = 0, firstCursor: [String: Any]?, revision: Int64 = -1
        while true {
            let response = runtime.handle(request)
            try require(response["ok"] as? Bool == true, "Text page RPC failed")
            let page = response["result"] as? [String: Any] ?? [:]
            revision = page["snapshotRevision"] as? Int64 ?? -1
            for entry in page["entries"] as? [[String: Any]] ?? [] {
                let id = (entry["metadata"] as? [String: Any])?["id"] as? String ?? ""
                try require(ids.insert(id).inserted, "Paging repeated a same-timestamp record")
                count += 1
            }
            if page["hasMore"] as? Bool != true { break }
            guard let cursor = page["nextCursor"] as? [String: Any] else { throw CheckFailure(message: "Missing page cursor") }
            if firstCursor == nil { firstCursor = cursor }
            request["cursor"] = cursor
        }
        let validated = runtime.handle(["op": "textValidateSnapshot", "snapshotRevision": revision])
        try require(count == 301 && validated["ok"] as? Bool == true, "Text paging RPC lost entries or snapshot validation")
        print("PASS Text page RPC reaches all 301 same-timestamp records and validates complete snapshot")
        try archive.append(text: "mutation", at: Date(timeIntervalSince1970: 61), applicationBundleID: "fixture.paging")
        request["cursor"] = firstCursor
        let changed = runtime.handle(request)
        let stale = runtime.handle(["op": "textValidateSnapshot", "snapshotRevision": revision])
        try require(changed["ok"] as? Bool == false && stale["ok"] as? Bool == false, "Mutated text archive accepted old cursor or export snapshot")
        print("PASS Text paging and final export validation reject a changed archive snapshot")
    }

    static func checkCSVExporter(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("full.csv"), total = 10_000
        let header = "minute_utc,key_presses,key_histogram\r\n", snapshot: [String: Any] = ["id": String(repeating: "a", count: 32), "revision": 1]
        let end = Double(total * 60)
        var calls = 0, validated = false, published = false
        func page(_ query: [String: Any]) throws -> Any {
            if query["op"] as? String == "exportValidate" { validated = true; return NSNull() }
            let after = (query["cursor"] as? [String: Any])?["afterMinute"] as? Int ?? -60
            let first = (after + 60) / 60, last = min(first + 500, total)
            let csv = (first..<last).map { "\($0 * 60),1,\"\(String(repeating: "A:1;", count: 250))\"\r\n" }.joined()
            let next: Any = last < total ? ["snapshot": snapshot, "start": 0.0, "end": end, "afterMinute": (last - 1) * 60] : NSNull()
            calls += 1
            return ["header": header, "csv": csv, "rowCount": last - first, "totalRows": total, "snapshot": snapshot, "nextCursor": next, "hasMore": last < total] as [String: Any]
        }
        let written = try StatisticsCSVExporter.write(to: target, start: 0, end: end, request: page,
            beginPublish: { try require(validated, "CSV published before final snapshot validation"); published = true })
        let content = try String(contentsOf: target, encoding: .utf8)
        let mode = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber
        try require(written == total && calls == 20 && published && content.utf8.count > 8 * 1024 * 1024 && mode?.intValue == 0o600, "CSV complete stream or permissions failed")
        let lines = content.components(separatedBy: "\r\n")
        try require(lines.count == total + 2 && lines[0] + "\r\n" == header, "CSV header repeated or row omitted")
        for index in 0..<total { try require(lines[index + 1].hasPrefix("\(index * 60),1,"), "CSV row order/identity changed") }
        print("PASS CSV exporter streams more than 8 MiB with exact row order, one header and private atomic publication")

        let original = Data("keep original".utf8)
        for failure in ["request", "snapshot", "cursor", "cancel", "publish"] {
            try PrivateFile.write(original, to: target)
            var pages = 0, cancelled = false
            do {
                _ = try StatisticsCSVExporter.write(to: target, start: 0, end: end, request: { query in
                    if query["op"] as? String == "exportValidate" { return NSNull() }
                    var value = try page(query) as! [String: Any]; pages += 1
                    if pages == 2 {
                        if failure == "request" { throw RuntimeError("fixture IO failure") }
                        if failure == "snapshot" { value["snapshot"] = ["id": String(repeating: "b", count: 32), "revision": 1] }
                        if failure == "cursor" { value["nextCursor"] = query["cursor"] }
                        if failure == "cancel" { cancelled = true }
                    }
                    return value
                }, checkCancellation: { if cancelled { throw RuntimeError("fixture cancellation") } },
                   beginPublish: { if failure == "publish" { throw RuntimeError("fixture final cancellation") } })
                throw CheckFailure(message: "CSV accepted \(failure)")
            } catch is RuntimeError { }
            let retained = try Data(contentsOf: target)
            let temporary = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(".keytrail-") }
            try require(retained == original && temporary.isEmpty, "CSV \(failure) replaced existing file or left temporary plaintext")
        }
        print("PASS CSV request/version/cursor/cancellation failures preserve existing file and discard partial output")
    }

    @MainActor static func checkCSVRuntimeRPC(_ directory: URL) throws {
        let start = 1_704_067_200.0, end = start + 1001 * 60
        do {
            let source = try ActivityStore(url: directory.appendingPathComponent("activity.sqlite"))
            try source.ingest((0..<1001).map { InputSample(timestamp: Date(timeIntervalSince1970: start + Double($0 * 60)), kind: .keyPress, keyLabel: $0 % 2 == 0 ? "A" : "B") }, observedThrough: Date(timeIntervalSince1970: end))
            try source.endActivity(at: Date(timeIntervalSince1970: end))
        }
        let runtime = try RuntimeController(isDemo: true, directory: directory)
        defer { runtime.shutdown() }
        func rpc(_ query: [String: Any]) throws -> Any {
            let response = runtime.handle(query)
            guard response["ok"] as? Bool == true else { throw RuntimeError(response["error"] as? String ?? "fixture RPC failed") }
            return response["result"] ?? NSNull()
        }
        let target = directory.appendingPathComponent("real.csv")
        let written = try StatisticsCSVExporter.write(to: target, start: start, end: end, request: rpc)
        let legacy = try rpc(["op": "export", "start": start, "end": end]) as? String
        let actual = try String(contentsOf: target, encoding: .utf8)
        try require(written == 1001 && actual == legacy, "Rust -> Runtime -> CSV stream differs from legacy bytes")
        let empty = try StatisticsCSVExporter.write(to: target, start: end, end: end + 60, request: rpc)
        let emptyBody = try String(contentsOf: target, encoding: .utf8)
        try require(empty == 0 && emptyBody.contains("minute_utc,"), "Empty CSV export omitted header or invented rows")
        print("PASS Actual Runtime CSV page RPC exports 1001 rows byte-identically and handles empty range")
        let first = try rpc(["op": "exportPage", "start": start, "end": end, "limit": 1]) as! [String: Any]
        let snapshot = first["snapshot"]!, cursor = first["nextCursor"]!
        _ = try rpc(["op": "delete", "start": start, "end": start + 60])
        let stale = runtime.handle(["op": "exportPage", "start": start, "end": end, "cursor": cursor, "limit": 1])
        let validation = runtime.handle(["op": "exportValidate", "snapshot": snapshot])
        try require(stale["ok"] as? Bool == false && validation["ok"] as? Bool == false, "Deletion left export cursor or final validation valid")
        print("PASS Runtime deletion invalidates CSV continuation and final snapshot validation")
    }
}
