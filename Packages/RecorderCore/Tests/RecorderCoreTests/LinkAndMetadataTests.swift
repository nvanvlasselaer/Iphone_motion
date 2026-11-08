//
//  LinkAndMetadataTests.swift
//  RecorderCoreTests
//

import XCTest
@testable import RecorderCore

final class LinkCodecTests: XCTestCase {
    private let sid = UUID()

    private var startCommand: StartCommand {
        StartCommand(
            folder: "2026-10-05_16-00-00_S01_T01", mode: .both, subject: "S01", trial: "T01",
            placement: .defaultWatch, sensors: .default, maxDurationS: 5400, waterLock: true
        )
    }

    private var status: WatchStatus {
        WatchStatus(
            phase: .recording, sid: sid, elapsedS: 12.5,
            motion: StreamProgress(count: 2500, hz: 199.9, gaps: 0),
            accel: StreamProgress(count: 10_000, hz: 800, gaps: 1),
            battery: 0.8, waterLock: true, batchLatencyS: 0.6, pendingTransfers: 2
        )
    }

    private var allMessages: [LinkMessage] {
        let device = DeviceInfo(modelIdentifier: "Watch7,5", systemName: "watchOS", systemVersion: "26.0.0", appVersion: "2.0 (1)", wristLocation: "left", crownOrientation: "right")
        return [
            .hello(HelloPayload(appVersion: "2.0 (1)")),
            .helloReply(HelloReplyPayload(
                device: device,
                capabilities: WatchCapabilities(batchedDeviceMotion: true, batchedAccelerometer: true, legacyReferenceFrames: ["xArbitraryZVertical"], waterLockSupported: true),
                authorization: WatchAuthorization(health: "authorized", motion: "authorized"),
                status: status, pendingSessions: [UUID()], freeBytes: 12_000_000_000, lowPowerMode: false
            )),
            .arm, .disarm,
            .start(startCommand),
            .stop(StopCommand(reason: "phone")),
            .ack(CommandAck(accepted: false, phase: .finalizing, error: "busy")),
            .ping(PingPayload(seq: 7, t1: 123.456, wantStatus: true)),
            .pong(PongPayload(seq: 7, t2: 5000.1, t3: 5000.2, status: status)),
            .step(StepNotice(stepId: "jumps_start", kind: .sync, haptic: .directionUp)),
            .marker(MarkerPayload(label: "stumble")),
            .endTrial,
            .file(FileInfo(kind: .motion, records: 1200, bytes: 110_416)),
            .ingestAck(IngestAckPayload(ok: true, kinds: [.manifest, .motion, .events])),
            .resend,
        ]
    }

    func testEveryMessageRoundTrips() throws {
        for message in allMessages {
            let envelope = Envelope(message, sid: sid)
            let decoded = try LinkCodec.decode(LinkCodec.encode(envelope))
            XCTAssertEqual(decoded, envelope, "\(message.type) did not round-trip")
        }
    }

    func testUnknownMessageTypeDecodes() throws {
        let json = #"{"v":1,"id":"\#(UUID().uuidString)","sent":1,"body":{"type":"futureFeature","payload":{"x":1}}}"#
        let envelope = try LinkCodec.decode(Data(json.utf8))
        XCTAssertEqual(envelope.body, .unknown("futureFeature"))
    }

    func testVersionMismatchIsReported() {
        let json = #"{"v":99,"id":"\#(UUID().uuidString)","sent":1,"body":{"type":"arm"}}"#
        XCTAssertThrowsError(try LinkCodec.decode(Data(json.utf8))) { error in
            XCTAssertEqual(error as? LinkError, .versionMismatch(99))
        }
    }

    func testUserInfoIsAPropertyList() throws {
        let envelope = Envelope(.file(FileInfo(kind: .accel)), sid: sid)
        let info = try LinkCodec.userInfo(envelope)
        XCTAssertNoThrow(try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0))
        XCTAssertEqual(try LinkCodec.envelope(from: info), envelope)
        XCTAssertNil(try LinkCodec.envelope(from: ["other": 1]))
    }
}

final class ManifestTests: XCTestCase {
    private func makeManifest() -> SessionManifest {
        let stats: StreamStats = {
            var s = StreamStats(nominalHz: 100)
            s.add(1); s.add(1.01); s.add(1.02)
            return s
        }()
        let iphone = DeviceSection(
            info: DeviceInfo(modelIdentifier: "iPhone16,1", systemName: "iOS", systemVersion: "26.6.2", appVersion: "2.0 (1)"),
            placement: .defaultIphone,
            anchorStart: ClockAnchor(uptimeS: 1, continuousS: 2, unixS: 3),
            anchorEnd: ClockAnchor(uptimeS: 4, continuousS: 5, unixS: 6),
            battery: BatteryInfo(start: 0.9, end: 0.85),
            guidedAccess: true,
            lowPowerMode: false,
            eventsFile: "iphone_events.csv",
            streams: [StreamInfo(kind: .motion, file: "iphone_motion.csv", sourceApi: "CMMotionManager.deviceMotion", requestedHz: 100, referenceFrame: "xArbitraryZVertical", dmStartUptimeS: 0.9, stats: stats, truncatedTailBytes: 0)]
        )
        let definition = ProtocolDefinition.knee(trialDurationS: 60, includeSeatedStatic: true)
        let sync = ClockSyncSummary(
            method: ClockSyncEstimator.method, refIphoneUptimeS: 1300, offsetS: 1234.5, driftPpm: 31.2, driftEstimated: true,
            residualRmsS: 0.001, maxAbsResidualS: 0.002, nPings: 160, nLost: 2, nUsed: 40, spanS: 600, minRttS: 0.041,
            windows: [ClockSyncSummary.Window(label: "start", midpointS: 1000, offsetS: 1234.49, minRttS: 0.041, used: 5, total: 20)]
        )
        return SessionManifest(
            sessionId: UUID(), folder: "2026-10-05_16-00-00_S01_T01", status: .awaitingWatchData, mode: .both,
            subject: "S01", trial: "T01", notes: "first test, outdoors",
            created: Timestamp(unixS: 1_791_216_000, timeZone: TimeZone(identifier: "Europe/Brussels")!),
            guidedProtocol: ProtocolRecord(definition: definition, instrumentedSide: .right, timeline: [ProtocolTimelineEntry(step: "static_start", windowStartUptimeS: 3, windowEndUptimeS: 8)], outcome: "complete"),
            devices: Devices(iphone: iphone, watch: nil),
            clockSync: sync,
            files: [FileEntry(name: "iphone_motion.csv", rows: 3, bytes: 900)],
            warnings: ["example warning"]
        )
    }

    func testSessionManifestRoundTripsWithSnakeCaseKeys() throws {
        let manifest = makeManifest()
        let data = try ManifestCoding.encoder().encode(manifest)
        let json = String(decoding: data, as: UTF8.self)
        for key in ["\"schema_version\"", "\"session_id\"", "\"awaiting_watch_data\"", "\"guided_protocol\"", "\"window_start_uptime_s\"",
                    "\"dm_start_uptime_s\"", "\"achieved_hz\"", "\"ref_iphone_uptime_s\"", "\"drift_ppm\"", "\"min_rtt_s\"",
                    "\"model_identifier\"", "\"anchor_start\"", "\"preset_id\"", "\"iso8601\"", "\"unix_s\""] {
            XCTAssertTrue(json.contains(key), "missing \(key)")
        }
        XCTAssertTrue(json.contains("2026-10-05T18:00:00"), "local ISO time with offset expected")
        let decoded = try ManifestCoding.decoder().decode(SessionManifest.self, from: data)
        XCTAssertEqual(decoded, manifest)
    }

    func testWatchManifestRoundTrips() throws {
        let section = DeviceSection(
            info: DeviceInfo(modelIdentifier: "Watch7,5", systemName: "watchOS", systemVersion: "26.0.0", appVersion: "2.0 (1)", wristLocation: "left", crownOrientation: "right"),
            placement: .defaultWatch,
            streams: [StreamInfo(kind: .accel, file: "watch_accel.bin", sourceApi: "CMBatchedSensorManager.accelerometer", reportedHz: 800)]
        )
        let manifest = WatchManifest(
            sessionId: UUID(),
            start: StartCommand(folder: "f", mode: .watch, subject: "S", trial: "T", placement: .defaultWatch, sensors: .default, maxDurationS: 60, waterLock: false),
            device: section, status: .complete, stopReason: "phone",
            files: [WatchFile(kind: .motion, name: "watch_motion.bin", records: 10, bytes: 936)],
            warnings: [], created: .now(), ended: .now()
        )
        let data = try ManifestCoding.encoder().encode(manifest)
        XCTAssertEqual(try ManifestCoding.decoder().decode(WatchManifest.self, from: data), manifest)
    }

    func testSettingsDecodeMissingKeysAsDefaults() throws {
        let partial = try JSONDecoder().decode(RecorderSettings.self, from: Data(#"{"subject":"P07","mode":"both"}"#.utf8))
        XCTAssertEqual(partial.subject, "P07")
        XCTAssertEqual(partial.mode, .both)
        XCTAssertEqual(partial.iphoneRateHz, 100)
        XCTAssertEqual(try JSONDecoder().decode(RecorderSettings.self, from: Data("{}".utf8)), RecorderSettings())

        var settings = RecorderSettings()
        settings.trialOpenEnded = true
        settings.watchPlacement.side = .left
        let decoded = try JSONDecoder().decode(RecorderSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
        XCTAssertNil(decoded.protocolDefinition.steps.first { $0.kind == .trial }?.durationS)
        XCTAssertEqual(decoded.instrumentedSide, .right, "iPhone-only mode uses the iPhone side")
    }
}

final class IngestPlannerTests: XCTestCase {
    private func manifest(kinds: [FileKind]) -> WatchManifest {
        WatchManifest(
            sessionId: UUID(), start: nil,
            device: DeviceSection(info: DeviceInfo(modelIdentifier: "W", systemName: "watchOS", systemVersion: "1", appVersion: "1"), placement: .defaultWatch),
            status: .complete, stopReason: "phone",
            files: kinds.map { WatchFile(kind: $0, name: $0.rawValue) },
            warnings: [], created: .now(), ended: nil
        )
    }

    func testWaitsForManifestFirst() {
        XCTAssertEqual(IngestPlanner.plan(manifest: nil, received: [.motion, .events], phoneSessionExists: true, phoneSessionDeleted: false), .waitForManifest)
    }

    func testWaitsForMissingFilesInAnyOrder() {
        let m = manifest(kinds: [.motion, .accel, .events])
        XCTAssertEqual(IngestPlanner.plan(manifest: m, received: [.manifest, .events], phoneSessionExists: true, phoneSessionDeleted: false), .waitForFiles([.motion, .accel]))
        XCTAssertEqual(IngestPlanner.plan(manifest: m, received: [.manifest, .accel, .events, .motion], phoneSessionExists: true, phoneSessionDeleted: false), .ingest(createFolder: false))
    }

    func testOrphanAndDeletedSessions() {
        let m = manifest(kinds: [.motion, .events])
        XCTAssertEqual(IngestPlanner.plan(manifest: m, received: [.manifest, .motion, .events], phoneSessionExists: false, phoneSessionDeleted: false), .ingest(createFolder: true))
        XCTAssertEqual(IngestPlanner.plan(manifest: nil, received: [.motion], phoneSessionExists: false, phoneSessionDeleted: true), .discard)
    }
}

final class PreflightTests: XCTestCase {
    private func input(mode: RecordingMode = .both, watch: WatchPreflight? = nil) -> PreflightInput {
        PreflightInput(
            mode: mode, deviceMotionAvailable: true, phoneFreeBytes: 50_000_000_000, phoneBattery: 0.9,
            phoneLowPowerMode: false, guidedAccess: true, pocketMode: true, voiceCues: true, outputVolume: 0.8,
            watch: watch
        )
    }

    private var readyWatch: WatchPreflight {
        WatchPreflight(paired: true, appInstalled: true, reachable: true, authorization: WatchAuthorization(health: "authorized", motion: "authorized"), freeBytes: 10_000_000_000, battery: 0.9, lowPowerMode: false, phase: .armed)
    }

    func testReadySetupHasNoErrors() {
        let items = Preflight.evaluate(input(watch: readyWatch))
        XCTAssertTrue(Preflight.canStart(items))
        XCTAssertTrue(items.isEmpty, "\(items)")
    }

    func testWatchProblemsBlockTheStart() {
        XCTAssertFalse(Preflight.canStart(Preflight.evaluate(input(watch: nil))))
        var watch = readyWatch
        watch.authorization = WatchAuthorization(health: "notDetermined", motion: "authorized")
        let items = Preflight.evaluate(input(watch: watch))
        XCTAssertFalse(Preflight.canStart(items))
        XCTAssertEqual(items.first?.id, "watch.auth")
        watch = readyWatch
        watch.phase = .finalizing
        XCTAssertTrue(Preflight.evaluate(input(watch: watch)).contains { $0.id == "watch.busy" })
        XCTAssertTrue(Preflight.canStart(Preflight.evaluate(input(mode: .iphone, watch: nil))), "watch is irrelevant in iPhone mode")
    }

    func testSpaceBatteryAndTips() {
        var i = input(mode: .iphone)
        i.phoneFreeBytes = 100_000_000
        XCTAssertFalse(Preflight.canStart(Preflight.evaluate(i)))
        i.phoneFreeBytes = 500_000_000
        i.phoneBattery = 0.1
        i.guidedAccess = false
        i.outputVolume = 0.1
        let items = Preflight.evaluate(i)
        XCTAssertTrue(Preflight.canStart(items))
        XCTAssertEqual(Set(items.map(\.id)), ["phone.space", "phone.battery", "phone.guidedaccess", "phone.volume"])
        XCTAssertEqual(items.last?.severity, .tip, "sorted most severe first")
    }
}
