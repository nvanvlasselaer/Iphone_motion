//
//  ClockSync.swift
//  RecorderCore
//
//  NTP-style estimation of the offset and drift between the iPhone and Apple Watch uptime clocks.
//
//  One ping: the iPhone sends at t1 (iPhone uptime), the Watch receives at t2 and replies at t3
//  (Watch uptime), the iPhone receives the reply at t4 (iPhone uptime).
//
//      round-trip delay  δ = (t4 − t1) − (t3 − t2)
//      offset            θ = ((t2 − t1) + (t3 − t4)) / 2      (watch − iPhone, error ≤ δ/2)
//      midpoint          m = (t1 + t4) / 2                     (iPhone uptime)
//
//  Pings are grouped in windows (the start and end bursts each form one window, periodic pings are
//  grouped per `windowS`). Within a window only the lowest-delay quarter is kept and the median
//  offset taken. A weighted least-squares line θ(m) = θ0 + r·(m − m_ref) with weights 1/δmin²
//  gives the offset θ0 at m_ref and the drift r. The two clocks then relate as
//
//      t_watch  = t_iphone + θ0 + r·(t_iphone − m_ref)
//      t_iphone = (t_watch − θ0 + r·m_ref) / (1 + r)
//

import Foundation

public enum PingBurst: String, Codable, Sendable {
    case start
    case periodic
    case end
}

public enum PingStatus: String, Codable, Sendable {
    case ok
    case timeout
    case error
}

public struct PingSample: Codable, Equatable, Sendable {
    public var seq: Int
    public var burst: PingBurst
    public var t1: Double
    public var t2: Double?
    public var t3: Double?
    public var t4: Double?
    public var status: PingStatus

    public init(seq: Int, burst: PingBurst, t1: Double, t2: Double? = nil, t3: Double? = nil, t4: Double? = nil, status: PingStatus) {
        self.seq = seq
        self.burst = burst
        self.t1 = t1
        self.t2 = t2
        self.t3 = t3
        self.t4 = t4
        self.status = status
    }

    /// Round-trip network delay (excludes the Watch's processing time).
    public var rtt: Double? {
        guard let t2, let t3, let t4 else { return nil }
        return (t4 - t1) - (t3 - t2)
    }

    /// Estimated Watch − iPhone clock offset.
    public var offset: Double? {
        guard let t2, let t3, let t4 else { return nil }
        return ((t2 - t1) + (t3 - t4)) / 2
    }

    /// iPhone uptime at which the offset applies.
    public var midpoint: Double? {
        guard let t4 else { return nil }
        return (t1 + t4) / 2
    }

    public var isUsable: Bool {
        guard status == .ok, let rtt else { return false }
        return rtt >= 0 && rtt.isFinite
    }

    /// CSV row for `clock_sync.csv`.
    public func csvFields(usedInFit: Bool?) -> [String] {
        func time(_ v: Double?) -> String { v.map { FixedPoint.string($0, decimals: 6) } ?? "" }
        return [
            String(seq),
            burst.rawValue,
            time(t1), time(t2), time(t3), time(t4),
            time(rtt), time(offset),
            status.rawValue,
            usedInFit.map { $0 ? "1" : "0" } ?? "",
        ]
    }
}

public struct ClockSyncSummary: Codable, Equatable, Sendable {
    public struct Window: Codable, Equatable, Sendable {
        public var label: String
        /// Median midpoint of the selected pings (iPhone uptime, s).
        public var midpointS: Double
        /// Median offset of the selected pings (watch − iPhone, s).
        public var offsetS: Double
        public var minRttS: Double
        public var used: Int
        public var total: Int
    }

    public var method: String
    /// m_ref: iPhone uptime at which `offsetS` applies.
    public var refIphoneUptimeS: Double
    /// θ0: watch − iPhone uptime offset at m_ref.
    public var offsetS: Double
    /// r in parts per million (watch clock runs faster than the iPhone clock when positive).
    public var driftPpm: Double
    /// False when the pings span less than the minimum drift span; drift is then fixed at 0.
    public var driftEstimated: Bool
    public var residualRmsS: Double
    public var maxAbsResidualS: Double
    public var nPings: Int
    public var nLost: Int
    public var nUsed: Int
    public var spanS: Double
    public var minRttS: Double
    public var windows: [Window]

    /// Watch uptime corresponding to an iPhone uptime.
    public func watchTime(fromIphone tp: Double) -> Double {
        let r = driftPpm * 1e-6
        return tp + offsetS + r * (tp - refIphoneUptimeS)
    }

    /// iPhone uptime corresponding to a Watch uptime.
    public func iphoneTime(fromWatch tw: Double) -> Double {
        let r = driftPpm * 1e-6
        return (tw - offsetS + r * refIphoneUptimeS) / (1 + r)
    }
}

public enum ClockSyncEstimator {
    public static let method = "ntp-lowdelay-wls/1"

    public struct Estimate: Equatable, Sendable {
        public var summary: ClockSyncSummary
        /// Sequence numbers of the pings that entered the fit.
        public var usedSeqs: Set<Int>
    }

    public static func estimate(
        _ pings: [PingSample],
        windowS: Double = 60,
        keepFraction: Double = 0.25,
        minDriftSpanS: Double = 60
    ) -> Estimate? {
        let usable = pings.filter(\.isUsable)
        guard !usable.isEmpty else { return nil }

        // Group into windows.
        let firstPeriodic = usable.filter { $0.burst == .periodic }.compactMap(\.midpoint).min() ?? 0
        var groups: [String: [PingSample]] = [:]
        for ping in usable {
            let key: String
            switch ping.burst {
            case .start: key = "start"
            case .end: key = "end"
            case .periodic:
                let index = Int(((ping.midpoint ?? firstPeriodic) - firstPeriodic) / windowS)
                key = "periodic-\(index)"
            }
            groups[key, default: []].append(ping)
        }

        var windows: [ClockSyncSummary.Window] = []
        var usedSeqs = Set<Int>()
        for (label, group) in groups {
            let sorted = group.sorted { ($0.rtt ?? .infinity) < ($1.rtt ?? .infinity) }
            let keep = max(1, Int((Double(sorted.count) * keepFraction).rounded(.up)))
            let selected = Array(sorted.prefix(keep))
            usedSeqs.formUnion(selected.map(\.seq))
            windows.append(ClockSyncSummary.Window(
                label: label,
                midpointS: median(selected.compactMap(\.midpoint)),
                offsetS: median(selected.compactMap(\.offset)),
                minRttS: selected[0].rtt ?? 0,
                used: selected.count,
                total: group.count
            ))
        }
        windows.sort { $0.midpointS < $1.midpointS }

        // Weighted least squares over the windows.
        let weights = windows.map { 1 / pow(max($0.minRttS, 1e-3), 2) }
        let weightSum = weights.reduce(0, +)
        let mRef = zip(weights, windows).map { $0 * $1.midpointS }.reduce(0, +) / weightSum
        let meanOffset = zip(weights, windows).map { $0 * $1.offsetS }.reduce(0, +) / weightSum
        let span = (windows.last?.midpointS ?? 0) - (windows.first?.midpointS ?? 0)

        var drift = 0.0
        var driftEstimated = false
        if windows.count >= 2 && span >= minDriftSpanS {
            var sxx = 0.0
            var sxy = 0.0
            for (w, window) in zip(weights, windows) {
                let x = window.midpointS - mRef
                sxx += w * x * x
                sxy += w * x * (window.offsetS - meanOffset)
            }
            if sxx > 0 {
                drift = sxy / sxx
                driftEstimated = true
            }
        }

        let residuals = windows.map { $0.offsetS - (meanOffset + drift * ($0.midpointS - mRef)) }
        let rms = sqrt(residuals.map { $0 * $0 }.reduce(0, +) / Double(residuals.count))

        let summary = ClockSyncSummary(
            method: method,
            refIphoneUptimeS: mRef,
            offsetS: meanOffset,
            driftPpm: drift * 1e6,
            driftEstimated: driftEstimated,
            residualRmsS: rms,
            maxAbsResidualS: residuals.map(abs).max() ?? 0,
            nPings: pings.count,
            nLost: pings.count - usable.count,
            nUsed: usedSeqs.count,
            spanS: span,
            minRttS: usable.compactMap(\.rtt).min() ?? 0,
            windows: windows
        )
        return Estimate(summary: summary, usedSeqs: usedSeqs)
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return .nan }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
