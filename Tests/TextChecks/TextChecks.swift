import Foundation
import AppKit
import CryptoKit
import CSQLite
import CKeyTrailRust
import KeyTrailIPC
#if canImport(KeyTrailRuntime)
import KeyTrailRuntime
#endif

struct TextCheckFailure: Error {let message:String}
func textCheck(_ condition:@autoclosure () throws ->Bool,_ message:String) throws {if try !condition(){throw TextCheckFailure(message:message)}}
func expectTextError(_ message:String,_ operation:() throws -> Void) throws {do{try operation()}catch{return};throw TextCheckFailure(message:message)}

@main struct TextChecks {
    @MainActor static func main() throws {
        try testSnapshotVersions()
        try testTextMetrics()
        try testSnapshotQueue()
        try testBaselineFreshness()
        try testDiffAndSafety()
        try testNativeCompositionProvider()
        try testSnapshotReadConsistency()
        try testEncryptedArchive()
        try testCipherSync()
        try testBoundedSearchCoverage()
        try testByteBoundedPages()
        try testAtomicDeletion()
        try testRetentionTail()
        try testNoOpRetention()
        try writeSyntheticInteropFixture()
        print("Passed 34 text fixture groups; no real Accessibility/Input Monitoring or production Keychain access")
    }
    static func testNoOpRetention() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("keytrail-noop-retention-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let textURL = directory.appendingPathComponent("text.sqlite"), statsURL = directory.appendingPathComponent("stats.sqlite")
        let archive = try TextArchive(url: textURL, key: SymmetricKey(size: .bits256))
        _ = try archive.append(text: "synthetic no-op capacity check", at: Date(timeIntervalSince1970: 60), applicationBundleID: "fixture")
        var error: UnsafeMutablePointer<CChar>?
        guard let core = keytrail_open(statsURL.path, &error) else {
            if let error { keytrail_string_free(error) }
            throw TextCheckFailure(message: "No-op retention fixture could not open core")
        }
        defer { keytrail_close(core) }
        let textBefore = try Data(contentsOf: textURL), statisticsBefore = try Data(contentsOf: statsURL)
        let result = try archive.retentionTogetherWithStatistics(at: statsURL, maxBytes: 1_048_576)
        let textAfter = try Data(contentsOf: textURL), statisticsAfter = try Data(contentsOf: statsURL)
        try textCheck(result.limitMet && result.deletedMinutes == 0 && result.deletedTextRecords == 0 && textBefore == textAfter && statisticsBefore == statisticsAfter,
                      "Under-limit joint retention compacted or mutated databases")
        print("PASS Under-limit joint archive retention leaves exact database bytes and journals unchanged")
    }
    static func testTextMetrics() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("keytrail-text-metrics-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:directory)}
        let url=directory.appendingPathComponent("text.sqlite"),archive=try TextArchive(url:url,key:SymmetricKey(size:.bits256))
        for(time,count) in [(50.0,999),(60.0,60),(80.0,40),(119.5,20),(120.0,100),(150.0,300)] {_ = try archive.append(text:String(repeating:"x",count:count),at:Date(timeIntervalSince1970:time),applicationBundleID:"fixture.metrics")}
        func metrics(_ a:Double,_ b:Double)throws->TextMetrics {try archive.metrics(start:Date(timeIntervalSince1970:a),end:Date(timeIntervalSince1970:b))}
        let a=try metrics(60,120)
        try textCheck(a.totalCharacters==120 && a.archivedActiveSeconds==50.5 && abs(a.averageCharactersPerActiveMinute!-120*60/50.5)<0.000001 && a.peakCharactersPerMinute==120 && a.peakMinute==60 && a.recordedMinutes==1,"metadata window union/count/peak mismatch")
        let b=try metrics(80,120)
        try textCheck(b.totalCharacters==60 && b.archivedActiveSeconds==30.5,"range-before records inflated archive activity denominator")
        let empty=try metrics(55,60)
        try textCheck(empty.totalCharacters==0 && empty.archivedActiveSeconds==0 && empty.averageCharactersPerActiveMinute==nil && empty.peakMinute==nil && empty.recordedMinutes==0,"outside prior 30s tail affected empty query")
        let partial=try metrics(60,120.5)
        try textCheck(partial.totalCharacters==220 && partial.archivedActiveSeconds==51 && partial.peakCharactersPerMinute==120 && partial.recordedMinutes==2,"fractional end or natural-minute peak miscounted")
        print("PASS archived-character metrics use in-range counts, clipped 30-second union and natural-minute peak")
        let paste=try metrics(60,180)
        try textCheck(paste.totalCharacters==520 && paste.archivedActiveSeconds==110.5 && paste.peakCharactersPerMinute==400 && paste.peakMinute==120,"paste-inclusive archive peak mismatch")
        var db:OpaquePointer?;sqlite3_open(url.path,&db);defer{sqlite3_close(db)}
        try textCheck(sqlite3_exec(db,"UPDATE text_records SET ciphertext=X'00'",nil,nil,nil)==SQLITE_OK,"fixture ciphertext invalidation failed")
        let metadataOnly=try metrics(60,180)
        try textCheck(metadataOnly.totalCharacters==paste.totalCharacters && metadataOnly.archivedActiveSeconds==paste.archivedActiveSeconds,"metrics read/decrypted ciphertext")
        try expectTextError("reversed metrics bounds accepted"){_ = try metrics(180,60)}
        print("PASS metadata-only character metrics remain independent of ciphertext and include paste without typing claims")
    }
    static func testSnapshotVersions() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("keytrail-text-version-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:directory)}
        let key=SymmetricKey(size:.bits256),url=directory.appendingPathComponent("text.sqlite")
        let archive=try TextArchive(url:url,key:key),source=try TextArchive(url:directory.appendingPathComponent("source.sqlite"),key:key)
        for i in 0..<3 {_ = try archive.append(text:"entry \(i)",at:Date(timeIntervalSince1970:Double(i+10)),applicationBundleID:"fixture.version")}
        let start=Date(timeIntervalSince1970:0),end=Date(timeIntervalSince1970:100)
        let page=try archive.searchPage(start:start,end:end,limit:1)
        _ = try archive.append(text:"new",at:Date(timeIntervalSince1970:20),applicationBundleID:"fixture.version")
        try expectTextError("mutated snapshot remained valid"){try archive.validateSnapshot(revision:page.snapshotRevision)}
        try expectTextError("old cursor reused after append"){_ = try archive.searchPage(start:start,end:end,cursor:page.nextCursor)}
        let updated=try archive.searchPage(start:start,end:end,limit:1)
        try textCheck(updated.totalRecords==4,"range total cache survived changed revision")
        try archive.delete(ids:[updated.entries[0].id])
        try expectTextError("old cursor reused after deletion"){_ = try archive.searchPage(start:start,end:end,cursor:updated.nextCursor)}
        let existing=try archive.exportEncrypted(start:start,end:end)[0]
        _ = try archive.applyEncryptedChanges([TextChange(revision:1_000_000,id:existing.metadata.id,deleted:false,record:existing)])
        let high=try archive.searchPage(start:start,end:end,limit:1)
        _ = try source.append(text:"remote lower revision",at:Date(timeIntervalSince1970:30),applicationBundleID:"fixture.version")
        let remote=try source.exportEncrypted(start:start,end:end)[0]
        _ = try archive.applyEncryptedChanges([TextChange(revision:5,id:remote.metadata.id,deleted:false,record:remote)])
        try expectTextError("lower source revision mutation did not invalidate snapshot"){try archive.validateSnapshot(revision:high.snapshotRevision)}
        var db:OpaquePointer?;sqlite3_open(url.path,&db);defer{sqlite3_close(db)}
        try textCheck(sqlite3_exec(db,"CREATE TRIGGER fail_version BEFORE INSERT ON text_sync BEGIN SELECT RAISE(ABORT,'fixture');END",nil,nil,nil)==SQLITE_OK,"version rollback fixture failed")
        let version=try archive.archiveVersion()
        try expectTextError("failed append did not fail"){_ = try archive.append(text:"rollback",at:Date(timeIntervalSince1970:40),applicationBundleID:"fixture.version")}
        try archive.validateSnapshot(revision:version)
        print("PASS append/delete/lower remote revisions invalidate snapshots and SQL rollback preserves revision")
    }
    static func testSnapshotQueue() throws {
        var gate=LatestSnapshotGate<Int>()
        try textCheck(gate.enqueue(0)==0,"first AX job did not start")
        for id in 1...100_000 {try textCheck(gate.enqueue(id)==nil,"burst started concurrent AX work")}
        try textCheck(gate.pending==100_000 && gate.finish()==100_000 && gate.inFlight,"burst did not coalesce to newest intent")
        _ = gate.enqueue(100_001);gate.cancelPending()
        try textCheck(gate.finish()==nil && !gate.inFlight && gate.pending==nil,"pause/reset retained queued AX work")
        try textCheck(gate.enqueue(100_002)==100_002 && gate.finish()==nil,"queue did not recover after cancellation")
        print("PASS 100,000-intent burst coalesces AX work and pause/reset cancels queued reads")
    }
    static func testBaselineFreshness() throws {
        var freshness=TextBaselineFreshness()
        let start=Date(timeIntervalSince1970:100)
        try textCheck(!freshness.canReuse(sameFocus:true,at:start),"missing initial baseline reused")
        // Pointer completion establishes an empty field but does not arm a keyboard sample.
        freshness.observe(at:start)
        var baseline="",selection=NSRange(location:0,length:0)
        var captured=""
        for(index,value) in ["a","ab","abc"].enumerated() {
            let intent=start.addingTimeInterval(Double(index+1)*0.6)
            // AX is deliberately post-edit, including the first key after the pointer.
            let reuse=freshness.canReuse(sameFocus:true,at:intent)
            try textCheck(reuse,"valid pointer/completed-sample baseline discarded")
            if !reuse {baseline=value;selection=NSRange(location:value.utf16.count,length:0)}
            freshness.observe(at:intent)
            captured += CommittedTextDiff.inserted(before:baseline,after:value,oldSelection:selection,newSelection:NSRange(location:value.utf16.count,length:0)) ?? ""
            baseline=value;selection=NSRange(location:value.utf16.count,length:0)
            // Sampling completes: the pending input intent is gone, the baseline remains fresh.
            freshness.observe(at:intent.addingTimeInterval(0.2))
        }
        try textCheck(captured=="abc","post-edit AX snapshots lost separately sampled characters")
        let observed=start.addingTimeInterval(2)
        try textCheck(freshness.canReuse(sameFocus:true,at:observed.addingTimeInterval(2)),"exact freshness boundary rejected")
        try textCheck(!freshness.canReuse(sameFocus:true,at:observed.addingTimeInterval(2.001)),"stale baseline reused")
        try textCheck(!freshness.canReuse(sameFocus:false,at:observed),"other focus reused")
        try textCheck(!freshness.canReuse(sameFocus:true,at:observed.addingTimeInterval(-0.1)),"clock reversal reused baseline")
        // Pause, app/pointer focus change, secure input and unreadable snapshots all call resetBaseline.
        freshness.reset()
        try textCheck(!freshness.canReuse(sameFocus:true,at:observed),"reset baseline reused")
        print("PASS pointer and completed-sample baseline survives delayed post-edit AX; stale/focus/reset fail closed")
    }
    @MainActor static func testDiffAndSafety() throws {
        func inserted(_ a:String,_ b:String,_ old:NSRange,_ new:Int)->String? {CommittedTextDiff.inserted(before:a,after:b,oldSelection:old,newSelection:NSRange(location:new,length:0))}
        try textCheck(inserted("existing document","existing document",NSRange(location:17,length:0),17)==nil,"initial unchanged baseline emitted history")
        try textCheck(inserted("Hello ","Hello 你好",NSRange(location:6,length:0),8)=="你好","Chinese final insertion lost")
        let emoji="👨‍👩‍👧‍👦";try textCheck(inserted("A","A"+emoji,NSRange(location:1,length:0),1+emoji.utf16.count)==emoji,"grapheme/UTF16 mismatch")
        try textCheck(inserted("e","e\u{301}",NSRange(location:1,length:0),2)=="\u{301}","combining insertion lost")
        try textCheck(inserted("aa","aaa",NSRange(location:1,length:0),2)=="a","repeated middle insertion lost")
        print("PASS Unicode Chinese/emoji/combining/repeated insertions")
        try textCheck(inserted("abc","a中c",NSRange(location:1,length:1),2)=="中","selected replacement lost")
        try textCheck(inserted("abc","ac",NSRange(location:1,length:1),1)==nil,"deletion recorded as text")
        try textCheck(inserted("abc","Xabc",NSRange(location:3,length:0),3)==nil,"off-caret background mutation accepted")
        try textCheck(inserted("a","abc",NSRange(location:9,length:0),3)==nil,"invalid selection accepted")
        print("PASS selection-bound edits, deletion and unrelated programmatic mutation filtering")
        try textCheck(!CommittedTextDiff.accepts(role:"AXTextField",subrole:"AXSecureTextField",protectedContent:false,secureInput:false,markedRangeKnown:true),"password subrole accepted")
        try textCheck(!CommittedTextDiff.accepts(role:"AXTextArea",subrole:nil,protectedContent:true,secureInput:false,markedRangeKnown:true),"protected content accepted")
        try textCheck(!CommittedTextDiff.accepts(role:"AXTextField",subrole:nil,protectedContent:false,secureInput:true,markedRangeKnown:true),"secure input accepted")
        try textCheck(!CommittedTextDiff.accepts(role:"AXTextArea",subrole:nil,protectedContent:false,secureInput:false,markedRangeKnown:false),"unknown composition state accepted")
        try textCheck(!CommittedTextDiff.accepts(role:"AXWebArea",subrole:nil,protectedContent:false,secureInput:false,markedRangeKnown:true),"unreadable role accepted")
        let demo=TextCapture(isDemo:true);try textCheck(!demo.enable(requestPermission:true) && !demo.status.enabled && !demo.status.permissionGranted,"demo started capture")
        demo.observeIntent(.keyPress);demo.disable();try textCheck(!demo.enabled,"disabled capture active")
        print("PASS fail-closed secure/unsupported filters and demo enable denial without prompts")
    }
    @MainActor static func testNativeCompositionProvider() throws {
        // A private, undisplayed Cocoa text view; no AX permission or other-app inspection.
        let view=NSTextView(frame:.zero);view.string="Hello ";view.setSelectedRange(NSRange(location:6,length:0))
        let baseline=view.string
        let initial=(view.accessibilityAttributeValue(.textInputMarkedRangeAttribute) as? NSValue)?.rangeValue
        try textCheck(initial?.length==0,"NSTextView did not expose empty marked range")
        view.setMarkedText("ni",selectedRange:NSRange(location:2,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
        let marked=(view.accessibilityAttributeValue(.textInputMarkedRangeAttribute) as? NSValue)?.rangeValue
        try textCheck(marked?.length==2,"NSTextView did not expose active IME preedit")
        let normalized=CommittedTextDiff.baselineRemovingMarkedText(view.string,markedRange:marked!,selection:view.selectedRange())
        try textCheck(normalized?.0==baseline && normalized?.1.location==6,"preedit normalization would retain phonetic input")
        view.insertText("你",replacementRange:NSRange(location:NSNotFound,length:0))
        let final=(view.accessibilityAttributeValue(.textInputMarkedRangeAttribute) as? NSValue)?.rangeValue
        try textCheck(final?.length==0,"NSTextView did not clear marked range on commit")
        let inserted=CommittedTextDiff.inserted(before:normalized!.0,after:view.string,oldSelection:normalized!.1,newSelection:view.selectedRange())
        try textCheck(inserted=="你","final IME value not separated from preedit")
        print("PASS native undisplayed NSTextView marked-range lifecycle and final Chinese insertion")
    }
    @MainActor static func testSnapshotReadConsistency() throws {
        // Undisplayed real NSTextView values; only the timing of provider reads is controlled.
        // The production AX path calls this same coordinator with AX attribute closures.
        func read(_ scenario: String) -> TextSnapshotReadCoordinator.Content? {
            let view=NSTextView(frame:.zero);view.string="Hello ";view.setSelectedRange(NSRange(location:6,length:0))
            if scenario == "ascii" {view.insertText("x",replacementRange:NSRange(location:NSNotFound,length:0))}
            if scenario == "chinese" {view.setMarkedText("ni",selectedRange:NSRange(location:2,length:0),replacementRange:NSRange(location:NSNotFound,length:0));view.insertText("你",replacementRange:NSRange(location:NSNotFound,length:0))}
            if scenario == "active" {view.setMarkedText("ni",selectedRange:NSRange(location:2,length:0),replacementRange:NSRange(location:NSNotFound,length:0))}
            var markerReads=0,valueReads=0,focused=true,secure=false,protected=false
            return TextSnapshotReadCoordinator.read(validateContext:{focused && !secure && !protected},markedRange:{
                markerReads += 1
                let result=(view.accessibilityAttributeValue(.textInputMarkedRangeAttribute) as? NSValue)?.rangeValue
                if markerReads == 1 && (scenario == "begin" || scenario == "beginThenCommit" || scenario == "sameLengthCommit") {
                    let preedit = scenario == "sameLengthCommit" ? "未" : "ni"
                    view.setMarkedText(preedit,selectedRange:NSRange(location:preedit.utf16.count,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
                }
                return result
            },selection:{view.selectedRange()},value:{
                valueReads += 1
                let result=view.string
                if valueReads == 1 {
                    if scenario == "beginThenCommit" || scenario == "sameLengthCommit" {view.insertText("你",replacementRange:NSRange(location:NSNotFound,length:0))}
                    if scenario == "focus" {focused=false}
                    if scenario == "secure" {secure=true}
                    if scenario == "protected" {protected=true}
                }
                return result
            })
        }
        var failures:[String]=[]
        for scenario in ["begin","beginThenCommit","sameLengthCommit"] {
            let result=read(scenario)
            let insertion=result.flatMap {CommittedTextDiff.inserted(before:"Hello ",after:$0.value,oldSelection:NSRange(location:6,length:0),newSelection:$0.selection)}
            print("SNAPSHOT_PROVIDER \(scenario): accepted=\(result != nil), insertion=\(insertion ?? "<none>")")
            if result != nil {failures.append(scenario)}
        }
        try textCheck(failures.isEmpty,"provider accepted inconsistent composition snapshots: \(failures)")
        print("PASS production snapshot coordinator rejects composition start and clear-to-clear candidate replacement during reads")
        for scenario in ["focus","secure","protected"] {try textCheck(read(scenario)==nil,"provider accepted changed \(scenario) context")}
        print("PASS production snapshot coordinator rejects focus, secure-input and protected-role changes")
        for (scenario,expected) in [("ascii","x"),("chinese","你")] {
            guard let result=read(scenario) else {throw TextCheckFailure(message:"stable \(scenario) provider rejected")}
            try textCheck(result.marked.length==0 && CommittedTextDiff.inserted(before:"Hello ",after:result.value,oldSelection:NSRange(location:6,length:0),newSelection:result.selection)==expected,"stable committed value lost")
        }
        guard let active=read("active") else {throw TextCheckFailure(message:"stable active composition should remain available for waiting/baseline")}
        try textCheck(active.marked.length==2 && CommittedTextDiff.baselineRemovingMarkedText(active.value,markedRange:active.marked,selection:active.selection)?.0=="Hello ","active composition waiting/baseline changed")
        var reads=0
        let unsupported=TextSnapshotReadCoordinator.read(validateContext:{true},markedRange:{nil},selection:{NSRange(location:0,length:0)},value:{reads += 1;return "x"})
        try textCheck(unsupported==nil && reads==0,"unknown marked state read document value")
        let oversized=TextSnapshotReadCoordinator.read(validateContext:{true},markedRange:{NSRange(location:0,length:0)},selection:{NSRange(location:0,length:0)},value:{reads += 1;return String(repeating:"x",count:262_145)})
        try textCheck(oversized==nil && reads==1,"oversized first payload repeated or accepted")
        let invalid=TextSnapshotReadCoordinator.read(validateContext:{true},markedRange:{NSRange(location:0,length:0)},selection:{NSRange(location:2,length:0)},value:{"x"})
        try textCheck(invalid==nil,"invalid UTF16 selection accepted")
        print("PASS stable ASCII/Chinese commits and active-composition baseline survive bounded provider reads")
    }
    static func testEncryptedArchive() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("keytrail-text-tests-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:directory)}
        let key=SymmetricKey(data:Data(repeating:17,count:32)),url=directory.appendingPathComponent("text.sqlite")
        var archive:TextArchive?=try TextArchive(url:url,key:key)
        let phrase="机密 fixture 文字 👨‍👩‍👧‍👦 e\u{301} unique-plaintext-marker"
        let first=try archive!.append(text:phrase,at:Date(timeIntervalSince1970:1000.123),applicationBundleID:"fixture.editor")
        _ = try archive!.append(text:"Second SEARCH fixture",at:Date(timeIntervalSince1970:1001),applicationBundleID:"fixture.editor")
        _ = try archive!.append(text:"third fixture",at:Date(timeIntervalSince1970:1002),applicationBundleID:"fixture.editor")
        let start=Date(timeIntervalSince1970:1000),end=Date(timeIntervalSince1970:1003)
        let result=try archive!.search(start:start,end:end,keyword:"fixture",offset:1,limit:1)
        try textCheck(result.entries.count==1 && result.entries[0].text=="Second SEARCH fixture" && result.matchedCount==3 && result.hasMore && result.coverageComplete,"search/pagination mismatch")
        let caseSearch=try archive!.search(start:start,end:end,keyword:"search")
        try textCheck(caseSearch.entries.count==1,"case-insensitive search failed")
        let exact=try archive!.search(start:start,end:Date(timeIntervalSince1970:1001))
        try textCheck(exact.entries.count==1 && exact.entries[0].metadata.characterCount==phrase.count,"half-open or character count mismatch")
        let bytes=try Data(contentsOf:url)
        try textCheck(bytes.range(of:Data(phrase.utf8))==nil && bytes.range(of:Data("unique-plaintext-marker".utf8))==nil,"plaintext persisted on disk")
        try textCheck((try FileManager.default.attributesOfItem(atPath:url.path)[.posixPermissions] as? NSNumber)?.intValue==0o600,"archive permission not 0600")
        print("PASS encrypted disk, Unicode counts, half-open searches, match pagination")
        archive=nil;archive=try TextArchive(url:url,key:key)
        try textCheck(try archive!.search(start:start,end:end).entries[0].text==phrase,"restart decryption failed")
        try expectTextError("wrong key was silently replaced"){_ = try TextArchive(url:url,key:SymmetricKey(size:.bits256))}
        print("PASS restart and wrong-key fail closed")
        let envelopes=try archive!.exportEncrypted(start:start,end:end)
        let export=try archive!.exportTXT(start:start,end:end)
        let filteredExport=try archive!.exportTXT(start:start,end:end,keyword:"search")
        try textCheck(filteredExport.contains("Second SEARCH") && !filteredExport.contains(phrase),"keyword export ignored filter")
        try textCheck(export.contains(phrase) && !envelopes[0].sealedBoxBase64.contains("unique-plaintext-marker"),"explicit export broken")
        let auth=Data(base64Encoded:envelopes[0].aadBase64)!
        let decoder=JSONDecoder();decoder.dateDecodingStrategy = .secondsSince1970
        try textCheck(try decoder.decode(TextRecordMetadata.self,from:auth)==first,"AAD metadata mismatch")
        let combined=Data(base64Encoded:envelopes[0].sealedBoxBase64)!
        let direct=try AES.GCM.open(AES.GCM.SealedBox(combined:combined),using:key,authenticating:auth)
        try textCheck(String(data:direct,encoding:.utf8)==phrase && combined.count==phrase.utf8.count+28,"WebCrypto combined layout/AAD mismatch")
        print("PASS explicit TXT/cipher export and cross-platform raw AAD/nonce/tag contract")
        let second=try TextArchive(url:directory.appendingPathComponent("import.sqlite"),key:key)
        try textCheck(try second.importEncrypted(envelopes)==3,"encrypted import failed")
        try textCheck(try second.importEncrypted(envelopes)==0,"duplicate import not idempotent")
        let changed=TextRecordMetadata(id:first.id,timestamp:first.timestamp,applicationBundleID:"fixture.attacker",characterCount:first.characterCount)
        let tampered=EncryptedTextRecord(metadata:changed,sealedBoxBase64:envelopes[0].sealedBoxBase64,aadBase64:envelopes[0].aadBase64)
        try expectTextError("outer metadata tamper accepted"){_ = try second.importEncrypted([tampered])}
        var modified=combined;modified[modified.count-1]^=1
        let badCipher=EncryptedTextRecord(metadata:first,sealedBoxBase64:modified.base64EncodedString(),aadBase64:envelopes[0].aadBase64)
        try expectTextError("GCM tag tamper accepted"){_ = try second.importEncrypted([badCipher])}
        var unknownFields=try JSONSerialization.jsonObject(with:auth) as! [String:Any];unknownFields["unexpected"]="must not become plaintext metadata"
        let invalidAAD=try JSONSerialization.data(withJSONObject:unknownFields,options:.sortedKeys)
        let invalidCombined=try AES.GCM.seal(Data(phrase.utf8),using:key,authenticating:invalidAAD).combined!
        try expectTextError("unknown authenticated metadata fields accepted"){_ = try second.importEncrypted([EncryptedTextRecord(metadata:first,sealedBoxBase64:invalidCombined.base64EncodedString(),aadBase64:invalidAAD.base64EncodedString())])}
        print("PASS encrypted import idempotency and metadata/ciphertext authentication")
        try archive!.delete(ids:[first.id]);try textCheck(try archive!.search(start:start,end:end).totalRecords==2,"ID deletion failed")
        try archive!.delete(start:Date(timeIntervalSince1970:1001),end:Date(timeIntervalSince1970:1002));try textCheck(try archive!.search(start:start,end:end).totalRecords==1,"range deletion failed")
        try archive!.clear();try textCheck(try archive!.search(start:start,end:end).totalRecords==0,"clear failed")
        print("PASS ID/range/all deletion preserves key and removes records")
        // Inspect schema instead of storing any plaintext search index.
        var db:OpaquePointer?;sqlite3_open_v2(url.path,&db,SQLITE_OPEN_READONLY,nil);defer{sqlite3_close(db)}
        var statement:OpaquePointer?;sqlite3_prepare_v2(db,"PRAGMA table_info(text_records)",-1,&statement,nil);defer{sqlite3_finalize(statement)}
        var fields:[String]=[];while sqlite3_step(statement)==SQLITE_ROW{fields.append(String(cString:sqlite3_column_text(statement,1)))}
        try textCheck(fields==["id","time_ms","app","char_count","ciphertext","aad"],"plaintext index/schema introduced")
        print("PASS independent ciphertext-only text schema")
    }
    static func testCipherSync() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("keytrail-text-sync-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:directory)}
        let key=SymmetricKey(data:Data(repeating:42,count:32))
        let source=try TextArchive(url:directory.appendingPathComponent("source.sqlite"),key:key)
        let targetURL=directory.appendingPathComponent("target.sqlite")
        var target:TextArchive?=try TextArchive(url:targetURL,key:key)
        let first=try source.append(text:"sync first",at:Date(timeIntervalSince1970:10),applicationBundleID:"fixture.editor")
        _ = try source.append(text:"sync second",at:Date(timeIntervalSince1970:11),applicationBundleID:"fixture.editor")
        let page=try source.syncChanges(after:0,limit:1);try textCheck(page.hasMore && page.changes.count==1,"sync pagination missing")
        let initial=try source.syncChanges(after:0,limit:100)
        try textCheck(try target!.applyEncryptedChanges(initial.changes).applied==2,"initial ciphertext apply failed")
        try textCheck(try target!.applyEncryptedChanges(initial.changes).ignored==2,"duplicate cipher replay applied")
        print("PASS ciphertext revision paging and duplicate application")
        try source.delete(ids:[first.id]);let deletion=try source.syncChanges(after:initial.cursor,limit:100)
        try textCheck(deletion.changes.count==1 && deletion.changes[0].deleted && deletion.changes[0].record==nil,"text deletion lacked durable tombstone")
        _ = try target!.applyEncryptedChanges(deletion.changes);target=nil;target=try TextArchive(url:targetURL,key:key)
        try textCheck(try target!.applyEncryptedChanges(initial.changes).ignored==2,"old ciphertext resurrected tombstone after restart")
        try textCheck(try target!.search(start:Date(timeIntervalSince1970:0),end:Date(timeIntervalSince1970:100)).totalRecords==1,"delete replay count mismatch")
        print("PASS encrypted deletion/out-of-order replay across restart")
        let newer=try source.syncChanges(after:0,limit:100)
        try textCheck(newer.changes.count==2 && newer.changes.last!.deleted,"latest-ID coalescing retained old ciphertext")
        let invalid=TextChange(revision:100,id:UUID().uuidString,deleted:false,record:initial.changes[0].record)
        try expectTextError("invalid batch was not rejected"){_ = try target!.applyEncryptedChanges([invalid])}
        let empty=try TextArchive(url:directory.appendingPathComponent("empty.sqlite"),key:key)
        try expectTextError("partial encrypted batch committed"){_ = try empty.applyEncryptedChanges([initial.changes[0],invalid])}
        try textCheck(try empty.search(start:Date(timeIntervalSince1970:0),end:Date(timeIntervalSince1970:100)).totalRecords==0,"invalid batch partially committed")
        print("PASS coalesced ciphertext journal and atomic invalid-batch rejection")
    }
    static func testBoundedSearchCoverage() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("keytrail-text-coverage-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:directory)}
        let key=SymmetricKey(data:Data(repeating:31,count:32))
        let archive=try TextArchive(url:directory.appendingPathComponent("coverage.sqlite"),key:key)
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys];encoder.dateEncodingStrategy = .secondsSince1970
        var batch:[EncryptedTextRecord]=[]
        for index in 0..<10_001 {
            let metadata=TextRecordMetadata(id:String(format:"00000000-0000-4000-8000-%012x",index),timestamp:Date(timeIntervalSince1970:10),applicationBundleID:"fixture.coverage",characterCount:index==10_000 ? 6:1)
            let aad=try encoder.encode(metadata)
            let encrypted=try AES.GCM.seal(Data((index==10_000 ? "needle":"x").utf8),using:key,authenticating:aad).combined!
            batch.append(EncryptedTextRecord(metadata:metadata,sealedBoxBase64:encrypted.base64EncodedString(),aadBase64:aad.base64EncodedString()))
            if batch.count==1000 { _ = try archive.importEncrypted(batch);batch=[] }
        }
        if !batch.isEmpty {_ = try archive.importEncrypted(batch)}
        let start=Date(timeIntervalSince1970:0),end=Date(timeIntervalSince1970:20_000)
        let result=try archive.search(start:start,end:end,keyword:"x",offset:9999,limit:10)
        try textCheck(!result.coverageComplete && result.scannedRecords==10_000 && result.totalRecords==10_001 && result.entries.count==1,"bounded search claimed full coverage")
        try expectTextError("oversized export silently truncated"){_ = try archive.exportTXT(start:start,end:end)}
        print("PASS bounded search explicitly reports incomplete coverage and export refuses truncation")
        var cursor:TextScanCursor?,seen=Set<String>(),scanned=0,pages=0
        let first=try archive.searchPage(start:start,end:end,limit:200)
        repeat {
            let page=try archive.searchPage(start:start,end:end,cursor:cursor,limit:200)
            try textCheck(page.totalRecords==10_001 && page.totalCharacters==10_006 && page.snapshotRevision==first.snapshotRevision,"cursor range totals changed")
            for entry in page.entries {try textCheck(seen.insert(entry.id).inserted,"same-timestamp cursor duplicated record")}
            scanned+=page.scannedRecords;pages+=1
            cursor=page.nextCursor
            if !page.hasMore {try textCheck(page.coverageComplete && cursor==nil,"last cursor page incomplete");break}
            try textCheck(cursor != nil && !page.coverageComplete,"unfinished scan lacked continuation")
        }while true
        try textCheck(scanned==10_001 && seen.count==10_001 && pages>50,"seek scan could not reach beyond first 10000 at one timestamp")
        let revisit=try archive.searchPage(start:start,end:end,limit:200)
        try textCheck(revisit.entries.map(\.id)==first.entries.map(\.id),"previous-page input cursor did not reproduce stable page")
        try expectTextError("cursor reused for a different keyword"){_ = try archive.searchPage(start:start,end:end,keyword:"needle",cursor:first.nextCursor)}
        try expectTextError("cursor reused for a different range"){_ = try archive.searchPage(start:start,end:Date(timeIntervalSince1970:100),cursor:first.nextCursor)}
        print("PASS versioned seek pages reach all 10001 same-timestamp records and bind query scope")
        cursor=nil;scanned=0;var matches:[String]=[];var sawEmpty=false
        repeat {
            let page=try archive.searchPage(start:start,end:end,keyword:"needle",cursor:cursor)
            scanned+=page.scannedRecords;matches+=page.entries.map(\.text)
            if page.entries.isEmpty && page.hasMore {sawEmpty=true}
            cursor=page.nextCursor;if !page.hasMore{break}
        }while true
        try textCheck(sawEmpty && scanned==10_001 && matches==["needle"],"empty match pages blocked later matches beyond first 10000")
        try archive.validateSnapshot(revision:first.snapshotRevision)
        print("PASS empty matching pages still advance and find the final matching record")

    }

    static func testByteBoundedPages() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("keytrail-text-bytes-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:directory)}
        let archive=try TextArchive(url:directory.appendingPathComponent("text.sqlite"),key:SymmetricKey(size:.bits256))
        let value=String(repeating:"😀",count:16_384)
        for i in 0..<140 {_ = try archive.append(text:value,at:Date(timeIntervalSince1970:Double(i)),applicationBundleID:"fixture.editor")}
        let start=Date(timeIntervalSince1970:0),end=Date(timeIntervalSince1970:200)
        let scanPage=try archive.searchPage(start:start,end:end,limit:200)
        let wireEncoder=JSONEncoder();wireEncoder.dateEncodingStrategy = .secondsSince1970
        try textCheck(scanPage.hasMore && scanPage.entries.count<140 && (try wireEncoder.encode(scanPage)).count<=1024*1024,"seek page exceeds 1 MiB encoded output")
        var next=scanPage.nextCursor,seen=scanPage.entries.count
        while let cursor=next {let page=try archive.searchPage(start:start,end:end,cursor:cursor,limit:200);seen+=page.entries.count;next=page.nextCursor}
        try textCheck(seen==140,"byte-bounded seek pages skipped output records")
        print("PASS byte-bounded seek output supports complete multi-page export without a total-size cap")
        let first=try archive.search(start:start,end:end,limit:200)
        try textCheck(first.coverageComplete && first.totalCharacters==140*16_384 && first.entries.count<140 && first.hasMore,"search byte page or total character count failed")
        let second=try archive.search(start:start,end:end,offset:first.entries.count,limit:200)
        try textCheck(first.entries.last!.metadata.id != second.entries.first!.metadata.id,"byte pagination repeated entry")
        let noMatch=try archive.search(start:start,end:end,keyword:"not present")
        try textCheck(noMatch.matchedCount==0 && noMatch.totalCharacters==140*16_384,"keyword changed range character total")
        let page=try archive.syncChanges(after:0,limit:1000)
        let encoder=JSONEncoder();encoder.dateEncodingStrategy = .secondsSince1970
        try textCheck(page.hasMore && page.changes.count<140 && (try encoder.encode(page)).count<2*1024*1024,"ciphertext sync exceeded HTTP body budget")
        var cursor:Int64=0,count=0
        repeat {let next=try archive.syncChanges(after:cursor,limit:1000);count+=next.changes.count;cursor=next.cursor;if !next.hasMore{break}}while true
        try textCheck(count==140,"byte-limited sync skipped records")
        try expectTextError("large TXT truncated or unbounded"){_ = try archive.exportTXT(start:start,end:end)}
        try expectTextError("large encrypted export unbounded"){_ = try archive.exportEncrypted(start:start,end:end)}
        print("PASS byte-bounded search/sync/export and complete metadata character totals")
    }
    static func testAtomicDeletion() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("keytrail-atomic-delete-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:directory)}
        let textURL=directory.appendingPathComponent("text.sqlite"),statsURL=directory.appendingPathComponent("stats.sqlite")
        let archive=try TextArchive(url:textURL,key:SymmetricKey(size:.bits256))
        var error:UnsafeMutablePointer<CChar>?
        guard let core=keytrail_open(statsURL.path,&error) else{throw TextCheckFailure(message:"fixture Rust open failed")}
        defer{keytrail_close(core)}
        func request(_ json:String)throws->[String:Any] {
            guard let ptr=keytrail_request(core,json) else{throw TextCheckFailure(message:"nil core reply")};defer{keytrail_string_free(ptr)}
            let value=try JSONSerialization.jsonObject(with:Data(String(cString:ptr).utf8)) as! [String:Any]
            try textCheck(value["ok"] as? Bool==true,"core fixture request failed: \(value)");return value
        }
        _ = try request(#"{"op":"ingest","samples":[{"timestamp":60,"kind":"keyPress","keyLabel":"A"},{"timestamp":120,"kind":"keyPress","keyLabel":"B"}],"observedThrough":120}"#)
        _ = try request(#"{"op":"end","time":120}"#)
        _ = try archive.append(text:"first",at:Date(timeIntervalSince1970:60),applicationBundleID:"fixture.editor")
        _ = try archive.append(text:"adjacent",at:Date(timeIntervalSince1970:120),applicationBundleID:"fixture.editor")
        func sql(_ url:URL,_ command:String)throws {var db:OpaquePointer?;guard sqlite3_open(url.path,&db)==SQLITE_OK else{throw TextCheckFailure(message:"SQL fixture open")};defer{sqlite3_close(db)};try textCheck(sqlite3_exec(db,command,nil,nil,nil)==SQLITE_OK,"SQL fixture command")}
        func scalar(_ url:URL,_ query:String)throws->Int64 {var db:OpaquePointer?;sqlite3_open(url.path,&db);defer{sqlite3_close(db)};var statement:OpaquePointer?;try textCheck(sqlite3_prepare_v2(db,query,-1,&statement,nil)==SQLITE_OK,"fixture scalar prepare");defer{sqlite3_finalize(statement)};try textCheck(sqlite3_step(statement)==SQLITE_ROW,"fixture scalar row");return sqlite3_column_int64(statement,0)}
        let before=try archive.syncChanges(after:0),statsRevision=try scalar(statsURL,"SELECT revision FROM sync_state")
        let start=Date(timeIntervalSince1970:60),end=Date(timeIntervalSince1970:120)
        try sql(statsURL,"CREATE TRIGGER fail_delete BEFORE DELETE ON minutes BEGIN SELECT RAISE(ABORT,'fixture');END")
        try expectTextError("stats failure partially committed"){try archive.deleteTogetherWithStatistics(at:statsURL,start:start,end:end)}
        try textCheck(try scalar(statsURL,"SELECT COUNT(*) FROM minutes")==2 && scalar(statsURL,"SELECT revision FROM sync_state")==statsRevision && archive.syncChanges(after:0).cursor==before.cursor && archive.search(start:start,end:Date(timeIntervalSince1970:180)).totalRecords==2,"stats failure changed data/journals")
        try sql(statsURL,"DROP TRIGGER fail_delete")
        try sql(textURL,"CREATE TRIGGER fail_delete BEFORE DELETE ON text_records BEGIN SELECT RAISE(ABORT,'fixture');END")
        try expectTextError("text failure partially committed"){try archive.deleteTogetherWithStatistics(at:statsURL,start:start,end:end)}
        try textCheck(try scalar(statsURL,"SELECT COUNT(*) FROM minutes")==2 && scalar(statsURL,"SELECT revision FROM sync_state")==statsRevision && archive.syncChanges(after:0).cursor==before.cursor,"text failure changed journals")
        try sql(textURL,"DROP TRIGGER fail_delete")
        print("PASS either-database failure rolls back aggregate/text data and both sync journals")
        try archive.deleteTogetherWithStatistics(at:statsURL,start:start,end:end)
        try textCheck(try scalar(statsURL,"SELECT COUNT(*) FROM minutes")==1 && scalar(statsURL,"SELECT COUNT(*) FROM key_histograms")==1 && scalar(statsURL,"SELECT COUNT(*) FROM rhythm_minutes")==1,"attached foreign-key cascade or half-open range failed")
        try textCheck(try archive.search(start:start,end:Date(timeIntervalSince1970:180)).entries.first?.text=="adjacent" && archive.syncChanges(after:before.cursor).changes.first?.deleted==true,"text adjacent boundary/tombstone failed")
        let sync=try request(#"{"op":"syncChanges","after":0,"limit":100}"#)["result"] as! [String:Any]
        let changes=sync["changes"] as! [[String:Any]]
        try textCheck(changes.contains{($0["minute"] as? Int)==60 && ($0["deleted"] as? Bool)==true},"Rust reader missed attached transaction tombstone")
        print("PASS atomic half-open deletion preserves adjacent records and creates Rust-readable tombstones")
        try archive.clearTogetherWithStatistics(at:statsURL)
        try textCheck(try scalar(statsURL,"SELECT COUNT(*) FROM minutes")==0 && scalar(statsURL,"SELECT COUNT(*) FROM sync_journal WHERE deleted=1")==2 && archive.search(start:start,end:Date(timeIntervalSince1970:180)).totalRecords==0,"atomic clear incomplete")
        print("PASS unified clear leaves durable aggregate and text tombstones")
        let samples=(0..<300).map{["timestamp":Double(600+$0*60),"kind":"keyPress","keyLabel":"A"] as [String:Any]}
        let input=try JSONSerialization.data(withJSONObject:["op":"ingest","samples":samples,"observedThrough":18_600])
        _ = try request(String(data:input,encoding:.utf8)!);_ = try request(#"{"op":"end","time":18600}"#)
        for i in 0..<300 {_ = try archive.append(text:String(repeating:"x",count:16_384),at:Date(timeIntervalSince1970:Double(600+i*60)),applicationBundleID:"fixture.retention")}
        let info=try archive.storageInfo(),retentionCursor=try archive.syncChanges(after:0,limit:1000).cursor
        let diskBytes=(try FileManager.default.attributesOfItem(atPath:textURL.path)[.size] as! NSNumber).int64Value
        try textCheck(info.bytes==diskBytes && info.records==300 && info.oldestTime==600,"text storageInfo bytes/oldest mismatch")
        try sql(statsURL,"CREATE TRIGGER fail_retention BEFORE DELETE ON minutes BEGIN SELECT RAISE(ABORT,'fixture');END")
        try expectTextError("retention SQL failure partially committed"){_ = try archive.retentionTogetherWithStatistics(at:statsURL,maxBytes:2*1024*1024)}
        try textCheck(try archive.storageInfo().records==300 && scalar(statsURL,"SELECT COUNT(*) FROM minutes")==300 && archive.syncChanges(after:0,limit:1000).cursor==retentionCursor,"failed retention changed records or text revisions")
        try sql(statsURL,"DROP TRIGGER fail_retention")
        print("PASS combined retention failure preserves both databases and metadata byte totals")
        let retained=try archive.retentionTogetherWithStatistics(at:statsURL,maxBytes:2*1024*1024)
        let remaining=try archive.storageInfo()
        let combinedDisk=(try FileManager.default.attributesOfItem(atPath:textURL.path)[.size] as! NSNumber).int64Value+(try FileManager.default.attributesOfItem(atPath:statsURL.path)[.size] as! NSNumber).int64Value
        try textCheck(retained.limitMet && retained.combinedBytes==combinedDisk && retained.combinedBytes<=2*1024*1024 && retained.deletedMinutes>0 && retained.deletedTextRecords>0 && remaining.records>0 && remaining.records<300 && remaining.oldestTime!>600,"retention failed oldest-first combined cap")
        try textCheck(try archive.search(start:Date(timeIntervalSince1970:18_540),end:Date(timeIntervalSince1970:18_600)).totalRecords==1 && scalar(statsURL,"SELECT COUNT(*) FROM key_histograms")==remaining.records && scalar(statsURL,"SELECT COUNT(*) FROM sync_journal WHERE deleted=1")>=retained.deletedMinutes,"retention lost new data/cascade/tombstone")
        print("PASS combined retention removes oldest minutes, preserves newest and retains sync tombstones")
        // Legitimate unacknowledged tombstone metadata alone may exceed the cap.
        try sql(textURL,"WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<20000) INSERT INTO text_sync(id,revision,deleted,record) SELECT printf('00000000-0000-4000-8000-%012x',x),100000+x,1,NULL FROM n")
        let floor=try archive.retentionTogetherWithStatistics(at:statsURL,maxBytes:1_048_576)
        try textCheck(!floor.limitMet && floor.combinedBytes>1_048_576 && (try scalar(textURL,"SELECT COUNT(*) FROM text_sync WHERE deleted=1"))>=20000,"retention erased unacknowledged metadata or claimed false cap")
        var interrupted = false
        let metadataOnly = try archive.retentionTogetherWithStatistics(at: statsURL, maxBytes: 1_048_576, beforeDeleting: { interrupted = true })
        try textCheck(!metadataOnly.limitMet && metadataOnly.deletedMinutes == 0 && metadataOnly.deletedTextRecords == 0 && !interrupted,
                      "Unattainable metadata-only cap interrupted collection although no record could be deleted")
        print("PASS retained tombstone metadata honestly reports an unattainable byte cap")

    }

    static func testRetentionTail() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("keytrail-retention-tail-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:directory)}
        let textURL=directory.appendingPathComponent("text.sqlite"),statsURL=directory.appendingPathComponent("stats.sqlite")
        let key=SymmetricKey(size:.bits256),archive=try TextArchive(url:textURL,key:key)
        var error:UnsafeMutablePointer<CChar>?
        guard let core=keytrail_open(statsURL.path,&error) else{throw TextCheckFailure(message:"tail fixture Rust open failed")}
        defer{keytrail_close(core)}
        func request(_ object:[String:Any])throws {
            let input=String(data:try JSONSerialization.data(withJSONObject:object),encoding:.utf8)!
            guard let reply=keytrail_request(core,input) else{throw TextCheckFailure(message:"tail fixture nil reply")};defer{keytrail_string_free(reply)}
            let envelope=try JSONSerialization.jsonObject(with:Data(String(cString:reply).utf8)) as! [String:Any]
            try textCheck(envelope["ok"] as? Bool==true,"tail fixture core failed")
        }
        func sql(_ url:URL,_ command:String)throws {var db:OpaquePointer?;guard sqlite3_open(url.path,&db)==SQLITE_OK else{throw TextCheckFailure(message:"tail SQL open")};defer{sqlite3_close(db)};try textCheck(sqlite3_exec(db,command,nil,nil,nil)==SQLITE_OK,"tail SQL command")}
        func scalar(_ url:URL,_ query:String)throws->Int64 {var db:OpaquePointer?;sqlite3_open(url.path,&db);defer{sqlite3_close(db)};var statement:OpaquePointer?;try textCheck(sqlite3_prepare_v2(db,query,-1,&statement,nil)==SQLITE_OK,"tail scalar prepare");defer{sqlite3_finalize(statement)};try textCheck(sqlite3_step(statement)==SQLITE_ROW,"tail scalar row");return sqlite3_column_int64(statement,0)}
        func size(_ url:URL)throws->Int64 {(try FileManager.default.attributesOfItem(atPath:url.path)[.size] as! NSNumber).int64Value}
        let samples=(0..<44).map{["timestamp":Double(600+$0*60),"kind":"keyPress","keyLabel":"A"] as [String:Any]}
        try request(["op":"ingest","samples":samples,"observedThrough":3240]);try request(["op":"end","time":3240])
        for i in 0..<44 {_ = try archive.append(text:String(repeating:"y",count:16_384),at:Date(timeIntervalSince1970:Double(600+i*60)),applicationBundleID:"fixture.tail")}
        try sql(textURL,"VACUUM");try sql(statsURL,"VACUUM")
        let beforeBytes=try size(textURL)+size(statsURL)
        let oracleText=directory.appendingPathComponent("oracle-text.sqlite"),oracleStats=directory.appendingPathComponent("oracle-stats.sqlite")
        try FileManager.default.copyItem(at:textURL,to:oracleText);try FileManager.default.copyItem(at:statsURL,to:oracleStats)
        let oracle=try TextArchive(url:oracleText,key:key)
        try oracle.deleteTogetherWithStatistics(at:oracleStats,start:Date(timeIntervalSince1970:600),end:Date(timeIntervalSince1970:660))
        try sql(oracleText,"VACUUM");try sql(oracleStats,"VACUUM")
        let cap=try size(oracleText)+size(oracleStats)
        try textCheck(cap>=1_048_576 && cap<beforeBytes && (try oracle.storageInfo().records)==43,"tail oracle must show one oldest minute suffices")
        let revision=try archive.archiveVersion(),sync=try scalar(statsURL,"SELECT revision FROM sync_state")
        try sql(statsURL,"CREATE TRIGGER fail_tail BEFORE DELETE ON minutes BEGIN SELECT RAISE(ABORT,'fixture');END")
        try expectTextError("tail failure partially committed"){_ = try archive.retentionTogetherWithStatistics(at:statsURL,maxBytes:cap)}
        try textCheck(try archive.storageInfo().records==44 && scalar(statsURL,"SELECT COUNT(*) FROM minutes")==44 && archive.archiveVersion()==revision && scalar(statsURL,"SELECT revision FROM sync_state")==sync,"tail failure lost rows or versions")
        try sql(statsURL,"DROP TRIGGER fail_tail")
        let result=try archive.retentionTogetherWithStatistics(at:statsURL,maxBytes:cap)
        try textCheck(result.limitMet && result.combinedBytes<=cap && result.deletedMinutes==1 && result.deletedTextRecords==1 && (try archive.storageInfo().records)==43,"tail cleanup erased a fitting newer suffix")
        try textCheck(try scalar(statsURL,"SELECT COUNT(*) FROM key_histograms")==43 && scalar(statsURL,"SELECT COUNT(*) FROM sync_journal WHERE deleted=1")==1 && scalar(textURL,"SELECT COUNT(*) FROM text_sync WHERE deleted=1")==1,"tail cascade or durable tombstone mismatch")
        print("PASS combined retention tail oracle preserves 43 newer records after one-minute deletion; rollback keeps versions; before=\(beforeBytes), cap=\(cap)")
    }

    static func writeSyntheticInteropFixture() throws {
        // TEST ONLY: intentionally exported synthetic key, never the production Keychain key.
        let key=SymmetricKey(data:Data((0..<32).map{UInt8($0)}))
        let plaintext="TEST ONLY 中文输入 👨‍👩‍👧‍👦 café e\u{301}"
        let metadata=TextRecordMetadata(id:"f04ae6b0-9d42-4b4e-9000-000000000001",timestamp:Date(timeIntervalSince1970:1_700_000_000.125),applicationBundleID:"fixture.synthetic.editor",characterCount:plaintext.count)
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys];encoder.dateEncodingStrategy = .secondsSince1970
        let aad=try encoder.encode(metadata),combined=try AES.GCM.seal(Data(plaintext.utf8),using:key,authenticating:aad).combined!
        let record=EncryptedTextRecord(metadata:metadata,sealedBoxBase64:combined.base64EncodedString(),aadBase64:aad.base64EncodedString())
        let directory=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("artifacts/text-interop")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try encoder.encode(record).write(to:directory.appendingPathComponent("swift-record.json"),options:.atomic)
        try Data(plaintext.utf8).write(to:directory.appendingPathComponent("expected-TEST-ONLY.txt"),options:.atomic)
        let keyURL=directory.appendingPathComponent("TEST-ONLY-key.base64")
        try key.withUnsafeBytes{Data(Data($0).base64EncodedString().utf8)}.write(to:keyURL,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:keyURL.path)
        try Data("TEST ONLY synthetic fixture. Never use this public synthetic key for real records. swift-record.json is AES-256-GCM combined nonce(12)+ciphertext+tag(16); use exact aadBase64 bytes. Expected UTF-8 is in expected-TEST-ONLY.txt.\n".utf8).write(to:directory.appendingPathComponent("README.txt"),options:.atomic)
    }

}
