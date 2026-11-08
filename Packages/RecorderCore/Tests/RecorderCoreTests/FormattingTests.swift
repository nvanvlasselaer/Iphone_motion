//
//  FormattingTests.swift
//  RecorderCoreTests
//

import XCTest
@testable import RecorderCore

final class FixedPointTests: XCTestCase {
    func testRoundsHalfAwayFromZero() {
        XCTAssertEqual(FixedPoint.string(1.5, decimals: 0), "2")
        XCTAssertEqual(FixedPoint.string(-1.5, decimals: 0), "-2")
        XCTAssertEqual(FixedPoint.string(0.125, decimals: 2), "0.13")
        XCTAssertEqual(FixedPoint.string(-0.125, decimals: 2), "-0.13")
        XCTAssertEqual(FixedPoint.string(1234.5678, decimals: 2), "1234.57")
    }

    func testPadsFractionAndKeepsIntegerPart() {
        XCTAssertEqual(FixedPoint.string(0.000001, decimals: 6), "0.000001")
        XCTAssertEqual(FixedPoint.string(123456.123456, decimals: 6), "123456.123456")
        XCTAssertEqual(FixedPoint.string(1.000000001, decimals: 9), "1.000000001")
        XCTAssertEqual(FixedPoint.string(7, decimals: 3), "7.000")
        XCTAssertEqual(FixedPoint.string(42.4, decimals: 0), "42")
    }

    func testNeverWritesNegativeZero() {
        XCTAssertEqual(FixedPoint.string(-0.0001, decimals: 3), "0.000")
        XCTAssertEqual(FixedPoint.string(-0.0, decimals: 2), "0.00")
    }

    func testNonFiniteValuesAreEmpty() {
        XCTAssertEqual(FixedPoint.string(.nan, decimals: 3), "")
        XCTAssertEqual(FixedPoint.string(.infinity, decimals: 3), "")
        XCTAssertEqual(FixedPoint.string(-.infinity, decimals: 3), "")
    }

    func testIntegers() {
        var out: [UInt8] = []
        FixedPoint.append(-42, to: &out)
        out.append(UInt8(ascii: ","))
        FixedPoint.append(0, to: &out)
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "-42,0")
    }

    func testUsesDotRegardlessOfLocale() {
        // A Belgian number formatter would use a comma; the CSV formatter never does.
        let belgian = NumberFormatter()
        belgian.locale = Locale(identifier: "nl_BE")
        belgian.minimumFractionDigits = 2
        XCTAssertEqual(belgian.string(from: 1.25), "1,25")
        XCTAssertEqual(FixedPoint.string(1.25, decimals: 2), "1.25")
        for value in stride(from: -3.0, through: 3.0, by: 0.37) {
            XCTAssertFalse(FixedPoint.string(value, decimals: 4).contains(","))
        }
    }

    func testCSVTextQuoting() {
        XCTAssertEqual(CSVText.escape("plain"), "plain")
        XCTAssertEqual(CSVText.escape("a,b"), "\"a,b\"")
        XCTAssertEqual(CSVText.escape("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(CSVText.line(["x", "", "y,z"]), "x,,\"y,z\"\n")
    }
}

final class StreamStatsTests: XCTestCase {
    func testRateGapsAndOrdering() {
        var stats = StreamStats(nominalHz: 100)
        var t = 10.0
        for _ in 0..<100 {
            stats.add(t)
            t += 0.01
        }
        stats.add(t + 0.04)          // 50 ms gap
        stats.add(t + 0.04)          // duplicate timestamp
        XCTAssertEqual(stats.count, 102)
        XCTAssertEqual(stats.gapCount, 1)
        XCTAssertEqual(stats.nonMonotonicCount, 1)
        XCTAssertEqual(stats.maxIntervalS, 0.05, accuracy: 1e-9)
        XCTAssertEqual(stats.firstT, 10.0)
        XCTAssertEqual(stats.achievedHz ?? 0, 101 / (t + 0.04 - 10.0), accuracy: 1e-6)
    }

    func testRingBufferKeepsNewest() {
        var buffer = RingBuffer<Int>(capacity: 3)
        XCTAssertNil(buffer.last)
        for i in 1...5 { buffer.append(i) }
        XCTAssertEqual(buffer.elements, [3, 4, 5])
        XCTAssertEqual(buffer.last, 5)
        buffer.removeAll()
        XCTAssertTrue(buffer.isEmpty)
    }

    func testDecimator() {
        var decimator = Decimator(factor: 5)
        let emitted = (0..<12).filter { _ in decimator.shouldEmit() }
        XCTAssertEqual(emitted, [0, 5, 10])
    }
}

final class SessionNamingTests: XCTestCase {
    func testFolderName() {
        let date = Date(timeIntervalSince1970: 1_791_216_000) // 2026-10-05 16:00:00 UTC
        let name = SessionNaming.folderName(start: date, timeZone: TimeZone(identifier: "UTC")!, subject: "S01", trial: "run 1")
        XCTAssertEqual(name, "2026-10-05_16-00-00_S01_run-1")
        XCTAssertEqual(
            SessionNaming.folderName(start: date, timeZone: TimeZone(identifier: "UTC")!, subject: "", trial: ""),
            "2026-10-05_16-00-00"
        )
    }

    func testSanitize() {
        XCTAssertEqual(SessionNaming.sanitize("S 01/ä"), "S-01")
        XCTAssertEqual(SessionNaming.sanitize("../evil"), "evil")
        XCTAssertEqual(SessionNaming.sanitize("ok_name-1.2"), "ok_name-1.2")
        XCTAssertEqual(SessionNaming.sanitize(String(repeating: "x", count: 60)).count, 40)
    }

    func testNextTrialLabel() {
        XCTAssertEqual(SessionNaming.nextTrialLabel("T09"), "T10")
        XCTAssertEqual(SessionNaming.nextTrialLabel("run3"), "run4")
        XCTAssertEqual(SessionNaming.nextTrialLabel("T99"), "T100")
        XCTAssertEqual(SessionNaming.nextTrialLabel("007"), "008")
        XCTAssertEqual(SessionNaming.nextTrialLabel("base"), "base_2")
        XCTAssertEqual(SessionNaming.nextTrialLabel(""), "1")
    }

    func testUniqued() {
        XCTAssertEqual(SessionNaming.uniqued("a", existing: []), "a")
        XCTAssertEqual(SessionNaming.uniqued("a", existing: ["a", "a_2"]), "a_3")
    }
}
