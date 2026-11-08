//
//  StreamStats.swift
//  RecorderCore
//

import Foundation

/// Running statistics of a sampled stream, computed from sensor timestamps.
public struct StreamStats: Codable, Equatable, Sendable {
    /// Rate the stream is expected to deliver (requested or reported by the API).
    public var nominalHz: Double
    public var count: Int = 0
    public var firstT: Double?
    public var lastT: Double?
    /// Intervals longer than 1.5 nominal sample periods.
    public var gapCount: Int = 0
    /// Longest interval between consecutive samples, seconds.
    public var maxIntervalS: Double = 0
    /// Samples whose timestamp did not increase.
    public var nonMonotonicCount: Int = 0
    /// (count - 1) / (lastT - firstT), when defined.
    public var achievedHz: Double?

    public init(nominalHz: Double) {
        self.nominalHz = nominalHz
    }

    public var durationS: Double {
        guard let firstT, let lastT else { return 0 }
        return lastT - firstT
    }

    public mutating func add(_ t: Double) {
        if let lastT {
            let dt = t - lastT
            if dt <= 0 {
                nonMonotonicCount += 1
            } else {
                maxIntervalS = max(maxIntervalS, dt)
                if nominalHz > 0 && dt > 1.5 / nominalHz {
                    gapCount += 1
                }
            }
        } else {
            firstT = t
        }
        lastT = t
        count += 1
        if let firstT, count > 1, t > firstT {
            achievedHz = Double(count - 1) / (t - firstT)
        }
    }
}
