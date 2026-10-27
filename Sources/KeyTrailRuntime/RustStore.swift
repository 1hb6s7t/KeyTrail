import Foundation
import CKeyTrailRust
import KeyTrailIPC

final class RustStore {
    private let handle: UnsafeMutableRawPointer
    init(url: URL) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard let pointer = keytrail_open(url.path, &error) else {
            let message = error.map { String(cString: $0) } ?? "Rust 数据库无法打开。"
            if let error { keytrail_string_free(error) }
            throw RuntimeError(message)
        }
        handle = pointer
    }
    deinit { keytrail_close(handle) }
    func request(_ value: [String: Any]) throws -> Any {
        let input = try JSONSerialization.data(withJSONObject: value)
        guard let string = String(data: input, encoding: .utf8), let output = keytrail_request(handle, string) else { throw RuntimeError("Rust 核心没有返回有效响应。") }
        defer { keytrail_string_free(output) }
        let data = Data(String(cString: output).utf8)
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw RuntimeError("Rust 核心响应格式错误。") }
        guard response["ok"] as? Bool == true else { throw RuntimeError(response["error"] as? String ?? "Rust 核心处理失败。") }
        return response["result"] ?? NSNull()
    }
}
