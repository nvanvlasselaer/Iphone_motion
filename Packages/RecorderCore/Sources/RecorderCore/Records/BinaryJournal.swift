//
//  BinaryJournal.swift
//  RecorderCore
//
//  Append-only journal of fixed-size records:
//
//      16-byte header: "IMUJ" | version u16 | kind u16 | recordSize u32 | reserved u32
//      followed by recordCount * recordSize bytes
//
//  Crash safety: buffered records are written at least every `flushInterval` seconds. After a crash
//  the file ends at a record boundary or with a partial record, which readers ignore and writers
//  truncate when reopening.
//

import Foundation

public enum JournalError: Error, Equatable, CustomStringConvertible {
    case tooShort
    case badMagic
    case unsupportedVersion(UInt16)
    case kindMismatch(expected: UInt16, found: UInt16)
    case recordSizeMismatch(expected: Int, found: Int)
    case closed
    case cannotCreate(String)

    public var description: String {
        switch self {
        case .tooShort: return "Journal file is shorter than its header."
        case .badMagic: return "Not a journal file (bad magic)."
        case .unsupportedVersion(let v): return "Unsupported journal version \(v)."
        case .kindMismatch(let e, let f): return "Journal holds record kind \(f), expected \(e)."
        case .recordSizeMismatch(let e, let f): return "Journal record size \(f), expected \(e)."
        case .closed: return "Journal is closed."
        case .cannotCreate(let path): return "Cannot create journal at \(path)."
        }
    }
}

enum JournalHeader {
    static let magic: [UInt8] = Array("IMUJ".utf8)
    static let version: UInt16 = 1
    static let size = 16

    static func encode(kind: UInt16, recordSize: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: size)
        bytes.withUnsafeMutableBytes { buffer in
            for (i, b) in magic.enumerated() { buffer[i] = b }
            var w = ByteWriter(UnsafeMutableRawBufferPointer(rebasing: buffer[4...]))
            w.uint16(version)
            w.uint16(kind)
            w.uint32(UInt32(recordSize))
            w.uint32(0)
        }
        return bytes
    }

    static func validate(_ bytes: UnsafeRawBufferPointer, kind: UInt16, recordSize: Int) throws {
        guard bytes.count >= size else { throw JournalError.tooShort }
        guard Array(bytes[0..<4]) == magic else { throw JournalError.badMagic }
        var r = ByteReader(UnsafeRawBufferPointer(rebasing: bytes[4..<size]))
        let foundVersion = r.uint16()
        let foundKind = r.uint16()
        let foundSize = Int(r.uint32())
        guard foundVersion == version else { throw JournalError.unsupportedVersion(foundVersion) }
        guard foundKind == kind else { throw JournalError.kindMismatch(expected: kind, found: foundKind) }
        guard foundSize == recordSize else { throw JournalError.recordSizeMismatch(expected: recordSize, found: foundSize) }
    }
}

/// Appends records to a journal file. Not thread-safe: use it from a single serial queue.
public final class JournalWriter<R: BinaryRecord> {
    public let url: URL
    /// Records appended so far (including records that are still buffered).
    public private(set) var recordCount: Int

    private let handle: FileHandle
    private let flushBytes: Int
    private let flushInterval: Double
    private let clock: () -> Double
    private var pending: [UInt8] = []
    private var lastFlush: Double
    private var isClosed = false

    /// Opens `url` for appending, creating it if needed. An existing journal is validated and a partial
    /// trailing record (from a crash) is truncated before new records are appended.
    public init(
        url: URL,
        attributes: [FileAttributeKey: Any] = [:],
        flushBytes: Int = 64 << 10,
        flushInterval: Double = 1,
        clock: @escaping () -> Double = MonotonicClock.uptime
    ) throws {
        let fileManager = FileManager.default
        let handle: FileHandle
        if fileManager.fileExists(atPath: url.path) {
            handle = try FileHandle(forUpdating: url)
            let header = try handle.read(upToCount: JournalHeader.size) ?? Data()
            guard header.count == JournalHeader.size else { throw JournalError.tooShort }
            try header.withUnsafeBytes { try JournalHeader.validate($0, kind: R.kind, recordSize: R.byteSize) }
            let end = try handle.seekToEnd()
            let bodyBytes = Int(end) - JournalHeader.size
            let tail = bodyBytes % R.byteSize
            if tail != 0 {
                try handle.truncate(atOffset: end - UInt64(tail))
                try handle.seekToEnd()
            }
            recordCount = bodyBytes / R.byteSize
        } else {
            let header = Data(JournalHeader.encode(kind: R.kind, recordSize: R.byteSize))
            guard fileManager.createFile(atPath: url.path, contents: header, attributes: attributes) else {
                throw JournalError.cannotCreate(url.path)
            }
            handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            recordCount = 0
        }
        self.url = url
        self.handle = handle
        self.flushBytes = flushBytes
        self.flushInterval = flushInterval
        self.clock = clock
        self.lastFlush = clock()
        pending.reserveCapacity(flushBytes + R.byteSize)
    }

    deinit {
        _ = try? close()
    }

    public func append(_ record: R) throws {
        guard !isClosed else { throw JournalError.closed }
        encode(record)
        try flushIfNeeded()
    }

    public func append<S: Sequence>(contentsOf records: S) throws where S.Element == R {
        guard !isClosed else { throw JournalError.closed }
        for record in records {
            encode(record)
        }
        try flushIfNeeded()
    }

    /// Writes buffered records to the file; with `fsync` also forces them to storage.
    public func flush(fsync: Bool) throws {
        guard !isClosed else { return }
        if !pending.isEmpty {
            try handle.write(contentsOf: pending)
            pending.removeAll(keepingCapacity: true)
        }
        lastFlush = clock()
        if fsync {
            try handle.synchronize()
        }
    }

    /// Flushes, syncs and closes the file. Returns the number of records in the journal.
    @discardableResult
    public func close() throws -> Int {
        guard !isClosed else { return recordCount }
        try flush(fsync: true)
        try handle.close()
        isClosed = true
        return recordCount
    }

    private func encode(_ record: R) {
        let start = pending.count
        pending.append(contentsOf: repeatElement(0, count: R.byteSize))
        pending.withUnsafeMutableBytes { buffer in
            record.encode(into: UnsafeMutableRawBufferPointer(rebasing: buffer[start..<(start + R.byteSize)]))
        }
        recordCount += 1
    }

    private func flushIfNeeded() throws {
        if pending.count >= flushBytes || clock() - lastFlush >= flushInterval {
            try flush(fsync: false)
        }
    }
}

/// Reads a journal file (memory-mapped). A partial trailing record is ignored and reported.
public struct JournalReader<R: BinaryRecord>: Sequence {
    public let url: URL
    public let recordCount: Int
    /// Bytes after the last complete record (non-zero after a crash mid-write).
    public let truncatedTailBytes: Int

    private let data: Data

    public init(url: URL) throws {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        guard data.count >= JournalHeader.size else { throw JournalError.tooShort }
        try data.withUnsafeBytes { buffer in
            try JournalHeader.validate(
                UnsafeRawBufferPointer(rebasing: buffer[0..<JournalHeader.size]),
                kind: R.kind,
                recordSize: R.byteSize
            )
        }
        let bodyBytes = data.count - JournalHeader.size
        self.url = url
        self.data = data
        self.recordCount = bodyBytes / R.byteSize
        self.truncatedTailBytes = bodyBytes % R.byteSize
    }

    public subscript(index: Int) -> R {
        precondition(index >= 0 && index < recordCount, "Journal index out of range")
        return data.withUnsafeBytes { buffer in
            let start = JournalHeader.size + index * R.byteSize
            return R(decoding: UnsafeRawBufferPointer(rebasing: buffer[start..<(start + R.byteSize)]))
        }
    }

    /// Fast sequential access to every complete record.
    public func forEachRecord(_ body: (R) throws -> Void) rethrows {
        try data.withUnsafeBytes { buffer in
            var start = JournalHeader.size
            for _ in 0..<recordCount {
                try body(R(decoding: UnsafeRawBufferPointer(rebasing: buffer[start..<(start + R.byteSize)])))
                start += R.byteSize
            }
        }
    }

    public func makeIterator() -> Iterator {
        Iterator(reader: self)
    }

    public struct Iterator: IteratorProtocol {
        private let reader: JournalReader<R>
        private var index = 0

        init(reader: JournalReader<R>) {
            self.reader = reader
        }

        public mutating func next() -> R? {
            guard index < reader.recordCount else { return nil }
            defer { index += 1 }
            return reader[index]
        }
    }
}
