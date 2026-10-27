import Foundation
import Darwin

public final class RuntimeServer {
    private let url: URL
    private let fd: Int32
    private let ownership: SocketOwnership
    private let queue = DispatchQueue(label: "keytrail.local-socket", qos: .utility)
    private let handler: ([String: Any]) -> [String: Any]
    private var stopped = false
    private let lock = NSLock()
    public init(url: URL, handler: @escaping ([String: Any]) -> [String: Any]) throws {
        self.url = url; self.handler = handler
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        ownership = try SocketOwnership(url: url.appendingPathExtension("lock"))
        var address = try SocketIO.address(url.path)
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard info.st_uid == getuid(), (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK) else { throw RuntimeError("后台路径不是当前用户的安全套接字。") }
            if try SocketIO.hasListener(url.path) { throw RuntimeError("键迹后台已运行。") }
            guard unlink(url.path) == 0 else { throw RuntimeError("无法清理已失效的后台连接。") }
        }
        fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RuntimeError("无法创建后台套接字。") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { Darwin.close(fd); throw RuntimeError("无法绑定本地后台连接。") }
        guard chmod(url.path, 0o600) == 0, Darwin.listen(fd, 8) == 0 else {
            Darwin.close(fd); unlink(url.path); throw RuntimeError("无法保护或监听本地后台连接。")
        }
    }
    public func start() {
        queue.async { [self] in
            while !isStopped {
                let client = Darwin.accept(fd, nil, nil)
                if client < 0 { if errno == EINTR { continue }; break }
                autoreleasepool {
                    defer { Darwin.close(client) }
                    SocketIO.configure(client, timeout: 3)
                    var uid: uid_t = 0; var gid: gid_t = 0
                    guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { return }
                    let response: [String: Any]
                    do {
                        let data = try SocketIO.readLine(fd: client, limit: 1024 * 1024)
                        guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw RuntimeError("请求格式不正确。") }
                        response = handler(request)
                    } catch { response = ["ok": false, "error": error.localizedDescription] }
                    if var data = try? JSONSerialization.data(withJSONObject: response) {
                        if data.count > 64 * 1024 * 1024 {
                            data = Data("{\"ok\":false,\"error\":\"数据范围过大，请缩小时间范围。\"}".utf8)
                        }
                        data.append(10); try? SocketIO.write(data, fd: client)
                    }
                }
            }
        }
    }
    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    public func stop() {
        lock.lock(); guard !stopped else { lock.unlock(); return }; stopped = true; lock.unlock()
        Darwin.shutdown(fd, SHUT_RDWR); Darwin.close(fd); unlink(url.path)
    }
    deinit { stop() }
}

private final class SocketOwnership {
    private let fd: Int32
    init(url: URL) throws {
        fd = Darwin.open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw RuntimeError("无法取得后台独占锁。") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd); throw RuntimeError("键迹后台已运行，或锁文件不可安全使用。")
        }
    }
    deinit { flock(fd, LOCK_UN); Darwin.close(fd) }
}
