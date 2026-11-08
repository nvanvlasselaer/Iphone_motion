//
//  MonotonicClock.swift
//  RecorderCore
//

import Foundation

/// The three clocks every recording is anchored to.
///
/// - `uptime`: seconds since boot, *not* counting sleep (`CLOCK_UPTIME_RAW` = `mach_absolute_time`).
///   Same time base as `ProcessInfo.systemUptime` and `CMLogItem.timestamp`, so sensor samples and
///   events can be compared directly on one device.
/// - `continuous`: seconds since boot *including* sleep (`CLOCK_MONOTONIC_RAW`). If
///   `continuous - uptime` changes during a session, the device slept.
/// - `unix`: wall-clock seconds since 1970 (can jump when the system time is adjusted).
public enum MonotonicClock {
    public static func uptime() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9
    }

    public static func continuous() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1e9
    }

    public static func unix() -> Double {
        Date().timeIntervalSince1970
    }
}

/// A simultaneous reading of the three clocks of one device.
public struct ClockAnchor: Codable, Equatable, Sendable {
    public var uptimeS: Double
    public var continuousS: Double
    public var unixS: Double

    public init(uptimeS: Double, continuousS: Double, unixS: Double) {
        self.uptimeS = uptimeS
        self.continuousS = continuousS
        self.unixS = unixS
    }

    public static func now() -> ClockAnchor {
        ClockAnchor(
            uptimeS: MonotonicClock.uptime(),
            continuousS: MonotonicClock.continuous(),
            unixS: MonotonicClock.unix()
        )
    }
}

/// Wall-clock time stored in metadata: Unix seconds plus a human-readable ISO 8601 string.
/// Never a Swift `Date` (JSONEncoder would write seconds since 2001).
public struct Timestamp: Codable, Equatable, Sendable {
    public var unixS: Double
    public var iso8601: String
    public var timeZone: String

    public init(unixS: Double, timeZone: TimeZone = .current) {
        self.unixS = unixS
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.iso8601 = formatter.string(from: Date(timeIntervalSince1970: unixS))
        self.timeZone = timeZone.identifier
    }

    public static func now(timeZone: TimeZone = .current) -> Timestamp {
        Timestamp(unixS: MonotonicClock.unix(), timeZone: timeZone)
    }
}
