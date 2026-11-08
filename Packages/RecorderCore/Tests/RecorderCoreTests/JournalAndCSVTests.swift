//
//  JournalAndCSVTests.swift
//  RecorderCoreTests
//

import XCTest
@testable import RecorderCore

final class JournalTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func sample(_ i: Int) -> MotionRecord {
        MotionRecord(
            t: 1000 + Double(i) * 0.01,
            qw: 1, qx: Float(i) * 0.001, qy: -0.5, qz: 0.25,
            roll: 0.1, pitch: -0.2, yaw: 3.0,
            gyro: SIMD3(1, -2, Float(i)),
            userAcceleration: SIMD3(0.01, 0.02, 0.03),
            gravity: SIMD3(0, 0, -1),
            magneticField: i.isMultiple(of: 2) ? SIMD3(repeating: .nan) : SIMD3(20, -30, 40),
            magneticAccuracy: i.isMultiple(of: 2) ? -1 : 2,
            heading: i.isMultiple(of: 2) ? .nan : 90
        )
    }

    func testRoundTrip() throws {
        let url = directory.appendingPathComponent("m.bin")
        let writer = try JournalWriter<MotionRecord>(url: url, flushBytes: 1000)
        let records = (0..<1000).map(sample)
        try writer.append(contentsOf: records.prefix(10))
        for record in records.dropFirst(10) {
            try writer.append(record)
        }
        XCTAssertEqual(try writer.close(), 1000)

        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        XCTAssertEqual(size, 16 + 1000 * MotionRecord.byteSize)

        let reader = try JournalReader<MotionRecord>(url: url)
        XCTAssertEqual(reader.recordCount, 1000)
        XCTAssertEqual(reader.truncatedTailBytes, 0)
        XCTAssertEqual(Array(reader), records)
        XCTAssertTrue(reader[1].magneticField.x == 20)
        XCTAssertTrue(reader[0].heading.isNaN)
    }

    func testRejectsWrongKindAndBadMagic() throws {
        let accelURL = directory.appendingPathComponent("a.bin")
        let writer = try JournalWriter<AccelRecord>(url: accelURL)
        try writer.append(AccelRecord(t: 1, acceleration: SIMD3(0, 0, -1)))
        try writer.close()
        XCTAssertThrowsError(try JournalReader<MotionRecord>(url: accelURL)) { error in
            XCTAssertEqual(error as? JournalError, .kindMismatch(expected: MotionRecord.kind, found: AccelRecord.kind))
        }

        let junk = directory.appendingPathComponent("junk.bin")
        try Data(repeating: 7, count: 64).write(to: junk)
        XCTAssertThrowsError(try JournalReader<MotionRecord>(url: junk)) { error in
            XCTAssertEqual(error as? JournalError, .badMagic)
        }
    }

    func testTruncatedTailIsIgnoredAndRepairedOnReopen() throws {
        let url = directory.appendingPathComponent("m.bin")
        let writer = try JournalWriter<MotionRecord>(url: url)
        try writer.append(contentsOf: (0..<10).map(sample))
        try writer.close()

        // Simulate a crash in the middle of a record.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([1, 2, 3, 4, 5]))
        try handle.close()

        let damaged = try JournalReader<MotionRecord>(url: url)
        XCTAssertEqual(damaged.recordCount, 10)
        XCTAssertEqual(damaged.truncatedTailBytes, 5)

        let reopened = try JournalWriter<MotionRecord>(url: url)
        XCTAssertEqual(reopened.recordCount, 10)
        try reopened.append(sample(10))
        try reopened.close()

        let repaired = try JournalReader<MotionRecord>(url: url)
        XCTAssertEqual(repaired.recordCount, 11)
        XCTAssertEqual(repaired.truncatedTailBytes, 0)
        XCTAssertEqual(repaired[10], sample(10))
    }

    func testFlushesAfterInterval() throws {
        var now = 0.0
        let url = directory.appendingPathComponent("m.bin")
        let writer = try JournalWriter<MotionRecord>(url: url, flushBytes: 1 << 20, flushInterval: 1, clock: { now })
        try writer.append(sample(0))
        XCTAssertEqual(try JournalReader<MotionRecord>(url: url).recordCount, 0, "still buffered")
        now = 1.5
        try writer.append(sample(1))
        XCTAssertEqual(try JournalReader<MotionRecord>(url: url).recordCount, 2, "written after the interval")
        try writer.close()
        XCTAssertThrowsError(try writer.append(sample(2)))
    }
}

final class CSVTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testMotionGoldenFile() throws {
        let journal = directory.appendingPathComponent("m.bin")
        let writer = try JournalWriter<MotionRecord>(url: journal)
        try writer.append(MotionRecord(
            t: 100.000001,
            qw: 1, qx: 0, qy: 0, qz: 0,
            roll: 0, pitch: 0, yaw: 0,
            gyro: SIMD3(0.5, -0.25, 0),
            userAcceleration: SIMD3(0.125, 0, -0.5),
            gravity: SIMD3(0, 0, -1)
        ))
        try writer.append(MotionRecord(
            t: 100.01,
            qw: 0.5, qx: 0.5, qy: 0.5, qz: 0.5,
            roll: .pi / 2, pitch: -.pi / 4, yaw: 0,
            gyro: SIMD3(1, 2, 3),
            userAcceleration: SIMD3(0, 0, 0),
            gravity: SIMD3(0, -1, 0),
            magneticField: SIMD3(10.5, -20.25, 30),
            magneticAccuracy: 2,
            heading: 123.45
        ))
        try writer.close()

        let csv = directory.appendingPathComponent("m.csv")
        let result = try CSVConverter.convertMotion(journal: journal, to: csv, nominalHz: 100)
        XCTAssertEqual(result.rows, 2)
        XCTAssertEqual(result.stats.count, 2)

        let expected = CSVSchema.header(CSVSchema.motionColumns)
            + "100.000001,1.0000000,0.0000000,0.0000000,0.0000000,0.0000,0.0000,0.0000,0.500000,-0.250000,0.000000,0.125000,0.000000,-0.500000,0.000000,0.000000,-1.000000,,,,-1,\n"
            + "100.010000,0.5000000,0.5000000,0.5000000,0.5000000,90.0000,-45.0000,0.0000,1.000000,2.000000,3.000000,0.000000,0.000000,0.000000,0.000000,-1.000000,0.000000,10.500,-20.250,30.000,2,123.45\n"
        XCTAssertEqual(try String(contentsOf: csv, encoding: .utf8), expected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: csv.path + ".partial"))
    }

    func testAccelConversionAndStats() throws {
        let journal = directory.appendingPathComponent("a.bin")
        let writer = try JournalWriter<AccelRecord>(url: journal)
        for i in 0..<801 {
            try writer.append(AccelRecord(t: 50 + Double(i) / 800, acceleration: SIMD3(0, 0, -1)))
        }
        try writer.close()

        let csv = directory.appendingPathComponent("a.csv")
        var lastProgress = 0.0
        let result = try CSVConverter.convertAccel(journal: journal, to: csv, nominalHz: 800) { lastProgress = $0 }
        XCTAssertEqual(result.rows, 801)
        XCTAssertEqual(result.stats.achievedHz ?? 0, 800, accuracy: 1e-6)
        XCTAssertEqual(result.stats.gapCount, 0)
        XCTAssertEqual(lastProgress, 1)
        let lines = try String(contentsOf: csv, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.first.map(String.init), "t_uptime_s,acc_x_g,acc_y_g,acc_z_g")
        XCTAssertEqual(lines[1], "50.000000,0.000000,0.000000,-1.000000")
        XCTAssertEqual(lines.count, 802)
    }

    func testEventLogWritesQuotedRows() throws {
        let url = directory.appendingPathComponent("events.csv")
        let log = try EventLog(url: url)
        log.log("marker", detail: "left, then right", at: ClockAnchor(uptimeS: 1.5, continuousS: 2.5, unixS: 1_800_000_000))
        log.log("step_begin", step: "static_start", at: ClockAnchor(uptimeS: 2, continuousS: 3, unixS: 1_800_000_001))
        log.close()
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text, """
        t_uptime_s,t_continuous_s,t_unix_s,event,step,detail
        1.500000,2.500000,1800000000.000000,marker,,"left, then right"
        2.000000,3.000000,1800000001.000000,step_begin,static_start,

        """)
    }

    func testEveryColumnIsDocumented() throws {
        let url = try XCTUnwrap(RecorderCoreResources.dataFormatURL, "DATA_FORMAT.md must be bundled")
        let document = try String(contentsOf: url, encoding: .utf8)
        let columns = CSVSchema.motionColumns + CSVSchema.accelColumns + CSVSchema.eventColumns + CSVSchema.clockSyncColumns
        for column in columns {
            XCTAssertTrue(document.contains("`\(column)`"), "\(column) is not documented in DATA_FORMAT.md")
        }
        XCTAssertTrue(document.contains("Schema version **\(SessionManifest.currentSchemaVersion)**"))
    }
}
