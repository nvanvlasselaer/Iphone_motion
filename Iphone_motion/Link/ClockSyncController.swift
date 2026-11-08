//
//  ClockSyncController.swift
//  Iphone_motion
//
//  Pings the Watch during a session (bursts at start and trial end, one ping every 5 s), writes
//  every ping to clock_sync.csv and fits the clock model at the end.
//

import Foundation
import RecorderCore

@MainActor
final class ClockSyncController {
    private let link: PhoneLink
    private let csvURL: URL
    private var writer: CSVLineWriter?
    private(set) var pings: [PingSample] = []
    private var seq = 0
    private var periodicTask: Task<Void, Never>?

    /// Called after every ping with the Watch status carried by the reply (if any).
    var onPing: ((PingSample, WatchStatus?) -> Void)?

    init(link: PhoneLink, csvURL: URL) throws {
        self.link = link
        self.csvURL = csvURL
        writer = try CSVLineWriter(url: csvURL, columns: CSVSchema.clockSyncColumns, attributes: SessionStore.protection)
    }

    @discardableResult
    func pingOnce(burst: PingBurst, wantStatus: Bool) async -> (PingSample, WatchStatus?) {
        seq += 1
        let (ping, status) = await link.ping(seq: seq, burst: burst, wantStatus: wantStatus)
        pings.append(ping)
        try? writer?.write(ping.csvFields(usedInFit: nil))
        onPing?(ping, status)
        return (ping, status)
    }

    func burst(_ burst: PingBurst, count: Int = 20) async {
        for _ in 0..<count {
            if Task.isCancelled { return }
            await pingOnce(burst: burst, wantStatus: false)
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func startPeriodic(every interval: Double = 5) {
        periodicTask?.cancel()
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pingOnce(burst: .periodic, wantStatus: true)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1e9))
            }
        }
    }

    func stopPeriodic() {
        periodicTask?.cancel()
        periodicTask = nil
    }

    /// Stops pinging, fits the model and rewrites clock_sync.csv with the `used_in_fit` column.
    func finish() -> ClockSyncSummary? {
        stopPeriodic()
        try? writer?.close()
        writer = nil
        guard let estimate = ClockSyncEstimator.estimate(pings) else { return nil }
        let temporary = csvURL.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: temporary)
        if let rewrite = try? CSVLineWriter(url: temporary, columns: CSVSchema.clockSyncColumns, attributes: SessionStore.protection) {
            for ping in pings {
                try? rewrite.write(ping.csvFields(usedInFit: estimate.usedSeqs.contains(ping.seq)))
            }
            try? rewrite.close()
            _ = try? FileManager.default.replaceItemAt(csvURL, withItemAt: temporary)
        }
        return estimate.summary
    }
}
