//
//  CoreMotionSupport.swift
//  RecorderCore
//
//  Conversion from CoreMotion types to journal records (iOS and watchOS only).
//

import Foundation

#if os(iOS) || os(watchOS)
import CoreMotion

extension MotionRecord {
    public init(_ motion: CMDeviceMotion) {
        let q = motion.attitude.quaternion
        let field = motion.magneticField
        let hasMagnetometer = field.accuracy != .uncalibrated
        self.init(
            t: motion.timestamp,
            qw: Float(q.w), qx: Float(q.x), qy: Float(q.y), qz: Float(q.z),
            roll: Float(motion.attitude.roll),
            pitch: Float(motion.attitude.pitch),
            yaw: Float(motion.attitude.yaw),
            gyro: SIMD3(Float(motion.rotationRate.x), Float(motion.rotationRate.y), Float(motion.rotationRate.z)),
            userAcceleration: SIMD3(Float(motion.userAcceleration.x), Float(motion.userAcceleration.y), Float(motion.userAcceleration.z)),
            gravity: SIMD3(Float(motion.gravity.x), Float(motion.gravity.y), Float(motion.gravity.z)),
            magneticField: hasMagnetometer
                ? SIMD3(Float(field.field.x), Float(field.field.y), Float(field.field.z))
                : SIMD3(repeating: .nan),
            magneticAccuracy: Int32(field.accuracy.rawValue),
            heading: motion.heading >= 0 ? Float(motion.heading) : .nan
        )
    }
}

extension AccelRecord {
    public init(_ data: CMAccelerometerData) {
        self.init(
            t: data.timestamp,
            acceleration: SIMD3(Float(data.acceleration.x), Float(data.acceleration.y), Float(data.acceleration.z))
        )
    }
}

public enum ReferenceFrames {
    public static let all: [(name: String, frame: CMAttitudeReferenceFrame)] = [
        ("xArbitraryZVertical", .xArbitraryZVertical),
        ("xArbitraryCorrectedZVertical", .xArbitraryCorrectedZVertical),
        ("xMagneticNorthZVertical", .xMagneticNorthZVertical),
        ("xTrueNorthZVertical", .xTrueNorthZVertical),
    ]

    /// Names of the frames this device supports.
    public static func availableNames() -> [String] {
        let available = CMMotionManager.availableAttitudeReferenceFrames()
        return all.filter { available.contains($0.frame) }.map(\.name)
    }

    public static func frame(named name: String) -> CMAttitudeReferenceFrame? {
        all.first { $0.name == name }?.frame
    }

    public static func name(of frame: CMAttitudeReferenceFrame) -> String {
        all.first { $0.frame == frame }?.name ?? "unknown(\(frame.rawValue))"
    }

    public static func title(_ name: String) -> String {
        switch name {
        case "xArbitraryZVertical": return "Arbitrary heading (gyro only)"
        case "xArbitraryCorrectedZVertical": return "Arbitrary heading, magnetometer-corrected"
        case "xMagneticNorthZVertical": return "Magnetic north"
        case "xTrueNorthZVertical": return "True north"
        default: return name
        }
    }
}
#endif
