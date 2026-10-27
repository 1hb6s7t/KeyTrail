import Foundation
import CryptoKit
import Security
import LocalAuthentication
import CSQLite
import KeyTrailIPC

public struct TextRecordMetadata: Codable, Sendable, Equatable {
    public let id: String
    public let timestamp: Date
    public let applicationBundleID: String
    public let characterCount: Int
    public init(id: String, timestamp: Date, applicationBundleID: String, characterCount: Int) {
        self.id=id; self.timestamp=timestamp; self.applicationBundleID=applicationBundleID; self.characterCount=characterCount
    }
}
public struct TextStorageInfo: Codable, Sendable {
    public let bytes:Int64
    public let records:Int64
    public let oldestTime:Double?
}
public struct CombinedRetentionResult: Codable, Sendable {
    public let deletedMinutes:Int64
    public let deletedTextRecords:Int64
    public let combinedBytes:Int64
    public let limitMet:Bool
}
/// Metadata-only speed of archived text; pasted fragments are included. This is
/// neither keyboard typing speed nor an estimate of activity in unsupported apps.
public struct TextMetrics: Codable, Sendable {
    public let totalCharacters:Int64
    public let archivedActiveSeconds:Double
    public let averageCharactersPerActiveMinute:Double?
    public let peakCharactersPerMinute:Int64
    public let peakMinute:Double?
    public let recordedMinutes:Int64
}
public struct TextSearchEntry: Codable, Sendable { public let metadata: TextRecordMetadata; public let text: String }
public struct TextSearchResult: Codable, Sendable {
    public let entries: [TextSearchEntry]
    public let matchedCount: Int
    public let scannedRecords: Int
    public let totalRecords: Int
    public let totalCharacters: Int
    public let hasMore: Bool
    public let coverageComplete: Bool
}
public struct EncryptedTextRecord: Codable, Sendable {
    public let version: Int
    public let metadata: TextRecordMetadata
    public let sealedBoxBase64: String
    public let aadBase64: String
    public init(version: Int = 1, metadata: TextRecordMetadata, sealedBoxBase64: String, aadBase64: String) {
        self.version=version; self.metadata=metadata; self.sealedBoxBase64=sealedBoxBase64; self.aadBase64=aadBase64
    }
}
public struct TextChange: Codable, Sendable {
    public let revision: Int64
    public let id: String
    public let deleted: Bool
    public let record: EncryptedTextRecord?
    public init(revision:Int64,id:String,deleted:Bool,record:EncryptedTextRecord?) {self.revision=revision;self.id=id;self.deleted=deleted;self.record=record}
}
public struct TextChangePage: Codable, Sendable {public let changes:[TextChange];public let cursor:Int64;public let hasMore:Bool}
public struct TextApplyResult: Codable, Sendable {public let applied:Int;public let ignored:Int}

public struct TextArchiveError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message=message }
}

/// Single-caller encrypted local archive. No plaintext text/index/key is written to SQLite.
public final class TextArchive {
    private var db: OpaquePointer?
    private let key: SymmetricKey
    private let scanSessionID=UUID().uuidString
    private var scanTotals:(first:Int64,last:Int64,revision:Int64,records:Int,characters:Int)?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let keyCheckAAD = Data("KeyTrail.text-archive.key-check.v1".utf8)
    private static let keyCheckBody = Data("KeyTrail archive key verified".utf8)
    public init(url: URL, key injectedKey: SymmetricKey? = nil, keychainService: String = "com.auriel.keytrail.text", keychainAccount: String = "archive-v1") throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var connection: OpaquePointer?
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let connection else {
            if let connection { sqlite3_close(connection) }; throw TextArchiveError("无法打开加密文字数据库。")
        }
        // Keep connection cleanup local until all initialization has succeeded.
        var accepted=false
        defer { if !accepted { sqlite3_close(connection) } }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        sqlite3_busy_timeout(connection, 3000)
        func execute(_ sql: String) throws {
            guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else { throw TextArchiveError(String(cString: sqlite3_errmsg(connection))) }
        }
        try execute("PRAGMA secure_delete=ON;PRAGMA journal_mode=DELETE;PRAGMA synchronous=FULL;")
        var versionStatement: OpaquePointer?
        guard sqlite3_prepare_v2(connection,"PRAGMA user_version",-1,&versionStatement,nil)==SQLITE_OK, let versionStatement else { throw TextArchiveError("无法读取文字库版本。") }
        let version = sqlite3_step(versionStatement)==SQLITE_ROW ? sqlite3_column_int(versionStatement,0) : -1
        sqlite3_finalize(versionStatement)
        guard version == 0 || version == 1 else { throw TextArchiveError("不支持的文字数据库版本。") }
        try execute("CREATE TABLE IF NOT EXISTS text_records(id TEXT PRIMARY KEY,time_ms INTEGER NOT NULL,app TEXT NOT NULL,char_count INTEGER NOT NULL,ciphertext BLOB NOT NULL,aad BLOB NOT NULL);CREATE INDEX IF NOT EXISTS text_time ON text_records(time_ms,id);CREATE TABLE IF NOT EXISTS text_meta(name TEXT PRIMARY KEY,value BLOB NOT NULL);CREATE TABLE IF NOT EXISTS text_sync_state(id INTEGER PRIMARY KEY CHECK(id=1),revision INTEGER NOT NULL);CREATE TABLE IF NOT EXISTS text_sync(id TEXT PRIMARY KEY,revision INTEGER NOT NULL UNIQUE,deleted INTEGER NOT NULL,record BLOB);CREATE TABLE IF NOT EXISTS text_replica_versions(id TEXT PRIMARY KEY,revision INTEGER NOT NULL);PRAGMA user_version=1;")
        // Independent data revision changes on every row mutation, including remote
        // updates whose source revision is below the greatest previously seen revision.
        try execute("CREATE TABLE IF NOT EXISTS text_query_state(id INTEGER PRIMARY KEY CHECK(id=1),revision INTEGER NOT NULL);INSERT OR IGNORE INTO text_query_state VALUES(1,abs(random()%4503599627370496));")
        for operation in ["INSERT","UPDATE","DELETE"] {
            try execute("CREATE TRIGGER IF NOT EXISTS text_query_\(operation.lowercased()) AFTER \(operation) ON text_records BEGIN SELECT CASE WHEN (SELECT revision FROM text_query_state WHERE id=1)>=9007199254740991 THEN RAISE(ABORT,'text snapshot revision exhausted') END;UPDATE text_query_state SET revision=revision+1 WHERE id=1;END;")
        }
        var checkStatement: OpaquePointer?
        guard sqlite3_prepare_v2(connection,"SELECT value FROM text_meta WHERE name='key_check'",-1,&checkStatement,nil)==SQLITE_OK, let checkStatement else { throw TextArchiveError("无法读取密钥校验记录。") }
        let existingCheck: Data?
        if sqlite3_step(checkStatement)==SQLITE_ROW, let bytes=sqlite3_column_blob(checkStatement,0) { existingCheck=Data(bytes:bytes,count:Int(sqlite3_column_bytes(checkStatement,0))) } else { existingCheck=nil }
        sqlite3_finalize(checkStatement)
        if existingCheck == nil {
            var checkCount:OpaquePointer?
            guard sqlite3_prepare_v2(connection,"SELECT COUNT(*) FROM text_records",-1,&checkCount,nil)==SQLITE_OK,let checkCount else {throw TextArchiveError("无法检查文字库。")}
            let rows=sqlite3_step(checkCount)==SQLITE_ROW ? sqlite3_column_int64(checkCount,0) : 1
            sqlite3_finalize(checkCount)
            guard rows==0 else {throw TextArchiveError("现有文字记录缺少密钥校验；拒绝建立新密钥。")}
        }
        if let injectedKey { guard injectedKey.bitCount == 256 else { throw TextArchiveError("文字加密需要 256 位密钥。") }; key=injectedKey }
        else { key=try Self.loadKey(service:keychainService,account:keychainAccount,allowCreate:existingCheck == nil) }
        if let existingCheck {
            do {
                let plaintext=try AES.GCM.open(AES.GCM.SealedBox(combined:existingCheck),using:key,authenticating:Self.keyCheckAAD)
                guard plaintext==Self.keyCheckBody else { throw TextArchiveError("密钥校验失败。") }
            } catch { throw TextArchiveError("文字密钥不匹配或数据已损坏；未覆盖现有密钥/记录。") }
        } else {
            var countStatement: OpaquePointer?
            guard sqlite3_prepare_v2(connection,"SELECT COUNT(*) FROM text_records",-1,&countStatement,nil)==SQLITE_OK, let countStatement else { throw TextArchiveError("文字库校验失败。") }
            let count=sqlite3_step(countStatement)==SQLITE_ROW ? sqlite3_column_int64(countStatement,0) : 1
            sqlite3_finalize(countStatement)
            guard count==0 else { throw TextArchiveError("现有文字记录缺少密钥校验；拒绝建立新密钥。") }
            let sealed=try AES.GCM.seal(Self.keyCheckBody,using:key,authenticating:Self.keyCheckAAD).combined!
            var insert: OpaquePointer?
            guard sqlite3_prepare_v2(connection,"INSERT INTO text_meta VALUES('key_check',?)",-1,&insert,nil)==SQLITE_OK, let insert else { throw TextArchiveError("无法保存密钥校验记录。") }
            defer { sqlite3_finalize(insert) }
            _ = sealed.withUnsafeBytes { sqlite3_bind_blob(insert,1,$0.baseAddress,Int32($0.count),unsafeBitCast(-1,to:sqlite3_destructor_type.self)) }
            guard sqlite3_step(insert)==SQLITE_DONE else { throw TextArchiveError("无法保存密钥校验记录。") }
        }
        db=connection;accepted=true
        let state=try prepare("SELECT COUNT(*) FROM text_sync_state");defer{sqlite3_finalize(state)}
        if try next(state),sqlite3_column_int64(state,0)==0 {
            try transaction {
                try execute("INSERT INTO text_sync_state VALUES(1,0)")
                try visitEncrypted(start:Date(timeIntervalSince1970:0),end:Date(timeIntervalSince1970:999_999_999_999),limit:Int(Int32.max)) {record in try journal(id:record.metadata.id,record:record);return true}
            }
        }
    }
    deinit { if let db { sqlite3_close(db) } }

    @discardableResult public func append(text: String, at date: Date = Date(), applicationBundleID: String) throws -> TextRecordMetadata {
        guard !text.isEmpty, text.count<=16_384, text.utf8.count<=262_144 else { throw TextArchiveError("单条提交文字长度无效或超过上限。") }
        let milliseconds=try Self.milliseconds(date)
        let metadata=TextRecordMetadata(id:UUID().uuidString.lowercased(),timestamp:Date(timeIntervalSince1970:Double(milliseconds)/1000),applicationBundleID:applicationBundleID,characterCount:text.count)
        try validate(metadata)
        let sealed=try AES.GCM.seal(Data(text.utf8),using:key,authenticating:aad(metadata)).combined!
        let record=EncryptedTextRecord(metadata:metadata,sealedBoxBase64:sealed.base64EncodedString(),aadBase64:try aad(metadata).base64EncodedString())
        try transaction {try insert(record);try journal(id:metadata.id,record:record)}
        return metadata
    }
    /// Scans every candidate in a bounded-size page of output, with no plaintext index.
    /// Large ranges are explicit bounded scans; coverageComplete is false above 10,000 rows.
    public func search(start: Date, end: Date, keyword: String = "", offset: Int = 0, limit: Int = 50) throws -> TextSearchResult {
        guard offset>=0, offset<=100_000, (1...200).contains(limit), keyword.count<=1024 else { throw TextArchiveError("无效的搜索分页或关键词。") }
        let total=try recordCount(start:start,end:end)
        var matched=0, scanned=0, scanBytes=0, outputBytes=0;var entries:[TextSearchEntry]=[];var outputFull=false
        try visitEncrypted(start:start,end:end,limit:10_000) { record in
            let estimated=record.sealedBoxBase64.utf8.count+record.aadBase64.utf8.count
            guard scanBytes+estimated<=64*1024*1024 else{return false}
            scanBytes+=estimated;scanned+=1
            let text=try decrypt(record)
            if keyword.isEmpty || text.localizedCaseInsensitiveContains(keyword) {
                if matched>=offset && entries.count<limit && !outputFull {
                    let bytes=text.utf8.count+1024
                    if outputBytes+bytes<=4*1024*1024 {entries.append(TextSearchEntry(metadata:record.metadata,text:text));outputBytes+=bytes}
                    else {outputFull=true}
                }
                matched+=1
            }
            return true
        }
        return TextSearchResult(entries:entries,matchedCount:matched,scannedRecords:scanned,totalRecords:total,totalCharacters:try characterCount(start:start,end:end),hasMore:matched>offset+entries.count,coverageComplete:scanned==total)
    }

    public func archiveVersion() throws -> Int64 {
        try integer("SELECT revision FROM text_query_state WHERE id=1")
    }
    public func validateSnapshot(revision:Int64) throws {
        guard revision>=0,revision<=9_007_199_254_740_991,try archiveVersion()==revision else {
            throw TextArchiveError("文字数据已变化，分页快照失效，请重新搜索或导出。")
        }
    }
    /// Bounded seek pagination. Continue through empty matching pages while hasMore
    /// is true. Reuse a prior input cursor to revisit a page of an unchanged snapshot.
    public func searchPage(start:Date,end:Date,keyword:String="",cursor:TextScanCursor?=nil,limit:Int=100) throws -> TextScanPage {
        guard (1...200).contains(limit),keyword.count<=1024 else{throw TextArchiveError("无效的文字扫描分页或关键词。")}
        let(first,last)=try bounds(start,end)
        let fingerprintData=try JSONSerialization.data(withJSONObject:["startMilliseconds":first,"endMilliseconds":last,"keyword":keyword,"locale":Locale.current.identifier,"session":scanSessionID],options:.sortedKeys)
        let fingerprint=SHA256.hash(data:fingerprintData).map{String(format:"%02x",$0)}.joined()
        try execute("BEGIN DEFERRED")
        do {
            let revision=try archiveVersion()
            if let cursor {
                try validateSnapshot(revision:cursor.snapshotRevision)
                guard cursor.queryFingerprint==fingerprint,cursor.timestampMilliseconds>=first,cursor.timestampMilliseconds<last,UUID(uuidString:cursor.id) != nil else{throw TextArchiveError("文字分页游标不属于此范围或关键词，请重新搜索。")}
            }
            let total:Int,characters:Int
            if let cached=scanTotals,cached.first==first,cached.last==last,cached.revision==revision {
                total=cached.records;characters=cached.characters
            } else {
                let totals=try prepare("SELECT COUNT(*),COALESCE(SUM(char_count),0) FROM text_records WHERE time_ms>=? AND time_ms<?")
                sqlite3_bind_int64(totals,1,first);sqlite3_bind_int64(totals,2,last)
                do {guard try next(totals) else{throw TextArchiveError("无法读取文字范围总量。")};total=Int(sqlite3_column_int64(totals,0));characters=Int(sqlite3_column_int64(totals,1));sqlite3_finalize(totals)}catch{sqlite3_finalize(totals);throw error}
                scanTotals=(first,last,revision,total,characters)
            }
            let statement:OpaquePointer
            if let cursor {
                // Cursor already lies within the frozen range. Row-value comparison
                // seeks the compound index directly, including dense same-ms rows.
                statement=try prepare("SELECT id,time_ms,app,char_count,ciphertext,aad FROM text_records WHERE (time_ms,id)>(?1,?2) AND time_ms<?3 ORDER BY time_ms,id LIMIT 257")
                sqlite3_bind_int64(statement,1,cursor.timestampMilliseconds);sqlite3_bind_text(statement,2,cursor.id,-1,transient);sqlite3_bind_int64(statement,3,last)
            } else {
                statement=try prepare("SELECT id,time_ms,app,char_count,ciphertext,aad FROM text_records WHERE time_ms>=?1 AND time_ms<?2 ORDER BY time_ms,id LIMIT 257")
                sqlite3_bind_int64(statement,1,first);sqlite3_bind_int64(statement,2,last)
            }
            var entries:[TextHistoryEntry]=[],scanned=0,scanBytes=0,outputBytes=4096,more=false,lastTime:Int64?,lastID:String?
            let encoder=JSONEncoder();encoder.dateEncodingStrategy = .secondsSince1970
            do {
                while try next(statement) {
                    if scanned>=256 || entries.count>=limit {more=true;break}
                    let bytes=Int(sqlite3_column_bytes(statement,4))+Int(sqlite3_column_bytes(statement,5))
                    if scanBytes+bytes>4*1024*1024 {more=true;break}
                    guard let idBytes=sqlite3_column_text(statement,0) else{throw TextArchiveError("文字记录ID缺失。")}
                    let id=String(cString:idBytes),time=sqlite3_column_int64(statement,1)
                    let record=try envelope(statement,id:id,offset:1),plain=try decrypt(record)
                    if keyword.isEmpty || plain.localizedCaseInsensitiveContains(keyword) {
                        let metadata=record.metadata
                        let entry=TextHistoryEntry(metadata:TextMetadata(id:metadata.id,timestamp:metadata.timestamp,applicationBundleID:metadata.applicationBundleID,characterCount:metadata.characterCount),text:plain)
                        let encoded=try encoder.encode(entry).count+1
                        if outputBytes+encoded>1024*1024 {
                            guard scanned>0 else{throw TextArchiveError("单条文字超过扫描输出预算。")};more=true;break
                        }
                        entries.append(entry);outputBytes+=encoded
                    }
                    scanBytes+=bytes;scanned+=1;lastTime=time;lastID=id
                }
                sqlite3_finalize(statement)
            }catch{sqlite3_finalize(statement);throw error}
            let nextCursor:TextScanCursor?
            if more {
                guard let lastTime,let lastID else{throw TextArchiveError("单条文字超过扫描预算，未跳过任何记录。")}
                nextCursor=TextScanCursor(snapshotRevision:revision,timestampMilliseconds:lastTime,id:lastID,queryFingerprint:fingerprint)
            } else {nextCursor=nil}
            try execute("COMMIT")
            return TextScanPage(entries:entries,scannedRecords:scanned,matchedCount:entries.count,totalRecords:total,totalCharacters:characters,snapshotRevision:revision,nextCursor:nextCursor,hasMore:more,coverageComplete:!more)
        }catch{try? execute("ROLLBACK");throw error}
    }
    public func delete(ids: [String]) throws {
        guard ids.count<=1000, ids.allSatisfy({UUID(uuidString:$0) != nil}) else { throw TextArchiveError("无效的删除 ID 列表。") }
        try transaction {for id in Set(ids) {try journal(id:id,record:nil);let statement=try prepare("DELETE FROM text_records WHERE id=?");defer{sqlite3_finalize(statement)};sqlite3_bind_text(statement,1,id,-1,transient);try finish(statement)}}
    }
    public func delete(start: Date, end: Date) throws {
        let(first,last)=try bounds(start,end)
        try transaction {try deleteRecords(first:first,last:last)}
    }
    private func deleteRecords(first:Int64,last:Int64) throws {
        let statement=try prepare("SELECT id FROM text_records WHERE time_ms>=? AND time_ms<?");defer{sqlite3_finalize(statement)}
        sqlite3_bind_int64(statement,1,first);sqlite3_bind_int64(statement,2,last)
        while try next(statement) {if let id=sqlite3_column_text(statement,0) {try journal(id:String(cString:id),record:nil)}}
        let deletion=try prepare("DELETE FROM text_records WHERE time_ms>=? AND time_ms<?");defer{sqlite3_finalize(deletion)}
        sqlite3_bind_int64(deletion,1,first);sqlite3_bind_int64(deletion,2,last);try finish(deletion)
    }
    public func clear() throws {try delete(start:Date(timeIntervalSince1970:0),end:Date(timeIntervalSince1970:999_999_999_999))}

    /// The caller must flush/end the Rust engine's transient windows before calling.
    /// Uses SQLite's on-disk DELETE-journal multi-database transaction, including both journals.
    public func deleteTogetherWithStatistics(at statsURL:URL,start:Date,end:Date) throws {
        _ = try bounds(start,end)
        if start==end{return}
        let lower=floor(start.timeIntervalSince1970/60)*60,upper=ceil(end.timeIntervalSince1970/60)*60
        try deleteTogether(at:statsURL,lower:lower,upper:upper,all:false)
    }
    public func clearTogetherWithStatistics(at statsURL:URL) throws {
        try deleteTogether(at:statsURL,lower:0,upper:999_999_999_999,all:true)
    }
    private func withStatistics<T>(at statsURL:URL,_ body:() throws -> T) throws -> T {
        guard statsURL.isFileURL,FileManager.default.fileExists(atPath:statsURL.path),
              let db,let mainPath=sqlite3_db_filename(db,"main"),!String(cString:mainPath).isEmpty,
              URL(fileURLWithPath:String(cString:mainPath)).standardizedFileURL != statsURL.standardizedFileURL else {
            throw TextArchiveError("统一删除需要两个不同的本地持久数据库。")
        }
        try execute("PRAGMA foreign_keys=ON")
        let attach=try prepare("ATTACH DATABASE ? AS stats");sqlite3_bind_text(attach,1,statsURL.path,-1,transient)
        do {try finish(attach);sqlite3_finalize(attach)}catch{sqlite3_finalize(attach);throw error}
        defer{try? execute("DETACH DATABASE stats")}
        for schema in ["main","stats"] {
            let check=try prepare("PRAGMA \(schema).journal_mode");defer{sqlite3_finalize(check)}
            guard try next(check),let mode=sqlite3_column_text(check,0),String(cString:mode).lowercased()=="delete" else{
                throw TextArchiveError("统一删除需要两个数据库都使用 DELETE 日志；未修改任何记录。")
            }
        }
        try execute("PRAGMA stats.secure_delete=ON;PRAGMA stats.synchronous=FULL")
        return try body()
    }
    private func deleteTogether(at statsURL:URL,lower:Double,upper:Double,all:Bool) throws {
        try withStatistics(at:statsURL){try deleteAttached(lower:lower,upper:upper,all:all)}
    }
    private func deleteAttached(lower:Double,upper:Double,all:Bool) throws {
        try transaction {
            try deleteRecords(first:Int64(lower*1000),last:Int64(upper*1000))
            let query=all ? "SELECT minute FROM stats.minutes ORDER BY minute":"SELECT minute FROM stats.minutes WHERE minute>=? AND minute<? ORDER BY minute"
            let minutes=try prepare(query);defer{sqlite3_finalize(minutes)}
            if !all {sqlite3_bind_double(minutes,1,lower);sqlite3_bind_double(minutes,2,upper)}
            while try next(minutes) {
                let state=try prepare("SELECT revision FROM stats.sync_state WHERE id=1");defer{sqlite3_finalize(state)}
                guard try next(state),sqlite3_column_int64(state,0)<9_007_199_254_740_991 else {throw TextArchiveError("统计同步 revision 无效或已耗尽。")}
                let revision=sqlite3_column_int64(state,0)+1
                let advance=try prepare("UPDATE stats.sync_state SET revision=? WHERE id=1");defer{sqlite3_finalize(advance)}
                sqlite3_bind_int64(advance,1,revision);try finish(advance)
                let tombstone=try prepare("INSERT INTO stats.sync_journal(minute,revision,deleted,record) VALUES(?,?,1,NULL) ON CONFLICT(minute) DO UPDATE SET revision=excluded.revision,deleted=1,record=NULL");defer{sqlite3_finalize(tombstone)}
                sqlite3_bind_int64(tombstone,1,sqlite3_column_int64(minutes,0));sqlite3_bind_int64(tombstone,2,revision);try finish(tombstone)
            }
            let deletion=try prepare(all ? "DELETE FROM stats.minutes":"DELETE FROM stats.minutes WHERE minute>=? AND minute<?");defer{sqlite3_finalize(deletion)}
            if !all {sqlite3_bind_double(deletion,1,lower);sqlite3_bind_double(deletion,2,upper)}
            try finish(deletion)
        }
    }
    /// Only records inside [start,end) contribute counts or their timestamp + 30s
    /// windows. Union windows are clipped to end; historical outside rows never
    /// inflate the denominator. No ciphertext is read or decrypted.
    public func metrics(start:Date,end:Date) throws -> TextMetrics {
        let(first,last)=try bounds(start,end)
        let statement=try prepare("SELECT time_ms,char_count FROM text_records WHERE time_ms>=? AND time_ms<? ORDER BY time_ms,id");defer{sqlite3_finalize(statement)}
        sqlite3_bind_int64(statement,1,first);sqlite3_bind_int64(statement,2,last)
        var total:Int64=0,activeMilliseconds:Int64=0,minuteCharacters:Int64=0,peak:Int64=0,recordedMinutes:Int64=0
        var windowStart:Int64?,windowEnd:Int64=0,currentMinute:Int64?,peakMinute:Int64?
        func checked(_ a:Int64,_ b:Int64)throws->Int64 {let(value,overflow)=a.addingReportingOverflow(b);guard !overflow else{throw TextArchiveError("归档字符统计超出整数范围。")};return value}
        func finishMinute() {if let minute=currentMinute,minuteCharacters>peak {peak=minuteCharacters;peakMinute=minute}}
        while try next(statement) {
            let time=sqlite3_column_int64(statement,0),count=sqlite3_column_int64(statement,1)
            guard count>0 else{throw TextArchiveError("归档字符元数据无效。")}
            total=try checked(total,count)
            let minute=(time/60_000)*60
            if currentMinute != minute {finishMinute();currentMinute=minute;minuteCharacters=0;recordedMinutes+=1}
            minuteCharacters=try checked(minuteCharacters,count)
            let until=min(last,time+30_000)
            if let begin=windowStart {
                if time<=windowEnd {windowEnd=max(windowEnd,until)}
                else {activeMilliseconds=try checked(activeMilliseconds,windowEnd-begin);windowStart=time;windowEnd=until}
            } else {windowStart=time;windowEnd=until}
        }
        finishMinute()
        if let begin=windowStart {activeMilliseconds=try checked(activeMilliseconds,windowEnd-begin)}
        let seconds=Double(activeMilliseconds)/1000
        return TextMetrics(totalCharacters:total,archivedActiveSeconds:seconds,averageCharactersPerActiveMinute:seconds>0 ? Double(total)*60/seconds:nil,peakCharactersPerMinute:peak,peakMinute:peakMinute.map(Double.init),recordedMinutes:recordedMinutes)
    }
    public func storageInfo() throws -> TextStorageInfo {
        let statement=try prepare("SELECT COUNT(*),MIN(time_ms)/1000.0 FROM text_records");defer{sqlite3_finalize(statement)}
        guard try next(statement) else{throw TextArchiveError("无法读取文字存储信息。")}
        return TextStorageInfo(bytes:try pageBytes("main"),records:sqlite3_column_int64(statement,0),oldestTime:sqlite3_column_type(statement,1)==SQLITE_NULL ? nil:sqlite3_column_double(statement,1))
    }
    /// Read allocation and record metadata without opening the encrypted archive,
    /// loading a key, migrating the schema or creating a missing database.
    public static func storageInfo(at url: URL) throws -> TextStorageInfo? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var connection: OpaquePointer?
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let connection else {
            if let connection { sqlite3_close(connection) }
            throw TextArchiveError("无法只读打开文字数据库。")
        }
        defer { sqlite3_close(connection) }
        func prepare(_ sql: String) throws -> OpaquePointer {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                if let statement { sqlite3_finalize(statement) }
                throw TextArchiveError("无法读取文字数据库元数据。")
            }
            return statement
        }
        func integer(_ sql: String) throws -> Int64 {
            let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw TextArchiveError("无法读取文字数据库元数据。") }
            return sqlite3_column_int64(statement, 0)
        }
        guard try integer("PRAGMA user_version") == 1 else { throw TextArchiveError("不支持的文字数据库版本。") }
        let statement = try prepare("SELECT COUNT(*),MIN(time_ms)/1000.0 FROM text_records")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw TextArchiveError("无法读取文字存储信息。") }
        let pageCount = try integer("PRAGMA main.page_count")
        let pageSize = try integer("PRAGMA main.page_size")
        let (bytes, overflow) = pageCount.multipliedReportingOverflow(by: pageSize)
        guard pageCount >= 0, pageSize > 0, !overflow else { throw TextArchiveError("文字数据库容量无效。") }
        return TextStorageInfo(bytes: bytes, records: sqlite3_column_int64(statement, 0), oldestTime: sqlite3_column_type(statement, 1) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 1))
    }
    private func integer(_ sql:String) throws -> Int64 {
        let statement=try prepare(sql);defer{sqlite3_finalize(statement)}
        guard try next(statement) else{throw TextArchiveError("数据库统计查询失败。")};return sqlite3_column_int64(statement,0)
    }
    private func pageBytes(_ schema:String) throws -> Int64 {
        let count = try integer("PRAGMA \(schema).page_count"), size = try integer("PRAGMA \(schema).page_size")
        let (bytes, overflow) = count.multipliedReportingOverflow(by: size)
        guard count >= 0, size > 0, !overflow else { throw TextArchiveError("文字数据库容量无效或溢出。") }
        return bytes
    }
    private func combinedPageBytes() throws -> Int64 {
        let main = try pageBytes("main"), statistics = try pageBytes("stats")
        let (bytes, overflow) = main.addingReportingOverflow(statistics)
        guard !overflow else { throw TextArchiveError("联合数据库容量溢出。") }
        return bytes
    }
    /// Each oldest-minute batch commits both databases and tombstone journals
    /// atomically; VACUUM runs only between transactions. Callers with live Rust
    /// activity windows must flush normally first, then end those windows in
    /// beforeDeleting. That callback runs once only when deletion is necessary,
    /// with no active statements/transaction, so the Rust connection may write.
    public func retentionTogetherWithStatistics(at statsURL:URL,maxBytes:Int64,beforeDeleting:() throws -> Void = {}) throws -> CombinedRetentionResult {
        guard maxBytes>=1_048_576 else{throw TextArchiveError("存储上限至少为 1 MiB。")}
        return try withStatistics(at:statsURL) {
            var bytes = try combinedPageBytes()
            if bytes > maxBytes {
                try execute("VACUUM main;VACUUM stats")
                bytes = try combinedPageBytes()
            }
            var deletedMinutes:Int64=0,deletedText:Int64=0,preparedForDeletion=false
            while bytes>maxBytes {
                var oldMinutes=try integer("SELECT COUNT(*) FROM stats.minutes")
                var oldText=try integer("SELECT COUNT(*) FROM text_records")
                if oldMinutes+oldText==0 {break}
                if !preparedForDeletion {
                    // integer() finalizes each read before returning. No boundary
                    // SELECT or transaction exists yet; ending live windows may
                    // add a minute, so reread counts before choosing the boundary.
                    try beforeDeleting();preparedForDeletion=true
                    oldMinutes=try integer("SELECT COUNT(*) FROM stats.minutes")
                    oldText=try integer("SELECT COUNT(*) FROM text_records")
                    if oldMinutes+oldText==0 {break}
                }
                // Keep bulk throughput, but compact/recheck after each whole minute
                // in the final batch so a small byte excess does not erase its tail.
                let batchLimit:Int32=oldMinutes+oldText<=256 ? 1:256
                let boundary=try prepare("SELECT MAX(time) FROM (SELECT time FROM (SELECT minute AS time FROM stats.minutes UNION ALL SELECT time_ms/1000.0 AS time FROM text_records) ORDER BY time LIMIT ?)")
                sqlite3_bind_int(boundary,1,batchLimit)
                let cutoff:Double
                do {guard try next(boundary),sqlite3_column_type(boundary,0) != SQLITE_NULL else{throw TextArchiveError("无法计算保留边界。")};cutoff=floor(sqlite3_column_double(boundary,0)/60)*60+60;sqlite3_finalize(boundary)}catch{sqlite3_finalize(boundary);throw error}
                try deleteAttached(lower:-1e12,upper:cutoff,all:false)
                let remainingMinutes=try integer("SELECT COUNT(*) FROM stats.minutes")
                let remainingText=try integer("SELECT COUNT(*) FROM text_records")
                deletedMinutes+=oldMinutes-remainingMinutes;deletedText+=oldText-remainingText
                try execute("VACUUM main;VACUUM stats")
                bytes=try combinedPageBytes()
                if oldMinutes==remainingMinutes && oldText==remainingText {break}
            }
            return CombinedRetentionResult(deletedMinutes:deletedMinutes,deletedTextRecords:deletedText,combinedBytes:bytes,limitMet:bytes<=maxBytes)
        }
    }
    public func exportTXT(start: Date, end: Date, keyword: String = "") throws -> String {
        let count=try recordCount(start:start,end:end)
        guard count<=10_000 else { throw TextArchiveError("导出范围超过 10,000 条，请缩小时间范围；未生成不完整导出。") }
        guard keyword.count<=1024 else{throw TextArchiveError("关键词过长。")}
        let formatter=ISO8601DateFormatter();var output="";var scannedBytes=0
        try visitEncrypted(start:start,end:end,limit:10_000) {record in
            scannedBytes+=record.sealedBoxBase64.utf8.count+record.aadBase64.utf8.count
            guard scannedBytes<=64*1024*1024 else{throw TextArchiveError("导出扫描超过 64 MiB，请缩小范围；未生成不完整导出。")}
            let text=try decrypt(record)
            if keyword.isEmpty || text.localizedCaseInsensitiveContains(keyword) {
                let line="[\(formatter.string(from:record.metadata.timestamp))] \(record.metadata.applicationBundleID)\n\(text)"
                guard output.utf8.count+line.utf8.count+2<=8*1024*1024 else{throw TextArchiveError("TXT 导出超过 8 MiB，请缩小范围；未生成不完整导出。")}
                if !output.isEmpty {output+="\n\n"};output+=line
            }
            return true
        }
        return output
    }

    public func exportEncrypted(start: Date, end: Date) throws -> [EncryptedTextRecord] {
        guard try recordCount(start:start,end:end)<=10_000 else { throw TextArchiveError("密文导出超过 10,000 条，请缩小范围。") }
        var records:[EncryptedTextRecord]=[];var bytes=0
        try visitEncrypted(start:start,end:end,limit:10_000) {record in
            bytes+=record.sealedBoxBase64.utf8.count+record.aadBase64.utf8.count+1024
            guard bytes<=8*1024*1024 else{throw TextArchiveError("密文导出超过 8 MiB，请缩小范围。")}
            records.append(record);return true
        }
        return records
    }
    /// Accepts only envelopes authenticated with this archive's explicit key.
    @discardableResult public func importEncrypted(_ records: [EncryptedTextRecord]) throws -> Int {
        guard records.count<=1000 else { throw TextArchiveError("一次最多导入 1,000 条密文。") }
        for record in records { _ = try decrypt(record) }
        var imported=0
        try transaction {
            for record in records {
                let statement=try prepare("SELECT time_ms,app,char_count,ciphertext,aad FROM text_records WHERE id=?");defer{sqlite3_finalize(statement)}
                sqlite3_bind_text(statement,1,record.metadata.id,-1,transient)
                if try next(statement) {
                    let existing=try envelope(statement,id:record.metadata.id)
                    guard existing.metadata==record.metadata,existing.sealedBoxBase64==record.sealedBoxBase64,existing.aadBase64==record.aadBase64 else { throw TextArchiveError("密文 ID 冲突，整批导入已取消。") }
                } else { try insert(record);try journal(id:record.metadata.id,record:record);imported+=1 }
            }
        }
        return imported
    }
    public func syncChanges(after:Int64,limit:Int=100) throws -> TextChangePage {
        guard after>=0,after<=9_007_199_254_740_991,(1...1000).contains(limit) else {throw TextArchiveError("无效文字同步游标或分页。")}
        let statement=try prepare("SELECT revision,id,deleted,record FROM text_sync WHERE revision>? ORDER BY revision LIMIT ?");defer{sqlite3_finalize(statement)}
        sqlite3_bind_int64(statement,1,after);sqlite3_bind_int(statement,2,Int32(limit+1));var changes:[TextChange]=[];var bytes=0;var more=false
        while try next(statement) {
            let rowBytes=Int(sqlite3_column_bytes(statement,3))+1024
            if changes.count==limit || bytes+rowBytes>1024*1024 {more=true;break}
            bytes+=rowBytes
            guard let id=sqlite3_column_text(statement,1) else {throw TextArchiveError("文字同步ID缺失。")}
            let record:EncryptedTextRecord?
            if let data=sqlite3_column_blob(statement,3) {let decoder=JSONDecoder();decoder.dateDecodingStrategy = .secondsSince1970;record=try decoder.decode(EncryptedTextRecord.self,from:Data(bytes:data,count:Int(sqlite3_column_bytes(statement,3))))}else{record=nil}
            changes.append(TextChange(revision:sqlite3_column_int64(statement,0),id:String(cString:id),deleted:sqlite3_column_int(statement,2) != 0,record:record))
        }
        return TextChangePage(changes:changes,cursor:changes.last?.revision ?? after,hasMore:more)
    }
    public func applyEncryptedChanges(_ changes:[TextChange]) throws -> TextApplyResult {
        guard changes.count<=1000 else {throw TextArchiveError("一次最多同步1,000条文字变更。")}
        for change in changes {
            guard (1...9_007_199_254_740_991).contains(change.revision),UUID(uuidString:change.id) != nil else {throw TextArchiveError("无效文字变更。")}
            if change.deleted {guard change.record==nil else{throw TextArchiveError("文字墓碑不能包含内容。")}}
            else {guard let record=change.record,record.metadata.id==change.id else{throw TextArchiveError("文字变更ID不匹配。")};_ = try decrypt(record)}
        }
        var applied=0,ignored=0
        try transaction {
            for change in changes {
                let read=try prepare("SELECT revision FROM text_replica_versions WHERE id=?");defer{sqlite3_finalize(read)};sqlite3_bind_text(read,1,change.id,-1,transient)
                if try next(read),sqlite3_column_int64(read,0)>=change.revision {ignored+=1;continue}
                let deletion=try prepare("DELETE FROM text_records WHERE id=?");defer{sqlite3_finalize(deletion)};sqlite3_bind_text(deletion,1,change.id,-1,transient);try finish(deletion)
                if let record=change.record {try insert(record)}
                try remember(id:change.id,revision:change.revision)
                let advance=try prepare("UPDATE text_sync_state SET revision=MAX(revision,?) WHERE id=1");defer{sqlite3_finalize(advance)};sqlite3_bind_int64(advance,1,change.revision);try finish(advance)
                applied+=1
            }
        }
        return TextApplyResult(applied:applied,ignored:ignored)
    }
    private func remember(id:String,revision:Int64) throws {
        let statement=try prepare("INSERT INTO text_replica_versions VALUES(?,?) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision");defer{sqlite3_finalize(statement)}
        sqlite3_bind_text(statement,1,id,-1,transient);sqlite3_bind_int64(statement,2,revision);try finish(statement)
    }
    private func journal(id:String,record:EncryptedTextRecord?) throws {
        let state=try prepare("SELECT revision FROM text_sync_state WHERE id=1");defer{sqlite3_finalize(state)}
        guard try next(state),sqlite3_column_int64(state,0)<9_007_199_254_740_991 else{throw TextArchiveError("文字同步revision已耗尽。")}
        let revision=sqlite3_column_int64(state,0)+1
        let advance=try prepare("UPDATE text_sync_state SET revision=? WHERE id=1");defer{sqlite3_finalize(advance)};sqlite3_bind_int64(advance,1,revision);try finish(advance)
        let statement=try prepare("INSERT INTO text_sync VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,deleted=excluded.deleted,record=excluded.record");defer{sqlite3_finalize(statement)}
        sqlite3_bind_text(statement,1,id,-1,transient);sqlite3_bind_int64(statement,2,revision);sqlite3_bind_int(statement,3,record==nil ? 1:0)
        if let record {let encoder=JSONEncoder();encoder.dateEncodingStrategy = .secondsSince1970;let data=try encoder.encode(record);_ = data.withUnsafeBytes{sqlite3_bind_blob(statement,4,$0.baseAddress,Int32($0.count),transient)}}else{sqlite3_bind_null(statement,4)}
        try finish(statement);try remember(id:id,revision:revision)
    }

    /// Explicit user export only. Never persist or log this string automatically.
    public func exportKey() -> String { key.withUnsafeBytes { Data($0).base64EncodedString() } }

    private static func milliseconds(_ date: Date) throws -> Int64 {
        let value=date.timeIntervalSince1970
        guard value.isFinite,value>=0,value<1e12 else { throw TextArchiveError("文字记录时间无效。") }
        return Int64((value*1000).rounded())
    }
    private func bounds(_ start: Date,_ end: Date) throws -> (Int64,Int64) {
        let a=try Self.milliseconds(start),b=try Self.milliseconds(end)
        guard b>=a else { throw TextArchiveError("结束时间早于开始时间。") };return(a,b)
    }
    private func validate(_ metadata: TextRecordMetadata) throws {
        _ = try Self.milliseconds(metadata.timestamp)
        guard UUID(uuidString:metadata.id) != nil,(1...16_384).contains(metadata.characterCount),
              !metadata.applicationBundleID.isEmpty,metadata.applicationBundleID.utf8.count<=255,
              metadata.applicationBundleID.utf8.allSatisfy({(65...90).contains($0)||(97...122).contains($0)||(48...57).contains($0)||[45,46,95].contains($0)}) else { throw TextArchiveError("文字记录元数据无效。") }
    }
    private func aad(_ metadata: TextRecordMetadata) throws -> Data {
        try validate(metadata)
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys];encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(metadata)
    }

    private func decrypt(_ record: EncryptedTextRecord) throws -> String {
        guard record.version==1, record.sealedBoxBase64.utf8.count<=400_000,let sealed=Data(base64Encoded:record.sealedBoxBase64) else { throw TextArchiveError("无效的密文格式或版本。") }
        do {
            try validate(record.metadata)
            guard record.aadBase64.utf8.count<=4096,let aad=Data(base64Encoded:record.aadBase64) else {throw TextArchiveError("无效AAD。")}
            guard let fields=try JSONSerialization.jsonObject(with:aad) as? [String:Any],Set(fields.keys)==Set(["id","timestamp","applicationBundleID","characterCount"]) else {throw TextArchiveError("AAD包含未知或缺失字段。")}
            let decoder=JSONDecoder();decoder.dateDecodingStrategy = .secondsSince1970
            guard try decoder.decode(TextRecordMetadata.self,from:aad)==record.metadata else {throw TextArchiveError("AAD与元数据不匹配。")}
            let plain=try AES.GCM.open(AES.GCM.SealedBox(combined:sealed),using:key,authenticating:aad)
            guard plain.count<=262_144 else {throw TextArchiveError("文字长度超过上限。")}
            guard let text=String(data:plain,encoding:.utf8),text.count==record.metadata.characterCount else { throw TextArchiveError("文字字符计数与密文不符。") }
            return text
        } catch { throw TextArchiveError("密文认证失败；密钥、内容或元数据不匹配。") }
    }
    private func insert(_ record: EncryptedTextRecord) throws {
        try validate(record.metadata)
        guard let bytes=Data(base64Encoded:record.sealedBoxBase64) else { throw TextArchiveError("无效密文。") }
        let statement=try prepare("INSERT INTO text_records VALUES(?,?,?,?,?,?)");defer{sqlite3_finalize(statement)}
        sqlite3_bind_text(statement,1,record.metadata.id,-1,transient);sqlite3_bind_int64(statement,2,try Self.milliseconds(record.metadata.timestamp))
        sqlite3_bind_text(statement,3,record.metadata.applicationBundleID,-1,transient);sqlite3_bind_int64(statement,4,Int64(record.metadata.characterCount))
        _ = bytes.withUnsafeBytes { sqlite3_bind_blob(statement,5,$0.baseAddress,Int32($0.count),transient) }
        guard let aad=Data(base64Encoded:record.aadBase64) else {throw TextArchiveError("无效AAD。")}
        _ = aad.withUnsafeBytes {sqlite3_bind_blob(statement,6,$0.baseAddress,Int32($0.count),transient)};try finish(statement)
    }
    private func recordCount(start: Date,end: Date) throws -> Int {
        let (a,b)=try bounds(start,end);let statement=try prepare("SELECT COUNT(*) FROM text_records WHERE time_ms>=? AND time_ms<?");defer{sqlite3_finalize(statement)}
        sqlite3_bind_int64(statement,1,a);sqlite3_bind_int64(statement,2,b);return try next(statement) ? Int(sqlite3_column_int64(statement,0)) : 0
    }
    private func characterCount(start:Date,end:Date) throws -> Int {
        let(a,b)=try bounds(start,end);let statement=try prepare("SELECT COALESCE(SUM(char_count),0) FROM text_records WHERE time_ms>=? AND time_ms<?");defer{sqlite3_finalize(statement)}
        sqlite3_bind_int64(statement,1,a);sqlite3_bind_int64(statement,2,b);return try next(statement) ? Int(sqlite3_column_int64(statement,0)):0
    }
    private func visitEncrypted(start: Date,end: Date,limit: Int,_ visit:(EncryptedTextRecord)throws->Bool) throws {
        let(a,b)=try bounds(start,end);let statement=try prepare("SELECT id,time_ms,app,char_count,ciphertext,aad FROM text_records WHERE time_ms>=? AND time_ms<? ORDER BY time_ms,id LIMIT ?");defer{sqlite3_finalize(statement)}
        sqlite3_bind_int64(statement,1,a);sqlite3_bind_int64(statement,2,b);sqlite3_bind_int(statement,3,Int32(limit))
        while try next(statement) {
            guard let id=sqlite3_column_text(statement,0) else { throw TextArchiveError("记录 ID 缺失。") }
            if try !visit(envelope(statement,id:String(cString:id),offset:1)){break}
        }
    }
    private func envelope(_ statement:OpaquePointer,id:String,offset:Int32=0) throws -> EncryptedTextRecord {
        guard let app=sqlite3_column_text(statement,offset+1),let bytes=sqlite3_column_blob(statement,offset+3),let auth=sqlite3_column_blob(statement,offset+4) else { throw TextArchiveError("文字记录不完整。") }
        let metadata=TextRecordMetadata(id:id,timestamp:Date(timeIntervalSince1970:Double(sqlite3_column_int64(statement,offset))/1000),applicationBundleID:String(cString:app),characterCount:Int(sqlite3_column_int64(statement,offset+2)))
        return EncryptedTextRecord(metadata:metadata,sealedBoxBase64:Data(bytes:bytes,count:Int(sqlite3_column_bytes(statement,offset+3))).base64EncodedString(),aadBase64:Data(bytes:auth,count:Int(sqlite3_column_bytes(statement,offset+4))).base64EncodedString())
    }
    private func prepare(_ sql:String) throws -> OpaquePointer {var statement:OpaquePointer?;guard sqlite3_prepare_v2(db,sql,-1,&statement,nil)==SQLITE_OK,let statement else{throw failure()};return statement}
    private func execute(_ sql:String) throws {guard sqlite3_exec(db,sql,nil,nil,nil)==SQLITE_OK else{throw failure()}}
    private func next(_ statement:OpaquePointer) throws -> Bool {switch sqlite3_step(statement){case SQLITE_ROW:return true;case SQLITE_DONE:return false;default:throw failure()}}
    private func finish(_ statement:OpaquePointer) throws {guard sqlite3_step(statement)==SQLITE_DONE else{throw failure()}}
    private func failure()->TextArchiveError {TextArchiveError(db.map{String(cString:sqlite3_errmsg($0))} ?? "文字库已关闭。")}
    private func transaction(_ work:() throws -> Void) throws {try execute("BEGIN IMMEDIATE");do{try work();try execute("COMMIT")}catch{try? execute("ROLLBACK");throw error}}
    private static func loadKey(service:String,account:String,allowCreate:Bool) throws -> SymmetricKey {
        guard !service.isEmpty,!account.isEmpty else { throw TextArchiveError("Keychain 标识不能为空。") }
        let identity:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account]
        var query=identity;query[kSecReturnData as String]=true;query[kSecMatchLimit as String]=kSecMatchLimitOne;let context=LAContext();context.interactionNotAllowed=true;query[kSecUseAuthenticationContext as String]=context
        var result:CFTypeRef?;let status=SecItemCopyMatching(query as CFDictionary,&result)
        if status==errSecSuccess,let bytes=result as? Data,bytes.count==32{return SymmetricKey(data:bytes)}
        guard status==errSecItemNotFound,allowCreate else {throw TextArchiveError("无法读取现有文字密钥（Keychain \(status)）；未自动替换密钥。")}
        let key=SymmetricKey(size:.bits256);var item=identity
        item[kSecValueData as String]=key.withUnsafeBytes{Data($0)};item[kSecAttrAccessible as String]=kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added=SecItemAdd(item as CFDictionary,nil)
        guard added==errSecSuccess else {throw TextArchiveError("无法创建文字密钥（Keychain \(added)）。")};return key
    }
}
