import Foundation

public struct StatisticsExportSnapshot: Codable, Equatable, Sendable {
    public let id: String
    public let revision: Int64
}

public struct StatisticsExportCursor: Codable, Sendable {
    public let snapshot: StatisticsExportSnapshot
    public let start: Double
    public let end: Double
    public let afterMinute: Int64
}

public struct StatisticsExportPage: Decodable, Sendable {
    public let header: String
    public let csv: String
    public let rowCount: Int
    public let totalRows: Int
    public let snapshot: StatisticsExportSnapshot
    public let nextCursor: StatisticsExportCursor?
    public let hasMore: Bool
}

/// The dashboard and the integration harness use the same bounded export path.
/// Only the resident owns SQLite; the exporter requests pages and owns the file.
public enum StatisticsCSVExporter {
    @discardableResult
    public static func write(to url: URL, start: Double, end: Double,
                             request: ([String: Any]) throws -> Any,
                             checkCancellation: () throws -> Void = {},
                             beginPublish: () throws -> Void = {},
                             progress: (Int, Int) -> Void = { _, _ in }) throws -> Int {
        guard start.isFinite, end.isFinite, start >= 0, end >= start, end < 1e12 else {
            throw RuntimeError("统计导出范围无效。")
        }
        var cursor: StatisticsExportCursor?, snapshot: StatisticsExportSnapshot?
        var expectedHeader: String?, expectedTotal: Int?, written = 0
        try PrivateFile.write(to: url, beforePublish: beginPublish) { append in
            while true {
                try checkCancellation()
                var query: [String: Any] = ["op": "exportPage", "start": start, "end": end, "limit": 500]
                if let cursor { query["cursor"] = try object(cursor) }
                let raw = try request(query)
                let data = try JSONSerialization.data(withJSONObject: raw, options: [.withoutEscapingSlashes])
                guard data.count <= 1024 * 1024 else { throw RuntimeError("统计导出分页超过响应预算。") }
                let page = try JSONDecoder().decode(StatisticsExportPage.self, from: data)
                guard page.rowCount >= 0, page.rowCount <= 500, page.totalRows >= 0,
                      page.snapshot.revision >= 0, !page.snapshot.id.isEmpty,
                      !page.header.isEmpty,
                      (snapshot == nil || snapshot == page.snapshot),
                      (expectedHeader == nil || expectedHeader == page.header),
                      (expectedTotal == nil || expectedTotal == page.totalRows),
                      page.rowCount <= page.totalRows - written else {
                    throw RuntimeError("统计导出快照或分页计数不一致，原目标文件已保留。")
                }
                try checkCancellation()
                if expectedHeader == nil { try append(Data(page.header.utf8)) }
                try append(Data(page.csv.utf8))
                written += page.rowCount
                snapshot = page.snapshot; expectedHeader = page.header; expectedTotal = page.totalRows
                progress(written, page.totalRows)
                if !page.hasMore {
                    guard page.nextCursor == nil, written == page.totalRows else {
                        throw RuntimeError("统计导出未覆盖完整范围，未发布部分文件。")
                    }
                    break
                }
                guard page.rowCount > 0, written < page.totalRows, let next = page.nextCursor,
                      next.start == start, next.end == end, next.snapshot == page.snapshot,
                      next.afterMinute % 60 == 0,
                      Double(next.afterMinute) >= floor(start / 60) * 60,
                      Double(next.afterMinute) < end,
                      cursor == nil || next.afterMinute > cursor!.afterMinute else {
                    throw RuntimeError("统计导出游标没有正确推进，未发布部分文件。")
                }
                cursor = next
            }
            try checkCancellation()
            guard let snapshot else { throw RuntimeError("缺少统计导出快照。") }
            _ = try request(["op": "exportValidate", "snapshot": try object(snapshot)])
            try checkCancellation()
        }
        return written
    }

    private static func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }
}
