//
//  Placement.swift
//  RecorderCore
//

import Foundation

public enum RecordingMode: String, Codable, CaseIterable, Sendable {
    case iphone
    case watch
    case both

    public var usesIphone: Bool { self != .watch }
    public var usesWatch: Bool { self != .iphone }

    public var title: String {
        switch self {
        case .iphone: return "iPhone"
        case .watch: return "Watch"
        case .both: return "Both"
        }
    }
}

public enum Segment: String, Codable, CaseIterable, Sendable {
    case pelvis
    case trunk
    case thigh
    case shank
    case foot
    case upperArm = "upper_arm"
    case forearm
    case hand
    case head
    case other

    public var title: String {
        switch self {
        case .upperArm: return "Upper arm"
        default: return rawValue.capitalized
        }
    }
}

public enum BodySide: String, Codable, CaseIterable, Sendable {
    case left
    case right
    case center

    public var title: String { rawValue.capitalized }

    public var opposite: BodySide {
        switch self {
        case .left: return .right
        case .right: return .left
        case .center: return .center
        }
    }
}

/// Where and how a device is attached to the body.
public struct Placement: Codable, Equatable, Sendable {
    public var segment: Segment
    public var side: BodySide
    /// Free text, e.g. "lateral, distal third".
    public var site: String
    /// Free text, e.g. "screen facing out, top up".
    public var orientation: String

    public init(segment: Segment, side: BodySide, site: String, orientation: String) {
        self.segment = segment
        self.side = side
        self.site = site
        self.orientation = orientation
    }

    public static let defaultIphone = Placement(
        segment: .thigh, side: .right, site: "lateral, distal third", orientation: "screen facing out, top up"
    )
    public static let defaultWatch = Placement(
        segment: .shank, side: .right, site: "anteromedial tibia, proximal third", orientation: "crown pointing up"
    )

    public var summary: String {
        "\(side == .center ? "" : side.title + " ")\(segment.title.lowercased()), \(site)"
    }
}

/// Watch sensor configuration sent with the start command.
public enum WatchSensorSource: String, Codable, CaseIterable, Sendable {
    /// CMBatchedSensorManager: 200 Hz device motion (+ optional 800 Hz accelerometer). Series 8+/Ultra.
    case batched
    /// CMMotionManager: up to 100 Hz device motion with a selectable reference frame.
    case legacy
}

public struct WatchSensorConfig: Codable, Equatable, Sendable {
    public var source: WatchSensorSource
    public var accel800: Bool
    public var legacyHz: Double
    public var legacyReferenceFrame: String

    public init(source: WatchSensorSource, accel800: Bool, legacyHz: Double, legacyReferenceFrame: String) {
        self.source = source
        self.accel800 = accel800
        self.legacyHz = legacyHz
        self.legacyReferenceFrame = legacyReferenceFrame
    }

    public static let `default` = WatchSensorConfig(
        source: .batched, accel800: false, legacyHz: 100, legacyReferenceFrame: "xArbitraryZVertical"
    )
}
