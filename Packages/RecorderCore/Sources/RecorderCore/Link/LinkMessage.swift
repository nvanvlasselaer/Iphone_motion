//
//  LinkMessage.swift
//  RecorderCore
//
//  Messages exchanged between the iPhone and Watch apps over WatchConnectivity. Every message
//  travels as a JSON `Envelope` (sendMessageData, or the "env" key of userInfo/file metadata).
//

import Foundation

public enum WatchPhase: String, Codable, Sendable {
    case idle
    case arming
    case armed
    case starting
    case recording
    case finalizing
}

public enum FileKind: String, Codable, CaseIterable, Sendable {
    case manifest
    case motion
    case accel
    case events
}

public struct StreamProgress: Codable, Equatable, Sendable {
    public var count: Int
    public var hz: Double?
    public var gaps: Int

    public init(count: Int, hz: Double?, gaps: Int) {
        self.count = count
        self.hz = hz
        self.gaps = gaps
    }
}

/// Watch state reported in pong replies.
public struct WatchStatus: Codable, Equatable, Sendable {
    public var phase: WatchPhase
    public var sid: UUID?
    public var elapsedS: Double?
    public var motion: StreamProgress?
    public var accel: StreamProgress?
    public var battery: Float?
    public var waterLock: Bool
    public var lastError: String?
    /// Delivery uptime minus the last sample's timestamp (batch latency), seconds.
    public var batchLatencyS: Double?
    public var pendingTransfers: Int

    public init(
        phase: WatchPhase,
        sid: UUID? = nil,
        elapsedS: Double? = nil,
        motion: StreamProgress? = nil,
        accel: StreamProgress? = nil,
        battery: Float? = nil,
        waterLock: Bool = false,
        lastError: String? = nil,
        batchLatencyS: Double? = nil,
        pendingTransfers: Int = 0
    ) {
        self.phase = phase
        self.sid = sid
        self.elapsedS = elapsedS
        self.motion = motion
        self.accel = accel
        self.battery = battery
        self.waterLock = waterLock
        self.lastError = lastError
        self.batchLatencyS = batchLatencyS
        self.pendingTransfers = pendingTransfers
    }
}

public struct WatchCapabilities: Codable, Equatable, Sendable {
    public var batchedDeviceMotion: Bool
    public var batchedAccelerometer: Bool
    public var legacyReferenceFrames: [String]
    public var waterLockSupported: Bool

    public init(batchedDeviceMotion: Bool, batchedAccelerometer: Bool, legacyReferenceFrames: [String], waterLockSupported: Bool) {
        self.batchedDeviceMotion = batchedDeviceMotion
        self.batchedAccelerometer = batchedAccelerometer
        self.legacyReferenceFrames = legacyReferenceFrames
        self.waterLockSupported = waterLockSupported
    }
}

public struct WatchAuthorization: Codable, Equatable, Sendable {
    /// "authorized", "denied" or "notDetermined".
    public var health: String
    /// "authorized", "denied", "restricted" or "notDetermined".
    public var motion: String

    public init(health: String, motion: String) {
        self.health = health
        self.motion = motion
    }

    public var isReady: Bool { health == "authorized" && motion == "authorized" }
}

public struct HelloPayload: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var appVersion: String

    public init(protocolVersion: Int = Envelope.protocolVersion, appVersion: String) {
        self.protocolVersion = protocolVersion
        self.appVersion = appVersion
    }
}

public struct HelloReplyPayload: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var device: DeviceInfo
    public var capabilities: WatchCapabilities
    public var authorization: WatchAuthorization
    public var status: WatchStatus
    public var pendingSessions: [UUID]
    public var freeBytes: Int64?
    public var lowPowerMode: Bool

    public init(
        protocolVersion: Int = Envelope.protocolVersion,
        device: DeviceInfo,
        capabilities: WatchCapabilities,
        authorization: WatchAuthorization,
        status: WatchStatus,
        pendingSessions: [UUID],
        freeBytes: Int64?,
        lowPowerMode: Bool
    ) {
        self.protocolVersion = protocolVersion
        self.device = device
        self.capabilities = capabilities
        self.authorization = authorization
        self.status = status
        self.pendingSessions = pendingSessions
        self.freeBytes = freeBytes
        self.lowPowerMode = lowPowerMode
    }
}

public struct StartCommand: Codable, Equatable, Sendable {
    /// Session folder name on the iPhone.
    public var folder: String
    public var mode: RecordingMode
    public var subject: String
    public var trial: String
    public var placement: Placement
    public var sensors: WatchSensorConfig
    public var maxDurationS: Double
    public var waterLock: Bool

    public init(
        folder: String,
        mode: RecordingMode,
        subject: String,
        trial: String,
        placement: Placement,
        sensors: WatchSensorConfig,
        maxDurationS: Double,
        waterLock: Bool
    ) {
        self.folder = folder
        self.mode = mode
        self.subject = subject
        self.trial = trial
        self.placement = placement
        self.sensors = sensors
        self.maxDurationS = maxDurationS
        self.waterLock = waterLock
    }
}

public struct StopCommand: Codable, Equatable, Sendable {
    public var reason: String

    public init(reason: String) {
        self.reason = reason
    }
}

public struct CommandAck: Codable, Equatable, Sendable {
    public var accepted: Bool
    public var phase: WatchPhase
    public var error: String?

    public init(accepted: Bool, phase: WatchPhase, error: String? = nil) {
        self.accepted = accepted
        self.phase = phase
        self.error = error
    }
}

public struct PingPayload: Codable, Equatable, Sendable {
    public var seq: Int
    public var t1: Double
    public var wantStatus: Bool

    public init(seq: Int, t1: Double, wantStatus: Bool) {
        self.seq = seq
        self.t1 = t1
        self.wantStatus = wantStatus
    }
}

public struct PongPayload: Codable, Equatable, Sendable {
    public var seq: Int
    public var t2: Double
    public var t3: Double
    public var status: WatchStatus?

    public init(seq: Int, t2: Double, t3: Double, status: WatchStatus?) {
        self.seq = seq
        self.t2 = t2
        self.t3 = t3
        self.status = status
    }
}

public struct StepNotice: Codable, Equatable, Sendable {
    public var stepId: String
    public var kind: StepKind
    public var haptic: HapticKind?

    public init(stepId: String, kind: StepKind, haptic: HapticKind?) {
        self.stepId = stepId
        self.kind = kind
        self.haptic = haptic
    }
}

public struct MarkerPayload: Codable, Equatable, Sendable {
    public var label: String

    public init(label: String) {
        self.label = label
    }
}

/// Metadata attached to a transferred file.
public struct FileInfo: Codable, Equatable, Sendable {
    public var kind: FileKind
    public var records: Int?
    public var bytes: Int64?

    public init(kind: FileKind, records: Int? = nil, bytes: Int64? = nil) {
        self.kind = kind
        self.records = records
        self.bytes = bytes
    }
}

public struct IngestAckPayload: Codable, Equatable, Sendable {
    public var ok: Bool
    public var kinds: [FileKind]

    public init(ok: Bool, kinds: [FileKind]) {
        self.ok = ok
        self.kinds = kinds
    }
}

public enum LinkMessage: Equatable, Sendable {
    case hello(HelloPayload)
    case helloReply(HelloReplyPayload)
    case arm
    case disarm
    case start(StartCommand)
    case stop(StopCommand)
    case ack(CommandAck)
    case ping(PingPayload)
    case pong(PongPayload)
    case step(StepNotice)
    case marker(MarkerPayload)
    case endTrial
    case file(FileInfo)
    case ingestAck(IngestAckPayload)
    case resend
    case unknown(String)

    public var type: String {
        switch self {
        case .hello: return "hello"
        case .helloReply: return "helloReply"
        case .arm: return "arm"
        case .disarm: return "disarm"
        case .start: return "start"
        case .stop: return "stop"
        case .ack: return "ack"
        case .ping: return "ping"
        case .pong: return "pong"
        case .step: return "step"
        case .marker: return "marker"
        case .endTrial: return "endTrial"
        case .file: return "file"
        case .ingestAck: return "ingestAck"
        case .resend: return "resend"
        case .unknown(let type): return type
        }
    }
}

extension LinkMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case payload
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "hello": self = .hello(try container.decode(HelloPayload.self, forKey: .payload))
        case "helloReply": self = .helloReply(try container.decode(HelloReplyPayload.self, forKey: .payload))
        case "arm": self = .arm
        case "disarm": self = .disarm
        case "start": self = .start(try container.decode(StartCommand.self, forKey: .payload))
        case "stop": self = .stop(try container.decode(StopCommand.self, forKey: .payload))
        case "ack": self = .ack(try container.decode(CommandAck.self, forKey: .payload))
        case "ping": self = .ping(try container.decode(PingPayload.self, forKey: .payload))
        case "pong": self = .pong(try container.decode(PongPayload.self, forKey: .payload))
        case "step": self = .step(try container.decode(StepNotice.self, forKey: .payload))
        case "marker": self = .marker(try container.decode(MarkerPayload.self, forKey: .payload))
        case "endTrial": self = .endTrial
        case "file": self = .file(try container.decode(FileInfo.self, forKey: .payload))
        case "ingestAck": self = .ingestAck(try container.decode(IngestAckPayload.self, forKey: .payload))
        case "resend": self = .resend
        default: self = .unknown(type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        switch self {
        case .hello(let p): try container.encode(p, forKey: .payload)
        case .helloReply(let p): try container.encode(p, forKey: .payload)
        case .start(let p): try container.encode(p, forKey: .payload)
        case .stop(let p): try container.encode(p, forKey: .payload)
        case .ack(let p): try container.encode(p, forKey: .payload)
        case .ping(let p): try container.encode(p, forKey: .payload)
        case .pong(let p): try container.encode(p, forKey: .payload)
        case .step(let p): try container.encode(p, forKey: .payload)
        case .marker(let p): try container.encode(p, forKey: .payload)
        case .file(let p): try container.encode(p, forKey: .payload)
        case .ingestAck(let p): try container.encode(p, forKey: .payload)
        case .arm, .disarm, .endTrial, .resend, .unknown: break
        }
    }
}

public struct Envelope: Codable, Equatable, Sendable {
    /// Bump when messages change incompatibly; both apps must then be updated.
    public static let protocolVersion = 1

    public var v: Int
    /// Unique per message; retries reuse it so the receiver can answer idempotently.
    public var id: UUID
    /// Session the message belongs to.
    public var sid: UUID?
    /// Sender uptime when the envelope was created.
    public var sent: Double
    public var body: LinkMessage

    public init(_ body: LinkMessage, sid: UUID? = nil, id: UUID = UUID(), sent: Double = MonotonicClock.uptime()) {
        self.v = Self.protocolVersion
        self.id = id
        self.sid = sid
        self.sent = sent
        self.body = body
    }
}

public enum LinkError: Error, Equatable, CustomStringConvertible {
    case versionMismatch(Int)
    case notActivated
    case notReachable
    case timedOut
    case unexpectedReply(String)
    case rejected(String)
    case transport(String)

    public var description: String {
        switch self {
        case .versionMismatch(let v): return "The iPhone and Watch apps use different message versions (\(v) vs \(Envelope.protocolVersion)). Update both apps."
        case .notActivated: return "WatchConnectivity is not active."
        case .notReachable: return "The Watch app is not reachable."
        case .timedOut: return "The Watch did not reply in time."
        case .unexpectedReply(let type): return "Unexpected reply from the Watch (\(type))."
        case .rejected(let reason): return "The Watch rejected the command: \(reason)"
        case .transport(let message): return message
        }
    }
}

public enum LinkCodec {
    public static let userInfoKey = "env"

    public static func encode(_ envelope: Envelope) throws -> Data {
        try JSONEncoder().encode(envelope)
    }

    public static func decode(_ data: Data) throws -> Envelope {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.v == Envelope.protocolVersion else {
            throw LinkError.versionMismatch(envelope.v)
        }
        return envelope
    }

    /// Dictionary for `transferUserInfo` / `transferFile(metadata:)`.
    public static func userInfo(_ envelope: Envelope) throws -> [String: Any] {
        [userInfoKey: try encode(envelope)]
    }

    public static func envelope(from dictionary: [String: Any]) throws -> Envelope? {
        guard let data = dictionary[userInfoKey] as? Data else { return nil }
        return try decode(data)
    }
}
