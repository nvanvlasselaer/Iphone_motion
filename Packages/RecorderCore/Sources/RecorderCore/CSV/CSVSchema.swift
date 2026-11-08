//
//  CSVSchema.swift
//  RecorderCore
//
//  Column layout of every CSV file written by the recorder. DATA_FORMAT.md documents each column;
//  a unit test checks that every column listed here appears in that document.
//

import Foundation

public enum CSVSchema {
    /// Device-motion streams (`iphone_motion.csv`, `watch_motion.csv`).
    public static let motionColumns = [
        "t_uptime_s",
        "qw", "qx", "qy", "qz",
        "roll_deg", "pitch_deg", "yaw_deg",
        "gyro_x_rad_s", "gyro_y_rad_s", "gyro_z_rad_s",
        "uacc_x_g", "uacc_y_g", "uacc_z_g",
        "grav_x_g", "grav_y_g", "grav_z_g",
        "mag_x_uT", "mag_y_uT", "mag_z_uT",
        "mag_accuracy",
        "heading_deg",
    ]

    /// Raw accelerometer stream (`watch_accel.csv`).
    public static let accelColumns = ["t_uptime_s", "acc_x_g", "acc_y_g", "acc_z_g"]

    /// Event logs (`iphone_events.csv`, `watch_events.csv`).
    public static let eventColumns = ["t_uptime_s", "t_continuous_s", "t_unix_s", "event", "step", "detail"]

    /// Clock-synchronization pings (`clock_sync.csv`).
    public static let clockSyncColumns = [
        "seq", "burst",
        "t1_iphone_s", "t2_watch_s", "t3_watch_s", "t4_iphone_s",
        "rtt_s", "offset_watch_minus_iphone_s",
        "status", "used_in_fit",
    ]

    public static func header(_ columns: [String]) -> String {
        columns.joined(separator: ",") + "\n"
    }

    // Decimal places per quantity.
    static let timeDecimals = 6
    static let quaternionDecimals = 7
    static let angleDecimals = 4
    static let rateDecimals = 6
    static let accelerationDecimals = 6
    static let magneticDecimals = 3
    static let headingDecimals = 2

    public static func appendMotionRow(_ r: MotionRecord, to out: inout [UInt8]) {
        let comma = UInt8(ascii: ",")
        FixedPoint.append(r.t, decimals: timeDecimals, to: &out)
        for q in [r.qw, r.qx, r.qy, r.qz] {
            out.append(comma)
            FixedPoint.append(Double(q), decimals: quaternionDecimals, to: &out)
        }
        for angle in [r.roll, r.pitch, r.yaw] {
            out.append(comma)
            FixedPoint.append(Double(angle) * 180 / .pi, decimals: angleDecimals, to: &out)
        }
        appendVector(r.gyro, decimals: rateDecimals, to: &out)
        appendVector(r.userAcceleration, decimals: accelerationDecimals, to: &out)
        appendVector(r.gravity, decimals: accelerationDecimals, to: &out)
        appendVector(r.magneticField, decimals: magneticDecimals, to: &out)
        out.append(comma)
        FixedPoint.append(Int(r.magneticAccuracy), to: &out)
        out.append(comma)
        FixedPoint.append(Double(r.heading), decimals: headingDecimals, to: &out)
        out.append(UInt8(ascii: "\n"))
    }

    public static func appendAccelRow(_ r: AccelRecord, to out: inout [UInt8]) {
        FixedPoint.append(r.t, decimals: timeDecimals, to: &out)
        appendVector(r.acceleration, decimals: accelerationDecimals, to: &out)
        out.append(UInt8(ascii: "\n"))
    }

    private static func appendVector(_ v: SIMD3<Float>, decimals: Int, to out: inout [UInt8]) {
        for component in [v.x, v.y, v.z] {
            out.append(UInt8(ascii: ","))
            FixedPoint.append(Double(component), decimals: decimals, to: &out)
        }
    }
}
