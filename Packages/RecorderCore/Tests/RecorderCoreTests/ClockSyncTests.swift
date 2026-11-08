//
//  ClockSyncTests.swift
//  RecorderCoreTests
//

import XCTest
@testable import RecorderCore

/// Deterministic random numbers for reproducible synthetic data.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Simulated iPhone ↔ Watch link with a known clock relation.
struct SimulatedLink {
    let theta0 = 1234.567
    let drift = 30e-6
    let reference = 1000.0
    var rng = SplitMix64(state: 42)

    func watchTime(_ tp: Double) -> Double { tp + theta0 + drift * (tp - reference) }
    func iphoneTime(_ tw: Double) -> Double { (tw - theta0 + drift * reference) / (1 + drift) }

    mutating func exponential(mean: Double) -> Double {
        -mean * log(1 - Double.random(in: 0..<1, using: &rng))
    }

    /// A ping sent at iPhone uptime t1 with 20 ms base latency each way plus exponential jitter.
    mutating func ping(seq: Int, burst: PingBurst, t1: Double, extraDelay: Double = 0) -> PingSample {
        let forward = 0.020 + exponential(mean: 0.010) + extraDelay
        let backward = 0.020 + exponential(mean: 0.010)
        let t2 = watchTime(t1 + forward)
        let t3 = t2 + 0.001
        let t4 = iphoneTime(t3) + backward
        return PingSample(seq: seq, burst: burst, t1: t1, t2: t2, t3: t3, t4: t4, status: .ok)
    }
}

final class ClockSyncTests: XCTestCase {
    private func session(includeEnd: Bool = true, outliers: Bool = false, lost: Bool = false) -> (SimulatedLink, [PingSample]) {
        var link = SimulatedLink()
        var pings: [PingSample] = []
        var seq = 0
        var t = 1000.0
        for _ in 0..<20 {
            let ping = link.ping(seq: seq, burst: .start, t1: t)
            pings.append(ping)
            t = ping.t4! + 0.05
            seq += 1
        }
        var periodic = 1010.0
        while periodic < 1600 {
            pings.append(link.ping(seq: seq, burst: .periodic, t1: periodic, extraDelay: outliers && seq % 7 == 0 ? 2 : 0))
            if lost && seq % 5 == 0 {
                pings.append(PingSample(seq: seq + 10_000, burst: .periodic, t1: periodic + 1, status: .timeout))
            }
            periodic += 5
            seq += 1
        }
        if includeEnd {
            t = 1600
            for _ in 0..<20 {
                let ping = link.ping(seq: seq, burst: .end, t1: t)
                pings.append(ping)
                t = ping.t4! + 0.05
                seq += 1
            }
        }
        return (link, pings)
    }

    func testRecoversOffsetAndDrift() throws {
        let (link, pings) = session()
        let estimate = try XCTUnwrap(ClockSyncEstimator.estimate(pings))
        let summary = estimate.summary
        XCTAssertTrue(summary.driftEstimated)
        XCTAssertEqual(summary.driftPpm, 30, accuracy: 5)
        for tp in stride(from: 1000.0, through: 1600.0, by: 50) {
            XCTAssertEqual(summary.watchTime(fromIphone: tp), link.watchTime(tp), accuracy: 0.010)
        }
        XCTAssertEqual(summary.nLost, 0)
        XCTAssertGreaterThan(summary.nUsed, 0)
        XCTAssertLessThan(summary.nUsed, pings.count)
        XCTAssertEqual(summary.windows.first?.label, "start")
        XCTAssertEqual(summary.windows.last?.label, "end")
    }

    func testRejectsDelayedOutliersAndCountsLostPings() throws {
        let (link, pings) = session(outliers: true, lost: true)
        let summary = try XCTUnwrap(ClockSyncEstimator.estimate(pings)).summary
        XCTAssertGreaterThan(summary.nLost, 0)
        XCTAssertEqual(summary.driftPpm, 30, accuracy: 5)
        XCTAssertEqual(summary.watchTime(fromIphone: 1300), link.watchTime(1300), accuracy: 0.010)
    }

    func testSingleBurstFixesDriftAtZero() throws {
        var link = SimulatedLink()
        var pings: [PingSample] = []
        var t = 1000.0
        for seq in 0..<20 {
            let ping = link.ping(seq: seq, burst: .start, t1: t)
            pings.append(ping)
            t = ping.t4! + 0.05
        }
        let summary = try XCTUnwrap(ClockSyncEstimator.estimate(pings)).summary
        XCTAssertFalse(summary.driftEstimated)
        XCTAssertEqual(summary.driftPpm, 0)
        XCTAssertEqual(summary.offsetS, link.theta0, accuracy: 0.010)
    }

    func testNoUsablePings() {
        XCTAssertNil(ClockSyncEstimator.estimate([]))
        XCTAssertNil(ClockSyncEstimator.estimate([PingSample(seq: 0, burst: .start, t1: 1, status: .timeout)]))
    }

    func testMappingRoundTrip() throws {
        let (_, pings) = session()
        let summary = try XCTUnwrap(ClockSyncEstimator.estimate(pings)).summary
        for tp in [0.0, 1000.0, 1234.5, 99_999.0] {
            XCTAssertEqual(summary.iphoneTime(fromWatch: summary.watchTime(fromIphone: tp)), tp, accuracy: 1e-9)
        }
    }

    func testPingDerivedValuesAndCSVRow() {
        let ping = PingSample(seq: 3, burst: .periodic, t1: 10, t2: 110.02, t3: 110.03, t4: 10.05, status: .ok)
        XCTAssertEqual(ping.rtt!, 0.04, accuracy: 1e-9)
        XCTAssertEqual(ping.offset!, 100.0, accuracy: 1e-9)
        XCTAssertEqual(ping.midpoint!, 10.025, accuracy: 1e-9)
        XCTAssertEqual(ping.csvFields(usedInFit: true), [
            "3", "periodic", "10.000000", "110.020000", "110.030000", "10.050000", "0.040000", "100.000000", "ok", "1",
        ])
        let lost = PingSample(seq: 4, burst: .end, t1: 11, status: .timeout)
        XCTAssertFalse(lost.isUsable)
        XCTAssertEqual(lost.csvFields(usedInFit: nil), ["4", "end", "11.000000", "", "", "", "", "", "timeout", ""])
    }
}

final class OneShotTests: XCTestCase {
    func testReplyWins() async throws {
        let value: Int = try await withOneShot(timeout: 1) { shot in
            shot.resume(.success(5))
        }
        XCTAssertEqual(value, 5)
    }

    func testTimeoutWins() async {
        do {
            let _: Int = try await withOneShot(timeout: 0.05) { _ in }
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? OneShotError, .timedOut)
        }
    }

    func testLateReplyIsIgnored() async throws {
        let expectation = expectation(description: "late reply")
        do {
            let _: Int = try await withOneShot(timeout: 0.05) { shot in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                    XCTAssertFalse(shot.resume(.success(1)))
                    expectation.fulfill()
                }
            }
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? OneShotError, .timedOut)
        }
        await fulfillment(of: [expectation], timeout: 2)
    }
}
