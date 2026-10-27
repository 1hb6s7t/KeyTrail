import AppKit
import ApplicationServices
import Carbon
import Foundation

public enum TextInputIntent: Sendable { case keyPress, pointer }
public struct CapturedText: Sendable {
    public let text: String
    public let timestamp: Date
    public let applicationBundleID: String
}
public struct TextCaptureStatus: Codable, Sendable {
    public let enabled: Bool
    public let permissionGranted: Bool
    public let state: String
    public let message: String
}

/// Pure, Unicode-aware insertion extraction; replacement deletions are never archived.
public enum CommittedTextDiff {
    public static func inserted(before: String, after: String, oldSelection: NSRange, newSelection: NSRange, maximumCharacters: Int = 16_384) -> String? {
        guard before.utf8.count <= 262_144, after.utf8.count <= 262_144,
              oldSelection.location != NSNotFound, newSelection.location != NSNotFound,
              oldSelection.location >= 0, oldSelection.length >= 0, newSelection.length == 0,
              oldSelection.location <= before.utf16.count,
              oldSelection.length <= before.utf16.count - oldSelection.location else { return nil }
        let old = Array(before.utf16), new = Array(after.utf16)
        let start = oldSelection.location, oldEnd = start + oldSelection.length
        let suffixCount = old.count - oldEnd
        guard new.count >= start + suffixCount else { return nil }
        let newEnd = new.count - suffixCount
        func boundary(_ index: Int, _ units: [UInt16]) -> Bool {
            !(index > 0 && index < units.count && (0xD800...0xDBFF).contains(units[index-1]) && (0xDC00...0xDFFF).contains(units[index]))
        }
        guard boundary(start,old),boundary(oldEnd,old),boundary(start,new),boundary(newEnd,new),
              Array(old[..<start]) == Array(new[..<start]),
              Array(old[oldEnd...]) == Array(new[newEnd...]),
              newSelection.location == newEnd else { return nil }
        let insertion = String(decoding:new[start..<newEnd],as:UTF16.self)
        guard !insertion.isEmpty,insertion.count<=maximumCharacters else { return nil }
        return insertion
    }
    public static func baselineRemovingMarkedText(_ value:String, markedRange:NSRange, selection:NSRange) -> (String,NSRange)? {
        if markedRange.length == 0 || markedRange.location == NSNotFound {return (value,selection)}
        let units=Array(value.utf16)
        guard markedRange.location>=0,markedRange.length>0,markedRange.location<=units.count,
              markedRange.length<=units.count-markedRange.location else{return nil}
        let start=markedRange.location,end=start+markedRange.length
        guard !(start>0 && (0xD800...0xDBFF).contains(units[start-1]) && (0xDC00...0xDFFF).contains(units[start])),
              !(end<units.count && (0xD800...0xDBFF).contains(units[end-1]) && (0xDC00...0xDFFF).contains(units[end])) else{return nil}
        return (String(decoding:Array(units[..<start])+Array(units[end...]),as:UTF16.self),NSRange(location:start,length:0))
    }
    public static func accepts(role: String, subrole: String?, protectedContent: Bool, secureInput: Bool, markedRangeKnown: Bool) -> Bool {
        guard !secureInput, !protectedContent, markedRangeKnown,
              role == "AXTextField" || role == "AXTextArea" else { return false }
        let detail = subrole?.lowercased() ?? ""
        return !detail.contains("secure") && !detail.contains("password") && !detail.contains("protected")
    }
}

/// Coordinates provider reads; shared by real AX access and isolated provider fixtures.
public enum TextSnapshotReadCoordinator {
    public struct Content {
        public let value: String
        public let selection: NSRange
        public let marked: NSRange
    }
    public static func read(validateContext: () -> Bool, markedRange: () -> NSRange?, selection: () -> NSRange?, value: () -> String?) -> Content? {
        // AX attributes are separate IPC reads, not an atomic document snapshot. Bound
        // the work to two payload reads and reject observed instability; do not retry
        // here or claim this excludes a provider changing away and back between reads.
        guard validateContext(),
              let firstMarked = markedRange(), let firstSelection = selection(), let firstValue = value(),
              firstValue.utf8.count <= 262_144,
              let secondMarked = markedRange(), firstMarked == secondMarked,
              let secondSelection = selection(), firstSelection == secondSelection,
              let secondValue = value(), firstValue == secondValue,
              secondValue.utf8.count <= 262_144,
              let finalMarked = markedRange(), firstMarked == finalMarked,
              validateContext() else {return nil}
        let count = firstValue.utf16.count
        func valid(_ range:NSRange) -> Bool {
            range.location != NSNotFound && range.location >= 0 && range.length >= 0 &&
                range.location <= count && range.length <= count - range.location
        }
        guard valid(firstSelection),
              (firstMarked.location == NSNotFound && firstMarked.length == 0) || valid(firstMarked) else {return nil}
        let marked = firstMarked.location == NSNotFound ? NSRange(location:0,length:0) : firstMarked
        return Content(value:firstValue,selection:firstSelection,marked:marked)
    }
}

/// Baseline age is independent of a pending keyboard sample. A pointer or completed
/// sample establishes a usable baseline without arming capture by itself.
public struct TextBaselineFreshness {
    private var observedAt: Date?
    public init() {}
    public mutating func observe(at time: Date) { observedAt = time }
    public mutating func reset() { observedAt = nil }
    public func canReuse(sameFocus: Bool, at time: Date) -> Bool {
        guard sameFocus, let observedAt else { return false }
        let age = time.timeIntervalSince(observedAt)
        return age >= 0 && age <= 2
    }
}

/// A burst may retain only an in-flight request and the latest pending request.
public struct LatestSnapshotGate<Request> {
    public init() {}
    public private(set) var inFlight=false
    public private(set) var pending:Request?
    public mutating func enqueue(_ request:Request)->Request? {
        if inFlight {pending=request;return nil};inFlight=true;return request
    }
    public mutating func finish()->Request? {
        if let next=pending {pending=nil;return next};inFlight=false;return nil
    }
    public mutating func cancelPending(){pending=nil}
}

/// Explicitly enabled AX observer. It never creates an input hook or reads clipboard APIs.
/// Unavailable composition state is rejected rather than mistaking IME preedit for committed text.
@MainActor public final class TextCapture {
    public var onText: ((CapturedText) -> Void)?
    public private(set) var enabled = false
    private let isDemo: Bool
    private var baseline: Snapshot?
    private var baselineFreshness = TextBaselineFreshness()
    private var pending: DispatchWorkItem?
    private var lastIntent: Date?
    private var observer: NSObjectProtocol?
    private var generation: UInt64 = 0
    private let accessibilityQueue=DispatchQueue(label:"com.auriel.keytrail.text-accessibility",qos:.utility)
    private var snapshotGate=LatestSnapshotGate<SnapshotRequest>()
    private struct SnapshotRequest {
        let pid:pid_t
        let bundle:String
        let generation:UInt64
        let completion:(Snapshot?)->Void
    }
    private var state = "disabled"
    private var message = "文字记录已关闭，已有记录仍保留。"
    private struct Snapshot: @unchecked Sendable {
        let element: AXUIElement
        let pid: pid_t
        let bundle: String
        let value: String
        let selection: NSRange
        let marked: NSRange
        func sameFocus(_ other: Snapshot) -> Bool { pid == other.pid && CFEqual(element, other.element) }
    }
    public init(isDemo: Bool = false) { self.isDemo = isDemo }
    public var status: TextCaptureStatus {
        TextCaptureStatus(enabled: enabled, permissionGranted: isDemo ? false : AXIsProcessTrusted(), state: state, message: message)
    }
    @discardableResult public func enable(requestPermission: Bool = false) -> Bool {
        guard !isDemo else { state = "demo"; message = "演示模式不读取真实文字。"; return false }
        if requestPermission { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) }
        guard AXIsProcessTrusted() else { state = "permissionNeeded"; message = "需用户显式授予辅助功能权限后才能记录受支持控件的已提交文字。"; return false }
        enabled = true; resetBaseline(); state = "ready"; message = "已启用；仅在输入意图后读取受支持的非安全文本控件。"
        if observer == nil {
            observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.resetBaseline() }
            }
        }
        return true
    }
    public func disable() {
        enabled = false; resetBaseline()
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }; observer = nil
        state = "disabled"; message = "文字记录已关闭，已有记录仍保留。"
    }
    public func resetBaseline() {
        generation &+= 1; pending?.cancel(); pending = nil; baseline = nil; baselineFreshness.reset(); lastIntent = nil; snapshotGate.cancelPending()
    }
    public func observeIntent(_ kind: TextInputIntent, at time: Date = Date()) {
        guard enabled, !isDemo else { return }
        if kind == .pointer {resetBaseline()}
        requestSnapshot { [weak self] current in
            guard let self,self.enabled,Date().timeIntervalSince(time)>=(-0.5),Date().timeIntervalSince(time)<=2 else{return}
            guard let current else{self.resetBaseline();return}
            if kind == .pointer {self.baseline=current;self.baselineFreshness.observe(at:time);return}
            // Preserve pre-edit state during a burst, but never across focus or stale intent.
            if !self.baselineFreshness.canReuse(sameFocus:self.baseline?.sameFocus(current) ?? false,at:time) {
                guard let(value,selection)=CommittedTextDiff.baselineRemovingMarkedText(current.value,markedRange:current.marked,selection:current.selection) else{self.resetBaseline();return}
                self.baseline=Snapshot(element:current.element,pid:current.pid,bundle:current.bundle,value:value,selection:selection,marked:current.marked)
            }
            self.baselineFreshness.observe(at:time)
            self.lastIntent=time;self.schedule(after:0.20)
        }
    }
    private func schedule(after seconds: Double) {
        pending?.cancel(); let token = generation
        let task = DispatchWorkItem { [weak self] in
            Task { @MainActor in guard let self, self.generation == token else { return }; self.sampleAfterIntent() }
        }
        pending = task; DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: task)
    }
    private func sampleAfterIntent() {
        guard enabled,!isDemo,let intent=lastIntent,Date().timeIntervalSince(intent)<=2 else{resetBaseline();return}
        requestSnapshot { [weak self] current in
            guard let self,self.enabled,let latest=self.lastIntent,Date().timeIntervalSince(latest)<=2 else{return}
            guard let current,let previous=self.baseline,previous.sameFocus(current) else{self.resetBaseline();return}
            if current.marked.length>0 {self.schedule(after:0.10);return}
            guard !IsSecureEventInputEnabled() else{self.resetBaseline();return}
            if let insertion=CommittedTextDiff.inserted(before:previous.value,after:current.value,oldSelection:previous.selection,newSelection:current.selection) {
                self.onText?(CapturedText(text:insertion,timestamp:Date(),applicationBundleID:current.bundle))
                self.state="recording";self.message="已记录受支持控件的提交文字；不支持或安全控件会跳过。"
            }
            self.baseline=current;self.baselineFreshness.observe(at:Date());self.lastIntent=nil;self.pending=nil
        }
    }
    // One in-flight AX request plus one latest queued request bounds work during key bursts.
    // Cross-process AX IPC never runs inside the event-tap callback or on the main run loop.
    private func requestSnapshot(_ completion:@escaping (Snapshot?)->Void) {
        guard let app=NSWorkspace.shared.frontmostApplication,let bundle=app.bundleIdentifier else{unavailable("前台应用身份不可读。");completion(nil);return}
        let request=SnapshotRequest(pid:app.processIdentifier,bundle:bundle,generation:generation,completion:completion)
        if let next=snapshotGate.enqueue(request){startSnapshot(next)}
    }
    private func startSnapshot(_ request:SnapshotRequest) {
        accessibilityQueue.async { [weak self] in
            let result=Self.readSnapshot(pid:request.pid,bundle:request.bundle)
            DispatchQueue.main.async { [weak self] in
                guard let self else{return}
                if self.enabled,self.generation==request.generation,NSWorkspace.shared.frontmostApplication?.processIdentifier==request.pid {
                    if let reason=result.1 {self.unavailable(reason)}
                    request.completion(result.0)
                }
                if let next=self.snapshotGate.finish() {if self.enabled,next.generation==self.generation {self.startSnapshot(next)} else{_ = self.snapshotGate.finish()}}
            }
        }
    }
    private nonisolated static func readSnapshot(pid:pid_t,bundle:String)->(Snapshot?,String?) {
        guard AXIsProcessTrusted(),!IsSecureEventInputEnabled() else{return(nil,"安全输入或辅助功能不可用，文字读取已暂停。")}
        let application=AXUIElementCreateApplication(pid);AXUIElementSetMessagingTimeout(application,0.15)
        guard let focused=attribute(application,kAXFocusedUIElementAttribute),CFGetTypeID(focused)==AXUIElementGetTypeID() else{return(nil,"当前控件不可访问。")}
        let element=unsafeBitCast(focused,to:AXUIElement.self);AXUIElementSetMessagingTimeout(element,0.15)
        guard let role=attribute(element,kAXRoleAttribute) as? String else{return(nil,"当前控件角色未知。")}
        let subrole=attribute(element,kAXSubroleAttribute) as? String
        let protected=(attribute(element,NSAccessibility.Attribute.containsProtectedContent.rawValue) as? NSNumber)?.boolValue ?? false
        guard CommittedTextDiff.accepts(role:role,subrole:subrole,protectedContent:protected,secureInput:IsSecureEventInputEnabled(),markedRangeKnown:true) else{return(nil,"安全或不支持的控件不会记录。")}
        let content = TextSnapshotReadCoordinator.read(validateContext: {
            guard AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
                  let focus = attribute(application,kAXFocusedUIElementAttribute), CFGetTypeID(focus) == AXUIElementGetTypeID(),
                  CFEqual(focus,element), let currentRole = attribute(element,kAXRoleAttribute) as? String else {return false}
            let currentSubrole = attribute(element,kAXSubroleAttribute) as? String
            let currentProtected = (attribute(element,NSAccessibility.Attribute.containsProtectedContent.rawValue) as? NSNumber)?.boolValue ?? false
            return currentRole == role && currentSubrole == subrole && currentProtected == protected &&
                CommittedTextDiff.accepts(role:currentRole,subrole:currentSubrole,protectedContent:currentProtected,secureInput:IsSecureEventInputEnabled(),markedRangeKnown:true)
        }, markedRange: {range(attribute(element,NSAccessibility.Attribute.textInputMarkedRangeAttribute.rawValue))},
           selection: {range(attribute(element,kAXSelectedTextRangeAttribute))},
           value: {attribute(element,kAXValueAttribute) as? String})
        guard let content else{return(nil,"控件状态在读取期间变化或不可验证，已跳过本轮文字（覆盖不足）。")}
        return(Snapshot(element:element,pid:pid,bundle:bundle,value:content.value,selection:content.selection,marked:content.marked),nil)
    }
    private func unavailable(_ reason: String) { state = "unsupported"; message = reason }
    private nonisolated static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?; guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }; return result
    }
    private nonisolated static func range(_ value: CFTypeRef?) -> NSRange? {
        guard let value else { return nil }
        if CFGetTypeID(value) == AXValueGetTypeID() {
            let ax = unsafeBitCast(value, to: AXValue.self); var result = CFRange()
            guard AXValueGetType(ax) == .cfRange, AXValueGetValue(ax, .cfRange, &result) else { return nil }
            if result.location == kCFNotFound && result.length == 0 {return NSRange(location:NSNotFound,length:0)}
            return NSRange(location: result.location, length: result.length)
        }
        return (value as? NSValue)?.rangeValue
    }
}
