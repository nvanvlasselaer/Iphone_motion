//
//  SessionManifest.swift
//  RecorderCore
//
//  `session.json` (written by the iPhone) and `manifest.json` (written by the Watch and merged into
//  session.json on the iPhone). Keys are snake_case; property names must therefore avoid capitalized
//  acronyms (`sessionId`, not `sessionID`) so they round-trip through the key conversion.
//

import Foundation

public enum SessionStatus: String, Codable, Sendable {
    case recording
    case awaitingWatchData = "awaiting_watch_data"
    case complete
    case interrupted
}

public enum StreamKind: String, Codable, Sendable {
    case motion
    case accel
}

public struct StreamInfo: Codable, Equatable, Sendable {
    public var kind: StreamKind
    public var file: String
    /// e.g. "CMMotionManager.deviceMotion", "CMBatchedSensorManager.deviceMotion".
    public var sourceApi: String
    public var requestedHz: Double?
    /// Rate reported by the API (batched sensors).
    public var reportedHz: Double?
    /// CMAttitudeReferenceFrame name, for device motion.
    public var referenceFrame: String?
    /// Uptime at which device-motion updates (and thus the heading reference) started.
    public var dmStartUptimeS: Double?
    public var stats: StreamStats?
    public var truncatedTailBytes: Int?

    public init(
        kind: StreamKind,
        file: String,
        sourceApi: String,
        requestedHz: Double? = nil,
        reportedHz: Double? = nil,
        referenceFrame: String? = nil,
        dmStartUptimeS: Double? = nil,
        stats: StreamStats? = nil,
        truncatedTailBytes: Int? = nil
    ) {
        self.kind = kind
        self.file = file
        self.sourceApi = sourceApi
        self.requestedHz = requestedHz
        self.reportedHz = reportedHz
        self.referenceFrame = referenceFrame
        self.dmStartUptimeS = dmStartUptimeS
        self.stats = stats
        self.truncatedTailBytes = truncatedTailBytes
    }
}

public struct BatteryInfo: Codable, Equatable, Sendable {
    public var start: Float?
    public var end: Float?

    public init(start: Float? = nil, end: Float? = nil) {
        self.start = start
        self.end = end
    }
}

public struct DeviceSection: Codable, Equatable, Sendable {
    public var info: DeviceInfo
    public var placement: Placement
    public var anchorStart: ClockAnchor?
    public var anchorEnd: ClockAnchor?
    public var battery: BatteryInfo
    public var guidedAccess: Bool?
    public var lowPowerMode: Bool?
    public var eventsFile: String?
    public var streams: [StreamInfo]

    public init(
        info: DeviceInfo,
        placement: Placement,
        anchorStart: ClockAnchor? = nil,
        anchorEnd: ClockAnchor? = nil,
        battery: BatteryInfo = BatteryInfo(),
        guidedAccess: Bool? = nil,
        lowPowerMode: Bool? = nil,
        eventsFile: String? = nil,
        streams: [StreamInfo] = []
    ) {
        self.info = info
        self.placement = placement
        self.anchorStart = anchorStart
        self.anchorEnd = anchorEnd
        self.battery = battery
        self.guidedAccess = guidedAccess
        self.lowPowerMode = lowPowerMode
        self.eventsFile = eventsFile
        self.streams = streams
    }
}

public struct Devices: Codable, Equatable, Sendable {
    public var iphone: DeviceSection?
    public var watch: DeviceSection?

    public init(iphone: DeviceSection? = nil, watch: DeviceSection? = nil) {
        self.iphone = iphone
        self.watch = watch
    }
}

public struct FileEntry: Codable, Equatable, Sendable {
    public var name: String
    public var rows: Int?
    public var bytes: Int64?

    public init(name: String, rows: Int? = nil, bytes: Int64? = nil) {
        self.name = name
        self.rows = rows
        self.bytes = bytes
    }
}

public struct ProtocolTimelineEntry: Codable, Equatable, Sendable {
    public var step: String
    /// iPhone uptime when the step's measurement window opened / closed.
    public var windowStartUptimeS: Double
    public var windowEndUptimeS: Double?

    public init(step: String, windowStartUptimeS: Double, windowEndUptimeS: Double? = nil) {
        self.step = step
        self.windowStartUptimeS = windowStartUptimeS
        self.windowEndUptimeS = windowEndUptimeS
    }
}

public struct ProtocolRecord: Codable, Equatable, Sendable {
    public var definition: ProtocolDefinition
    public var instrumentedSide: BodySide
    public var timeline: [ProtocolTimelineEntry]
    /// "complete", "aborted", "interrupted" or nil while running.
    public var outcome: String?

    public init(definition: ProtocolDefinition, instrumentedSide: BodySide, timeline: [ProtocolTimelineEntry] = [], outcome: String? = nil) {
        self.definition = definition
        self.instrumentedSide = instrumentedSide
        self.timeline = timeline
        self.outcome = outcome
    }
}

/// `session.json`.
public struct SessionManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var sessionId: UUID
    public var folder: String
    public var status: SessionStatus
    public var mode: RecordingMode
    public var subject: String
    public var trial: String
    public var notes: String
    public var created: Timestamp
    public var ended: Timestamp?
    public var guidedProtocol: ProtocolRecord?
    public var devices: Devices
    public var clockSync: ClockSyncSummary?
    public var files: [FileEntry]
    public var warnings: [String]

    public init(
        sessionId: UUID,
        folder: String,
        status: SessionStatus,
        mode: RecordingMode,
        subject: String,
        trial: String,
        notes: String,
        created: Timestamp,
        ended: Timestamp? = nil,
        guidedProtocol: ProtocolRecord? = nil,
        devices: Devices = Devices(),
        clockSync: ClockSyncSummary? = nil,
        files: [FileEntry] = [],
        warnings: [String] = []
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.sessionId = sessionId
        self.folder = folder
        self.status = status
        self.mode = mode
        self.subject = subject
        self.trial = trial
        self.notes = notes
        self.created = created
        self.ended = ended
        self.guidedProtocol = guidedProtocol
        self.devices = devices
        self.clockSync = clockSync
        self.files = files
        self.warnings = warnings
    }
}

/// A file the Watch sends to the iPhone.
public struct WatchFile: Codable, Equatable, Sendable {
    public var kind: FileKind
    public var name: String
    public var records: Int?
    public var bytes: Int64?

    public init(kind: FileKind, name: String, records: Int? = nil, bytes: Int64? = nil) {
        self.kind = kind
        self.name = name
        self.records = records
        self.bytes = bytes
    }
}

/// `manifest.json` written by the Watch at the end of a session.
public struct WatchManifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var sessionId: UUID
    public var start: StartCommand?
    public var device: DeviceSection
    public var status: SessionStatus
    public var stopReason: String
    public var files: [WatchFile]
    public var warnings: [String]
    public var created: Timestamp
    public var ended: Timestamp?

    public init(
        sessionId: UUID,
        start: StartCommand?,
        device: DeviceSection,
        status: SessionStatus,
        stopReason: String,
        files: [WatchFile],
        warnings: [String],
        created: Timestamp,
        ended: Timestamp?
    ) {
        self.schemaVersion = SessionManifest.currentSchemaVersion
        self.sessionId = sessionId
        self.start = start
        self.device = device
        self.status = status
        self.stopReason = stopReason
        self.files = files
        self.warnings = warnings
        self.created = created
        self.ended = ended
    }
}

/// JSON coding used for every metadata file.
public enum ManifestCoding {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return decoder
    }

    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try encoder().encode(value)
        try data.write(to: url, options: [.atomic])
    }

    public static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try decoder().decode(type, from: Data(contentsOf: url))
    }
}
