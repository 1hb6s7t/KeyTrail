import Foundation
import Darwin

public enum RuntimePaths {
    private static let validationBundles = ["com.auriel.keytrail.validation", "com.auriel.keytrail.validation.dashboard", "com.auriel.keytrail.validation.dashboard.repaired"]
    public static var isValidation: Bool { validationBundles.contains(Bundle.main.bundleIdentifier ?? "") }
    public static func profileName(isDemo: Bool, bundleIdentifier: String?) -> String {
        if isDemo { return "KeyTrail Demo" }
        return validationBundles.contains(bundleIdentifier ?? "") ? "KeyTrail Validation" : "KeyTrail"
    }
    public static func keychainService(_ suffix: String, isDemo: Bool = false,
                                       bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> String {
        let scope = isDemo ? ".demo" : (validationBundles.contains(bundleIdentifier ?? "") ? ".validation" : "")
        return "com.auriel.keytrail\(scope).\(suffix)"
    }
    public static func directory(isDemo: Bool) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(profileName(isDemo: isDemo, bundleIdentifier: Bundle.main.bundleIdentifier), isDirectory: true)
    }
    public static func socketURL(isDemo: Bool) -> URL { directory(isDemo: isDemo).appendingPathComponent("engine.sock") }
    public static func databaseURL(isDemo: Bool) -> URL { directory(isDemo: isDemo).appendingPathComponent("activity.sqlite") }
}

public struct RuntimeStatus: Codable {
    public var monitoring: Bool
    public var paused: Bool
    public var permissionGranted: Bool
    public var suspended: Bool
    public var statusText: String
    public var pid: Int
    public var backend: String
    public var isDemo: Bool
    public init(monitoring: Bool, paused: Bool, permissionGranted: Bool, suspended: Bool, statusText: String, pid: Int, backend: String, isDemo: Bool) {
        self.monitoring = monitoring; self.paused = paused; self.permissionGranted = permissionGranted
        self.suspended = suspended; self.statusText = statusText; self.pid = pid; self.backend = backend; self.isDemo = isDemo
    }
}

public struct RuntimeError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

public final class RuntimeClient: Sendable {
    public let socketURL: URL
    public init(isDemo: Bool) { socketURL = RuntimePaths.socketURL(isDemo: isDemo) }
    public init(socketURL: URL) { self.socketURL = socketURL }
    public func request(_ object: [String: Any]) throws -> Any {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RuntimeError("无法创建本地连接。") }
        defer { Darwin.close(fd) }
        SocketIO.configure(fd, timeout: 3)
        var address = try SocketIO.address(socketURL.path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw RuntimeError("轻量后台尚未运行。请打开主应用「KeyTrail」，再刷新看板。") }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(10)
        try SocketIO.write(data, fd: fd)
        let response = try SocketIO.readLine(fd: fd, limit: 64 * 1024 * 1024)
        guard let envelope = try JSONSerialization.jsonObject(with: response) as? [String: Any] else { throw RuntimeError("后台响应格式不正确。") }
        guard envelope["ok"] as? Bool == true else { throw RuntimeError(envelope["error"] as? String ?? "后台处理失败。") }
        return envelope["result"] ?? NSNull()
    }
    public func status() throws -> RuntimeStatus {
        let value = try request(["op": "status"])
        return try JSONDecoder().decode(RuntimeStatus.self, from: JSONSerialization.data(withJSONObject: value))
    }
}

enum SocketIO {
    static func hasListener(_ path: String) throws -> Bool {
        var address = try self.address(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RuntimeError("无法检查后台连接。") }
        defer { Darwin.close(fd) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if result == 0 { return true }
        if errno == ECONNREFUSED || errno == ENOENT { return false }
        throw RuntimeError("后台连接状态不确定，保留现有连接。")
    }
    static func address(_ path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8)
        var address = sockaddr_un()
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw RuntimeError("本地后台路径过长。") }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            destination.copyBytes(from: bytes)
        }
        return address
    }
    static func configure(_ fd: Int32, timeout: Int) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var value = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    }
    static func write(_ data: Data, fd: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw RuntimeError("本地后台连接已断开或超时。") }
                offset += written
            }
        }
    }
    static func readLine(fd: Int32, limit: Int) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw RuntimeError("本地后台连接已断开或超时。") }
            if let newline = buffer.prefix(count).firstIndex(of: 10) {
                guard result.count + newline <= limit else { throw RuntimeError("数据范围过大，请缩小时间范围。") }
                result.append(contentsOf: buffer[..<newline])
                return result
            }
            guard result.count + count <= limit else { throw RuntimeError("本地请求过大。") }
            result.append(contentsOf: buffer.prefix(count))
        }
    }
}
