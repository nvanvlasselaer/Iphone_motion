//
//  Iphone_motionTests.swift
//  Iphone_motionTests
//
//  Created by Nicolas Van Vlasselaer on 18/06/2024.
//
//  App-level tests. The recording logic itself (journals, CSV, clock sync, protocol, state
//  machines) is tested in Packages/RecorderCore with `swift test`.
//

import RecorderCore
import XCTest
@testable import Iphone_motion

final class SessionStoreTests: XCTestCase {
    private var root: URL!
    private var store: SessionStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = SessionStore(documents: root.appendingPathComponent("Documents"), support: root.appendingPathComponent("Support"))
        store.prepareDirectories()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeSession(status: SessionStatus, mode: RecordingMode = .iphone) throws -> (SessionFolder, SessionManifest) {
        let sid = UUID()
        let folder = try store.create(name: "2026-10-05_10-00-00_S01_T\(Int.random(in: 1...999))", sid: sid)
        var manifest = SessionManifest(
            sessionId: sid, folder: folder.name, status: status, mode: mode,
            subject: "S01", trial: "T01", notes: "", created: .now()
        )
        manifest.devices.iphone = DeviceSection(
            info: DeviceInfo.current(),
            placement: .defaultIphone,
            streams: [StreamInfo(kind: .motion, file: "iphone_motion.csv", sourceApi: "CMMotionManager.deviceMotion", requestedHz: 100)]
        )
        try store.writeManifest(manifest, to: folder.url)
        return (folder, manifest)
    }

    func testCreateListAndDelete() throws {
        let (folder, manifest) = try makeSession(status: .complete)
        store.copyDataFormat(to: folder.url)
        let sessions = store.list()
        XCTAssertEqual(sessions.map(\.manifest.sessionId), [manifest.sessionId])
        XCTAssertEqual(store.folder(for: manifest.sessionId), folder.url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.url.appendingPathComponent("DATA_FORMAT.md").path))

        try store.delete(sessions[0])
        XCTAssertTrue(store.list().isEmpty)
        XCTAssertFalse(store.isDeleted(manifest.sessionId), "complete sessions need no tombstone")
    }

    func testDeletingAPendingSessionRemembersItForLateWatchFiles() throws {
        let (_, manifest) = try makeSession(status: .awaitingWatchData, mode: .both)
        try store.delete(store.list()[0])
        XCTAssertTrue(store.isDeleted(manifest.sessionId))
    }

    func testRecoversAnInterruptedRecording() throws {
        let (folder, manifest) = try makeSession(status: .recording)
        let journal = try JournalWriter<MotionRecord>(url: folder.journalDirectory.appendingPathComponent("iphone_motion.bin"))
        for i in 0..<250 {
            try journal.append(MotionRecord(
                t: 50 + Double(i) / 100, qw: 1, qx: 0, qy: 0, qz: 0, roll: 0, pitch: 0, yaw: 0,
                gyro: .zero, userAcceleration: .zero, gravity: SIMD3(0, 0, -1)
            ))
        }
        try journal.flush(fsync: true)   // simulate a crash: never closed properly

        XCTAssertEqual(store.recoverInterrupted(except: nil), [manifest.folder])

        let recovered = try XCTUnwrap(store.readManifest(at: folder.url))
        XCTAssertEqual(recovered.status, .interrupted)
        XCTAssertEqual(recovered.devices.iphone?.streams.first?.stats?.count, 250)
        XCTAssertFalse(recovered.warnings.isEmpty)
        let csv = try String(contentsOf: folder.url.appendingPathComponent("iphone_motion.csv"), encoding: .utf8)
        XCTAssertEqual(csv.split(separator: "\n").count, 251)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.journalDirectory.path), "journal removed after recovery")
        XCTAssertTrue(store.recoverInterrupted(except: nil).isEmpty, "nothing left to recover")
    }

    func testRecoveryKeepsAJournalItCannotConvert() throws {
        let (folder, _) = try makeSession(status: .recording)
        try Data(repeating: 0xAB, count: 200).write(to: folder.journalDirectory.appendingPathComponent("iphone_motion.bin"))

        XCTAssertEqual(store.recoverInterrupted(except: nil).count, 1)

        let recovered = try XCTUnwrap(store.readManifest(at: folder.url))
        XCTAssertEqual(recovered.status, .interrupted)
        XCTAssertTrue(recovered.warnings.contains { $0.contains("iphone_motion.journal.bin") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.url.appendingPathComponent("iphone_motion.journal.bin").path))
        XCTAssertTrue(recovered.files.contains { $0.name == "iphone_motion.journal.bin" })
    }

    func testMarkDeletedSurvivesNewStoreInstances() throws {
        let sid = UUID()
        store.markDeleted(sid)
        let reopened = SessionStore(documents: root.appendingPathComponent("Documents"), support: root.appendingPathComponent("Support"))
        XCTAssertTrue(reopened.isDeleted(sid))
        XCTAssertFalse(reopened.isDeleted(UUID()))
    }

    func testActiveSessionIsNotRecovered() throws {
        let (_, manifest) = try makeSession(status: .recording)
        XCTAssertTrue(store.recoverInterrupted(except: manifest.sessionId).isEmpty)
    }
}
