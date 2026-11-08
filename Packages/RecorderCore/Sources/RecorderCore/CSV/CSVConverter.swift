//
//  CSVConverter.swift
//  RecorderCore
//

import Foundation

/// Converts binary journals to the documented CSV files. Output is written to `<name>.partial`
/// and renamed when complete, so a half-written CSV never looks finished.
public enum CSVConverter {
    public struct Result: Equatable, Sendable {
        public var rows: Int
        public var truncatedTailBytes: Int
        public var stats: StreamStats
        public var bytes: Int64
    }

    public static func convertMotion(
        journal: URL,
        to csv: URL,
        nominalHz: Double,
        attributes: [FileAttributeKey: Any] = [:],
        progress: ((Double) -> Void)? = nil
    ) throws -> Result {
        try convert(
            journal: journal, to: csv, columns: CSVSchema.motionColumns, nominalHz: nominalHz,
            attributes: attributes, progress: progress
        ) { (record: MotionRecord, out: inout [UInt8]) in
            CSVSchema.appendMotionRow(record, to: &out)
        }
    }

    public static func convertAccel(
        journal: URL,
        to csv: URL,
        nominalHz: Double,
        attributes: [FileAttributeKey: Any] = [:],
        progress: ((Double) -> Void)? = nil
    ) throws -> Result {
        try convert(
            journal: journal, to: csv, columns: CSVSchema.accelColumns, nominalHz: nominalHz,
            attributes: attributes, progress: progress
        ) { (record: AccelRecord, out: inout [UInt8]) in
            CSVSchema.appendAccelRow(record, to: &out)
        }
    }

    private static func convert<R: BinaryRecord>(
        journal: URL,
        to csv: URL,
        columns: [String],
        nominalHz: Double,
        attributes: [FileAttributeKey: Any],
        progress: ((Double) -> Void)?,
        row: (R, inout [UInt8]) -> Void
    ) throws -> Result {
        let reader = try JournalReader<R>(url: journal)
        let fileManager = FileManager.default
        let partial = csv.appendingPathExtension("partial")
        try? fileManager.removeItem(at: partial)
        guard fileManager.createFile(atPath: partial.path, contents: nil, attributes: attributes) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: partial.path])
        }
        let handle = try FileHandle(forWritingTo: partial)

        let chunkBytes = 1 << 20
        var out: [UInt8] = []
        out.reserveCapacity(chunkBytes + 512)
        out.append(contentsOf: Array(CSVSchema.header(columns).utf8))

        var stats = StreamStats(nominalHz: nominalHz)
        var rows = 0
        var bytes: Int64 = 0
        let total = Double(max(reader.recordCount, 1))
        do {
            try reader.forEachRecord { record in
                stats.add(record.t)
                row(record, &out)
                rows += 1
                if out.count >= chunkBytes {
                    try handle.write(contentsOf: out)
                    bytes += Int64(out.count)
                    out.removeAll(keepingCapacity: true)
                    progress?(Double(rows) / total)
                }
            }
            try handle.write(contentsOf: out)
            bytes += Int64(out.count)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            try? fileManager.removeItem(at: partial)
            throw error
        }

        if fileManager.fileExists(atPath: csv.path) {
            try fileManager.removeItem(at: csv)
        }
        try fileManager.moveItem(at: partial, to: csv)
        progress?(1)
        return Result(rows: rows, truncatedTailBytes: reader.truncatedTailBytes, stats: stats, bytes: bytes)
    }
}
