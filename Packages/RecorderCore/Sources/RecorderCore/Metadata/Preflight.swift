//
//  Preflight.swift
//  RecorderCore
//
//  Checks run before a session starts. Errors block the start; warnings and tips are shown.
//

import Foundation

public struct WatchPreflight: Equatable, Sendable {
    public var paired: Bool
    public var appInstalled: Bool
    public var reachable: Bool
    public var authorization: WatchAuthorization?
    public var freeBytes: Int64?
    public var battery: Float?
    public var lowPowerMode: Bool
    public var phase: WatchPhase?

    public init(
        paired: Bool,
        appInstalled: Bool,
        reachable: Bool,
        authorization: WatchAuthorization? = nil,
        freeBytes: Int64? = nil,
        battery: Float? = nil,
        lowPowerMode: Bool = false,
        phase: WatchPhase? = nil
    ) {
        self.paired = paired
        self.appInstalled = appInstalled
        self.reachable = reachable
        self.authorization = authorization
        self.freeBytes = freeBytes
        self.battery = battery
        self.lowPowerMode = lowPowerMode
        self.phase = phase
    }
}

public struct PreflightInput: Equatable, Sendable {
    public var mode: RecordingMode
    public var deviceMotionAvailable: Bool
    public var phoneFreeBytes: Int64?
    /// 0...1, nil when unknown.
    public var phoneBattery: Float?
    public var phoneLowPowerMode: Bool
    public var guidedAccess: Bool
    public var pocketMode: Bool
    public var voiceCues: Bool
    /// System output volume 0...1, nil when unknown.
    public var outputVolume: Float?
    public var watch: WatchPreflight?

    public init(
        mode: RecordingMode,
        deviceMotionAvailable: Bool,
        phoneFreeBytes: Int64?,
        phoneBattery: Float?,
        phoneLowPowerMode: Bool,
        guidedAccess: Bool,
        pocketMode: Bool,
        voiceCues: Bool,
        outputVolume: Float?,
        watch: WatchPreflight?
    ) {
        self.mode = mode
        self.deviceMotionAvailable = deviceMotionAvailable
        self.phoneFreeBytes = phoneFreeBytes
        self.phoneBattery = phoneBattery
        self.phoneLowPowerMode = phoneLowPowerMode
        self.guidedAccess = guidedAccess
        self.pocketMode = pocketMode
        self.voiceCues = voiceCues
        self.outputVolume = outputVolume
        self.watch = watch
    }
}

public struct PreflightItem: Equatable, Sendable, Identifiable {
    public enum Severity: Int, Comparable, Sendable {
        case tip
        case warning
        case error

        public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var id: String
    public var severity: Severity
    public var message: String

    public init(id: String, severity: Severity, message: String) {
        self.id = id
        self.severity = severity
        self.message = message
    }
}

public enum Preflight {
    public static let phoneMinimumFreeBytes: Int64 = 300_000_000
    public static let phoneComfortableFreeBytes: Int64 = 1_000_000_000
    public static let watchMinimumFreeBytes: Int64 = 200_000_000
    public static let lowBattery: Float = 0.2

    public static func evaluate(_ input: PreflightInput) -> [PreflightItem] {
        var items: [PreflightItem] = []
        func add(_ id: String, _ severity: PreflightItem.Severity, _ message: String) {
            items.append(PreflightItem(id: id, severity: severity, message: message))
        }

        if input.mode.usesIphone && !input.deviceMotionAvailable {
            add("phone.motion", .error, "Device motion is not available on this iPhone.")
        }
        if let free = input.phoneFreeBytes {
            if free < phoneMinimumFreeBytes {
                add("phone.space", .error, "Less than 300 MB free on the iPhone.")
            } else if free < phoneComfortableFreeBytes {
                add("phone.space", .warning, "Less than 1 GB free on the iPhone.")
            }
        }
        if let battery = input.phoneBattery, battery < lowBattery {
            add("phone.battery", .warning, "iPhone battery below 20%.")
        }
        if input.phoneLowPowerMode {
            add("phone.lowpower", .warning, "Low Power Mode is on: turn it off for steady sampling.")
        }
        if input.voiceCues, let volume = input.outputVolume, volume < 0.3 {
            add("phone.volume", .warning, "iPhone volume is low: voice cues may be hard to hear.")
        }
        if input.mode.usesIphone && input.pocketMode && !input.guidedAccess {
            add("phone.guidedaccess", .tip, "Tip: start Guided Access with the side and volume buttons disabled so a strap cannot lock the iPhone.")
        }

        if input.mode.usesWatch {
            guard let watch = input.watch, watch.paired else {
                add("watch.paired", .error, "No Apple Watch is paired with this iPhone.")
                return items
            }
            if !watch.appInstalled {
                add("watch.installed", .error, "Install the Watch app (Watch app on iPhone ▸ Available Apps).")
            } else if !watch.reachable {
                add("watch.reachable", .error, "The Watch app is not reachable: tap Connect, or open the app on the Watch.")
            } else {
                if let authorization = watch.authorization, !authorization.isReady {
                    add("watch.auth", .error, "Open the app on the Watch and allow Health and Motion access.")
                }
                if let free = watch.freeBytes, free < watchMinimumFreeBytes {
                    add("watch.space", .error, "Less than 200 MB free on the Watch.")
                }
                if let battery = watch.battery, battery < lowBattery {
                    add("watch.battery", .warning, "Watch battery below 20%.")
                }
                if watch.lowPowerMode {
                    add("watch.lowpower", .warning, "Low Power Mode is on on the Watch.")
                }
                if let phase = watch.phase, phase == .recording || phase == .starting || phase == .finalizing {
                    add("watch.busy", .error, "The Watch is still busy with another session.")
                }
            }
        }
        return items.sorted { $0.severity > $1.severity }
    }

    public static func canStart(_ items: [PreflightItem]) -> Bool {
        !items.contains { $0.severity == .error }
    }
}
