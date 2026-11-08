//
//  EventLog.swift
//  RecorderCore
//

import Foundation

/// Writes a text CSV file line by line (header written once, existing files are appended to).
/// Not thread-safe.
public final class CSVLineWriter {
    public let url: URL
    private let handle: FileHandle
    private var isClosed = false

    public init(url: URL, columns: [String], attributes: [FileAttributeKey: Any] = [:]) throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: url.path) {
            let header = Data(CSVSchema.header(columns).utf8)
            guard fileManager.createFile(atPath: url.path, contents: header, attributes: attributes) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
        }
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        self.url = url
    }

    deinit {
        try? close()
    }

    /// Writes one row; text fields are quoted when needed.
    public func write(_ fields: [String]) throws {
        guard !isClosed else { throw JournalError.closed }
        try handle.write(contentsOf: Data(CSVText.line(fields).utf8))
    }

    public func flush(fsync: Bool) throws {
        guard !isClosed, fsync else { return }
        try handle.synchronize()
    }

    public func close() throws {
        guard !isClosed else { return }
        try handle.synchronize()
        try handle.close()
        isClosed = true
    }
}

/// Thread-safe event log (`*_events.csv`). Every row carries the three clocks of the device that
/// wrote it, captured when `log` is called.
public final class EventLog: @unchecked Sendable {
    public let url: URL
    private let queue = DispatchQueue(label: "RecorderCore.EventLog")
    private var writer: CSVLineWriter?

    public init(url: URL, attributes: [FileAttributeKey: Any] = [:]) throws {
        self.url = url
        writer = try CSVLineWriter(url: url, columns: CSVSchema.eventColumns, attributes: attributes)
    }

    public func log(_ event: String, step: String? = nil, detail: String? = nil, at anchor: ClockAnchor = .now()) {
        queue.async { [weak self] in
            try? self?.writer?.write([
                FixedPoint.string(anchor.uptimeS, decimals: 6),
                FixedPoint.string(anchor.continuousS, decimals: 6),
                FixedPoint.string(anchor.unixS, decimals: 6),
                event,
                step ?? "",
                detail ?? "",
            ])
        }
    }

    public func flush(fsync: Bool) {
        queue.sync {
            try? writer?.flush(fsync: fsync)
        }
    }

    public func close() {
        queue.sync {
            try? writer?.close()
            writer = nil
        }
    }
}
