import CryptoKit
import Darwin
import Foundation
import KeyTrailCore
import KeyTrailIPC
import KeyTrailRuntime

struct SyncFailure: Error, CustomStringConvertible {
    let description: String
    init(_ value: String) { description = value }
}
func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw SyncFailure(message) }
}

@MainActor
final class Fixture {
    let root = URL(fileURLWithPath: "/tmp/kt-sync-\(UUID().uuidString.prefix(8))", isDirectory: true)
    let collector = String(repeating: "A", count: 64)
    let viewer = String(repeating: "V", count: 64)
    let device = UUID().uuidString.lowercased()
    var process: Process?
    var runtime: RuntimeController?
    var port = 0
    var endpoint: String { "http://127.0.0.1:\(port)" }
    var local: URL { root.appendingPathComponent("local") }
    var remote: URL { root.appendingPathComponent("remote") }

    func setup() throws {
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SyncFailure("fixture socket failed") }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { throw SyncFailure("fixture bind failed") }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) } }
        port = Int(UInt16(bigEndian: address.sin_port))
        let config: [String: Any] = ["bind": "127.0.0.1:\(port)", "demoData": false, "dataDir": remote.path,
                                   "accounts": [["id": "fixture", "deviceId": device, "collectorToken": collector, "viewerToken": viewer]]]
        try PrivateFile.write(JSONSerialization.data(withJSONObject: config), to: root.appendingPathComponent("server.json"))
    }
    func startServer() async throws {
        let executable = ProcessInfo.processInfo.environment["KEYTRAIL_TEST_SERVER"] ?? FileManager.default.currentDirectoryPath + "/rust/target/debug/keytrail-server"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["serve", root.appendingPathComponent("server.json").path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run(); self.process = process
        for _ in 0..<100 {
            if !process.isRunning { throw SyncFailure("fixture server exited before ready") }
            if (try? await api("api/status")) != nil { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw SyncFailure("fixture server readiness timeout")
    }
    func stopServer() {
        if let process, process.isRunning { process.terminate(); process.waitUntilExit() }
        process = nil
    }
    func cleanup() {
        runtime?.shutdown(); runtime = nil
        stopServer()
        try? FileManager.default.removeItem(at: root)
    }
    func api(_ route: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: endpoint + "/" + route)!)
        request.timeoutInterval = 2
        request.setValue("Bearer \(viewer)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["ok"] as? Bool == true, let result = object["result"] as? [String: Any] else {
            throw SyncFailure("fixture API did not return success: \(route)")
        }
        return result
    }
    func rpc(_ request: [String: Any]) throws -> Any {
        guard let runtime else { throw SyncFailure("runtime missing") }
        let result = runtime.handle(request)
        guard result["ok"] as? Bool == true else { throw SyncFailure("runtime RPC \(request["op"] ?? "?"): \(result["error"] ?? "unknown")") }
        return result["result"] ?? NSNull()
    }
    func sync(expectError: Bool = false) async throws -> [String: Any] {
        _ = try rpc(["op": "syncNow"])
        for _ in 0..<600 {
            try await Task.sleep(nanoseconds: 50_000_000)
            let status = try rpc(["op": "syncStatus"]) as? [String: Any] ?? [:]
            if status["syncing"] as? Bool == false {
                let error = status["error"] as? String
                try check(expectError ? error != nil : error == nil, "unexpected sync status: \(error ?? "no error")")
                return status
            }
        }
        throw SyncFailure("runtime sync timeout")
    }
    func preferences(_ edit: (inout [String: Any]) -> Void) throws {
        var values = try (rpc(["op": "preferences"]) as? [String: Any])?["preferences"] as? [String: Any] ?? [:]
        edit(&values)
        _ = try rpc(["op": "setPreferences", "preferences": values])
    }
}

@main
struct SyncChecks {
    @MainActor static func main() async throws {
        let f = Fixture(); try f.setup(); defer { f.cleanup() }
        let base = Date(timeIntervalSince1970: 1_704_067_200)
        let start = base.timeIntervalSince1970, end = start + 180
        let texts = ["你好", "keyboard notes", "emoji 👋"]
        let key = SymmetricKey(data: Data(SHA256.hash(data: Data("KeyTrail public isolated demo text key v1".utf8))))
        do {
            let stats = try ActivityStore(url: f.local.appendingPathComponent("activity.sqlite"))
            let archive = try TextArchive(url: f.local.appendingPathComponent("text.sqlite"), key: key)
            for i in 0..<3 {
                let timestamp = base.addingTimeInterval(Double(i * 60))
                try stats.ingest([InputSample(timestamp: timestamp, kind: .keyPress, keyLabel: ["A", "B", "C"][i])], observedThrough: timestamp.addingTimeInterval(10))
                try stats.endActivity(at: timestamp.addingTimeInterval(10))
                _ = try archive.append(text: texts[i], at: timestamp.addingTimeInterval(1), applicationBundleID: "com.keytrail.synthetic")
            }
            // A text-only minute verifies the independent opt-in journal can wake sync
            // even when the aggregate journal has no new revisions.
            _ = try archive.append(text: "text-only scheduling fixture", at: base.addingTimeInterval(181), applicationBundleID: "com.keytrail.synthetic")
        }
        f.runtime = try RuntimeController(isDemo: true, directory: f.local)
        let history = try f.rpc(["op": "textSearch", "start": start, "end": end, "keyword": "你好"]) as? [String: Any] ?? [:]
        try check(history["matchedCount"] as? Int == 1 && history["totalCharacters"] as? Int == texts.map(\.count).reduce(0,+), "text search/total characters lost range semantics")
        let textMetrics = try f.rpc(["op": "textMetrics", "start": start, "end": end]) as? [String: Any] ?? [:]
        try check(textMetrics["totalCharacters"] as? Int == texts.map(\.count).reduce(0,+) && textMetrics["recordedMinutes"] as? Int == 3 && textMetrics["archivedActiveSeconds"] as? Double == 90, "metadata-only text metrics diverged from range")
        let info = try f.rpc(["op": "storageInfo"]) as? [String: Any] ?? [:]
        try check(info["textRecordCount"] as? Int == 4 && (info["textBytes"] as? Int ?? 0) > 0 && (info["databaseBytes"] as? Int ?? 0) > (info["textBytes"] as? Int ?? 0), "storage excluded text archive")
        print("PASS runtime encrypted search, whole-range character count and combined storage")

        let rejected = f.runtime!.handle(["op": "setPreferences", "preferences": ["textRecordingEnabled": true]])
        let login = f.runtime!.handle(["op": "setPreferences", "preferences": ["launchAtLoginEnabled": true]])
        try check(rejected["ok"] as? Bool == false && login["ok"] as? Bool == false && !f.runtime!.preferences.textRecordingEnabled && !f.runtime!.preferences.launchAtLoginEnabled && !f.runtime!.status.monitoring, "preview changed permission-sensitive state")
        for request in [["op": "replicaApply", "changes": []], ["op": "ingest", "samples": []]] as [[String: Any]] {
            try check(f.runtime!.handle(request)["ok"] as? Bool == false, "public IPC accepted private write")
        }
        print("PASS preview permission/login boundaries and private write RPC isolation")

        try await f.startServer()
        let invalid = f.runtime!.handle(["op": "configureSync", "endpoint": "http://example.com", "token": f.collector, "deviceId": f.device, "enabled": true])
        let short = f.runtime!.handle(["op": "configureSync", "endpoint": f.endpoint, "token": String(repeating: "x", count: 32), "deviceId": f.device, "enabled": true])
        try check(invalid["ok"] as? Bool == false && short["ok"] as? Bool == false, "sync validation differs from server")
        _ = try f.rpc(["op": "configureSync", "endpoint": f.endpoint, "token": f.collector, "deviceId": f.device, "enabled": true])
        try f.preferences { $0["textSyncEnabled"] = true }
        var synced = try await f.sync()
        let summaryQuery: [String: Any] = ["op": "summary", "start": start, "end": end]
        var remoteStats = try await f.api("api/query", body: summaryQuery)
        var remoteText = try await f.api("api/text-query", body: ["start": start, "end": end, "offset": 0, "limit": 50])
        try check(remoteStats["keyPresses"] as? Int == 3 && remoteText["total"] as? Int == 3 && (synced["cursor"] as? Int ?? 0) > 0 && (synced["textCursor"] as? Int ?? 0) > 0, "initial statistics/text sync failed")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        let records = try decoder.decode([EncryptedTextRecord].self, from: JSONSerialization.data(withJSONObject: remoteText["records"]!))
        let imported = try TextArchive(url: f.root.appendingPathComponent("decryption.sqlite"), key: key)
        try imported.importEncrypted(records)
        let decrypted = try imported.search(start: base, end: base.addingTimeInterval(180))
        try check(Set(decrypted.entries.map(\.text)) == Set(texts), "server changed authenticated ciphertext")
        print("PASS actual Rust HTTP server receives both journals; viewer ciphertext decrypts identically")

        let aggregateBeforeTextOnlyDelete = synced["cursor"] as? Int
        let textBeforeTextOnlyDelete = synced["textCursor"] as? Int ?? 0
        _ = try f.rpc(["op": "delete", "start": end, "end": end + 60])
        for _ in 0..<80 {
            try await Task.sleep(nanoseconds: 50_000_000)
            synced = try f.rpc(["op": "syncStatus"]) as? [String: Any] ?? [:]
            if (synced["textCursor"] as? Int ?? 0) > textBeforeTextOnlyDelete && synced["syncing"] as? Bool == false { break }
        }
        try check(synced["cursor"] as? Int == aggregateBeforeTextOnlyDelete && (synced["textCursor"] as? Int ?? 0) > textBeforeTextOnlyDelete && synced["error"] == nil,
                  "text-only pending deletion did not automatically sync within four seconds, or changed aggregate cursor")
        let removedTextOnly = try await f.api("api/text-query", body: ["start": end, "end": end + 60, "limit": 50])
        try check(removedTextOnly["total"] as? Int == 0, "automatically acknowledged text-only deletion remained on server")
        print("PASS text-only pending deletion automatically wakes sync with independent aggregate cursor")

        let beforeCursor = synced["cursor"] as? Int, beforeTextCursor = synced["textCursor"] as? Int
        synced = try await f.sync()
        try check(synced["cursor"] as? Int == beforeCursor && synced["textCursor"] as? Int == beforeTextCursor, "empty retry advanced cursors")
        remoteStats = try await f.api("api/query", body: summaryQuery)
        try check(remoteStats["keyPresses"] as? Int == 3, "retry doubled aggregate")
        print("PASS acknowledged empty retry preserves exact counts and durable cursors")

        let preferencesURL = f.local.appendingPathComponent("preferences.json")
        let backup = f.local.appendingPathComponent("preferences.backup")
        try FileManager.default.moveItem(at: preferencesURL, to: backup)
        try FileManager.default.createDirectory(at: preferencesURL, withIntermediateDirectories: false)
        let failed = f.runtime!.handle(["op": "configureSync", "endpoint": "http://localhost:\(f.port)", "token": String(repeating: "B", count: 64), "deviceId": f.device, "enabled": true])
        try FileManager.default.removeItem(at: preferencesURL)
        try FileManager.default.moveItem(at: backup, to: preferencesURL)
        try check(failed["ok"] as? Bool == false, "forced preferences rename failure was ignored")
        synced = try await f.sync()
        try check(synced["endpoint"] as? String == f.endpoint, "failed configuration replaced endpoint")
        let attrs = try FileManager.default.attributesOfItem(atPath: preferencesURL.path)
        try check((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600, "settings have broad permissions")
        let persisted = try String(contentsOf: preferencesURL, encoding: .utf8)
        try check(!persisted.contains(f.collector) && !persisted.contains(String(repeating: "B", count: 64)), "credentials leaked into settings")
        print("PASS failed endpoint save preserves old authenticated credential; private atomic preferences contain no token")

        f.stopServer()
        try await Task.sleep(nanoseconds: 3_300_000_000)
        synced = try f.rpc(["op": "syncStatus"]) as? [String: Any] ?? [:]
        try check(synced["error"] == nil && synced["syncing"] as? Bool == false,
                  "empty journals contacted stopped server before heartbeat")
        print("PASS empty journals stay locally idle with server stopped across multiple maintenance ticks")
        _ = try f.rpc(["op": "delete", "start": start, "end": start + 60])
        for _ in 0..<80 {
            try await Task.sleep(nanoseconds: 50_000_000)
            synced = try f.rpc(["op": "syncStatus"]) as? [String: Any] ?? [:]
            if synced["error"] as? String != nil { break }
        }
        try check(synced["error"] as? String != nil, "pending deletion failed to trigger automatic network attempt within four seconds")
        try check(synced["cursor"] as? Int == beforeCursor && synced["textCursor"] as? Int == beforeTextCursor, "offline failure acknowledged unsent deletion")
        let localText = try f.rpc(["op": "textSearch", "start": start, "end": end]) as? [String: Any] ?? [:]
        try check(localText["totalRecords"] as? Int == 2, "joint delete left local text")
        try await f.startServer(); _ = try await f.sync()
        remoteStats = try await f.api("api/query", body: summaryQuery)
        remoteText = try await f.api("api/text-query", body: ["start": start, "end": end, "limit": 50])
        try check(remoteStats["keyPresses"] as? Int == 2 && remoteText["total"] as? Int == 2, "offline joint deletion did not propagate")
        print("PASS disconnected joint deletion retains cursors then removes statistics and ciphertext after reconnect")

        let beforeHeartbeat = try f.rpc(["op": "syncStatus"]) as? [String: Any] ?? [:]
        let previousStatsSuccess = beforeHeartbeat["lastSuccess"] as? Double ?? 0
        let previousTextSuccess = beforeHeartbeat["lastTextSuccess"] as? Double ?? 0
        f.stopServer(); try FileManager.default.removeItem(at: f.remote)
        try await f.startServer()
        // No force call and no new local changes: the idle heartbeat must discover
        // a rebuilt replica and replay both durable journals on its own.
        let heartbeatStarted = ProcessInfo.processInfo.systemUptime
        var replayed = false
        while ProcessInfo.processInfo.systemUptime - heartbeatStarted < 66 {
            let state = try f.rpc(["op": "syncStatus"]) as? [String: Any] ?? [:]
            if (state["lastSuccess"] as? Double ?? 0) > previousStatsSuccess &&
                (state["lastTextSuccess"] as? Double ?? 0) > previousTextSuccess && state["syncing"] as? Bool == false {
                replayed = true; break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try check(replayed, "idle heartbeat did not automatically replay both rebuilt replicas within 66 seconds")
        remoteStats = try await f.api("api/query", body: summaryQuery)
        remoteText = try await f.api("api/text-query", body: ["start": start, "end": end, "limit": 50])
        try check(remoteStats["keyPresses"] as? Int == 2 && remoteText["total"] as? Int == 2, "replica reset resurrected deletion or lost retained history")
        print("PASS idle heartbeat automatically discovers recreated server and replays independent replicas without resurrecting deleted data")

        _ = try f.rpc(["op": "configureSync", "endpoint": f.endpoint, "token": f.collector, "deviceId": f.device, "enabled": false])
        try check(!f.runtime!.preferences.syncEnabled && !f.runtime!.preferences.textSyncEnabled, "disabling base sync left dependent flag enabled")
        try f.preferences { $0["floatingWindowEnabled"] = true; $0["textSyncEnabled"] = true }
        try check(f.runtime!.preferences.floatingWindowEnabled && !f.runtime!.preferences.textSyncEnabled, "normalized settings trap prevented independent option")
        print("PASS disabling sync normalizes text sync and permits unrelated settings changes")

        _ = try f.rpc(["op": "configureSync", "endpoint": f.endpoint, "token": f.collector, "deviceId": f.device, "enabled": true])
        try f.preferences { $0["textSyncEnabled"] = true; $0["storageLimitBytes"] = 1_048_576 }
        let export = try f.rpc(["op": "textExport", "start": start, "end": end, "keyword": "keyboard"]) as? String ?? ""
        try check(export.contains("keyboard notes") && !export.contains("emoji"), "keyword export leaked nonmatching record")
        _ = try f.rpc(["op": "clear"]); _ = try await f.sync()
        remoteStats = try await f.api("api/query", body: summaryQuery)
        remoteText = try await f.api("api/text-query", body: ["start": start, "end": end, "limit": 50])
        try check(remoteStats["keyPresses"] as? Int == 0 && remoteText["total"] as? Int == 0 && !f.runtime!.status.monitoring, "clear did not remove both remote datasets or stop capture")
        print("PASS filtered export and full clear propagate while capture remains stopped")
        print("Passed 11 sync/runtime integration groups; synthetic temporary data only, no real capture or external upload")
    }
}
