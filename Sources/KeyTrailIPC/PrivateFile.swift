import Foundation
import Darwin

public enum PrivateFile {
    /// Atomic replacement whose temporary file is owner-only from creation.
    public static func write(_ data: Data, to url: URL) throws {
        try write(to: url) { append in try append(data) }
    }

    /// Streams bounded chunks to an owner-only temporary file. A failed producer
    /// never publishes a partial export or replaces the user's existing file.
    public static func write(to url: URL, beforePublish: () throws -> Void = {}, produce: (_ append: (Data) throws -> Void) throws -> Void) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".keytrail-\(UUID().uuidString).tmp")
        let descriptor = temporary.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, 0o600) }
        guard descriptor >= 0 else { throw RuntimeError("无法创建私密导出文件。") }
        var closed = false
        defer { if !closed { Darwin.close(descriptor) }; try? FileManager.default.removeItem(at: temporary) }
        try produce { data in
            try data.withUnsafeBytes { bytes in
                guard let address = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(descriptor, address.advanced(by: offset), bytes.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw RuntimeError("导出写入失败，原文件已保留。") }
                    offset += count
                }
            }
        }
        guard fsync(descriptor) == 0 else { throw RuntimeError("导出保存失败，原文件已保留。") }
        Darwin.close(descriptor); closed = true
        try beforePublish()
        let result = temporary.path.withCString { from in url.path.withCString { to in Darwin.rename(from, to) } }
        guard result == 0 else { throw RuntimeError("无法完成导出文件替换。") }
    }
}
