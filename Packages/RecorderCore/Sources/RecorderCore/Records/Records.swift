//
//  Records.swift
//  RecorderCore
//
//  Fixed-size binary sample records written to journals. Little-endian, Float64 time, Float32 values.
//

import Foundation

/// A fixed-size sample that can be appended to a `JournalWriter`.
public protocol BinaryRecord {
    /// Identifies the record type in the journal header.
    static var kind: UInt16 { get }
    /// Size of one encoded record in bytes.
    static var byteSize: Int { get }
    /// Sensor timestamp in seconds of device uptime.
    var t: Double { get }

    /// Writes exactly `byteSize` bytes into `buffer`.
    func encode(into buffer: UnsafeMutableRawBufferPointer)
    /// Reads a record from exactly `byteSize` bytes.
    init(decoding buffer: UnsafeRawBufferPointer)
}

/// One processed device-motion sample (CoreMotion `CMDeviceMotion`).
///
/// Unavailable values are stored as NaN (magnetic field, heading).
public struct MotionRecord: BinaryRecord, Equatable, Sendable {
    public static let kind: UInt16 = 1
    public static let byteSize = 92

    /// Sensor timestamp, seconds of device uptime.
    public var t: Double
    /// Attitude quaternion as reported by CoreMotion.
    public var qw: Float, qx: Float, qy: Float, qz: Float
    /// CoreMotion Euler angles in radians.
    public var roll: Float, pitch: Float, yaw: Float
    /// Bias-corrected rotation rate, rad/s.
    public var gyro: SIMD3<Float>
    /// Acceleration without gravity, in g.
    public var userAcceleration: SIMD3<Float>
    /// Gravity vector, in g.
    public var gravity: SIMD3<Float>
    /// Calibrated magnetic field, µT (NaN when the reference frame does not use the magnetometer).
    public var magneticField: SIMD3<Float>
    /// CoreMotion calibration accuracy: -1 uncalibrated/unavailable, 0 low, 1 medium, 2 high.
    public var magneticAccuracy: Int32
    /// Heading in degrees relative to the reference frame (NaN when unavailable).
    public var heading: Float

    public init(
        t: Double,
        qw: Float, qx: Float, qy: Float, qz: Float,
        roll: Float, pitch: Float, yaw: Float,
        gyro: SIMD3<Float>,
        userAcceleration: SIMD3<Float>,
        gravity: SIMD3<Float>,
        magneticField: SIMD3<Float> = SIMD3(repeating: .nan),
        magneticAccuracy: Int32 = -1,
        heading: Float = .nan
    ) {
        self.t = t
        self.qw = qw; self.qx = qx; self.qy = qy; self.qz = qz
        self.roll = roll; self.pitch = pitch; self.yaw = yaw
        self.gyro = gyro
        self.userAcceleration = userAcceleration
        self.gravity = gravity
        self.magneticField = magneticField
        self.magneticAccuracy = magneticAccuracy
        self.heading = heading
    }

    public func encode(into buffer: UnsafeMutableRawBufferPointer) {
        var w = ByteWriter(buffer)
        w.double(t)
        w.floats(qw, qx, qy, qz, roll, pitch, yaw)
        w.vector(gyro)
        w.vector(userAcceleration)
        w.vector(gravity)
        w.vector(magneticField)
        w.int32(magneticAccuracy)
        w.floats(heading)
    }

    public init(decoding buffer: UnsafeRawBufferPointer) {
        var r = ByteReader(buffer)
        t = r.double()
        qw = r.float(); qx = r.float(); qy = r.float(); qz = r.float()
        roll = r.float(); pitch = r.float(); yaw = r.float()
        gyro = r.vector()
        userAcceleration = r.vector()
        gravity = r.vector()
        magneticField = r.vector()
        magneticAccuracy = r.int32()
        heading = r.float()
    }

    public static func == (lhs: MotionRecord, rhs: MotionRecord) -> Bool {
        // Bitwise comparison so NaN fields compare equal after a round trip.
        var a = [UInt8](repeating: 0, count: byteSize)
        var b = [UInt8](repeating: 0, count: byteSize)
        a.withUnsafeMutableBytes { lhs.encode(into: $0) }
        b.withUnsafeMutableBytes { rhs.encode(into: $0) }
        return a == b
    }
}

/// One raw accelerometer sample (includes gravity), in g.
public struct AccelRecord: BinaryRecord, Equatable, Sendable {
    public static let kind: UInt16 = 2
    public static let byteSize = 20

    public var t: Double
    public var acceleration: SIMD3<Float>

    public init(t: Double, acceleration: SIMD3<Float>) {
        self.t = t
        self.acceleration = acceleration
    }

    public func encode(into buffer: UnsafeMutableRawBufferPointer) {
        var w = ByteWriter(buffer)
        w.double(t)
        w.vector(acceleration)
    }

    public init(decoding buffer: UnsafeRawBufferPointer) {
        var r = ByteReader(buffer)
        t = r.double()
        acceleration = r.vector()
    }
}

// MARK: - Little-endian helpers

struct ByteWriter {
    private let buffer: UnsafeMutableRawBufferPointer
    private var offset = 0

    init(_ buffer: UnsafeMutableRawBufferPointer) {
        self.buffer = buffer
    }

    mutating func double(_ v: Double) {
        buffer.storeBytes(of: v.bitPattern.littleEndian, toByteOffset: offset, as: UInt64.self)
        offset += 8
    }

    mutating func floats(_ values: Float...) {
        for v in values {
            buffer.storeBytes(of: v.bitPattern.littleEndian, toByteOffset: offset, as: UInt32.self)
            offset += 4
        }
    }

    mutating func vector(_ v: SIMD3<Float>) {
        floats(v.x, v.y, v.z)
    }

    mutating func int32(_ v: Int32) {
        buffer.storeBytes(of: v.littleEndian, toByteOffset: offset, as: Int32.self)
        offset += 4
    }

    mutating func uint16(_ v: UInt16) {
        buffer.storeBytes(of: v.littleEndian, toByteOffset: offset, as: UInt16.self)
        offset += 2
    }

    mutating func uint32(_ v: UInt32) {
        buffer.storeBytes(of: v.littleEndian, toByteOffset: offset, as: UInt32.self)
        offset += 4
    }
}

struct ByteReader {
    private let buffer: UnsafeRawBufferPointer
    private var offset = 0

    init(_ buffer: UnsafeRawBufferPointer) {
        self.buffer = buffer
    }

    mutating func double() -> Double {
        defer { offset += 8 }
        return Double(bitPattern: UInt64(littleEndian: buffer.loadUnaligned(fromByteOffset: offset, as: UInt64.self)))
    }

    mutating func float() -> Float {
        defer { offset += 4 }
        return Float(bitPattern: UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
    }

    mutating func vector() -> SIMD3<Float> {
        SIMD3(float(), float(), float())
    }

    mutating func int32() -> Int32 {
        defer { offset += 4 }
        return Int32(littleEndian: buffer.loadUnaligned(fromByteOffset: offset, as: Int32.self))
    }

    mutating func uint16() -> UInt16 {
        defer { offset += 2 }
        return UInt16(littleEndian: buffer.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
    }

    mutating func uint32() -> UInt32 {
        defer { offset += 4 }
        return UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }
}
