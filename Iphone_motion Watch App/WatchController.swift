//
//  WatchController.swift
//  Iphone_motion Watch App
//
//  Executes the effects of `WatchStateMachine` (RecorderCore) in order and connects it to the
//  workout session, the sensors, the session files and the iPhone link.
//

import CoreMotion
import Foundation
import HealthKit
import Observation
import RecorderCore
import WatchKit

@MainActor
@Observable
final class WatchController {
    static let shared = WatchController()

    private(set) var phase: WatchPhase = .idle
    private(set) var sid: UUID?
    private(set) var recordingStartDate: Date?
    private(set) var stepId: String?
    private(set) var lastError: String?
    private(set) var healthStatus = "notDetermined"
    private(set) var motionStatus = "notDetermined"
    private(set) var phoneReachable = false
    private(set) var pendingSessions = 0
    private(set) var markerCount = 0

    @ObservationIgnored let recorder = WatchMotionRecorder()
    @ObservationIgnored private let link = WatchLink()
    @ObservationIgnored private let workout = WorkoutSessionManager()
    @ObservationIgnored private let store = WatchSessionStore()
    @ObservationIgnored private let statusBox = StatusBox()
    @ObservationIgnored private var machine = WatchStateMachine()
    @ObservationIgnored private var session: WatchSessionState?
    @ObservationIgnored private var events: EventLog?
    @ObservationIgnored private var timers: [WatchStateMachine.Timer: Task<Void, Never>] = [:]
    @ObservationIgnored private var batteryTask: Task<Void, Never>?
    @ObservationIgnored private var anchorTask: Task<Void, Never>?
    @ObservationIgnored private var pendingWaterLock = false
    @ObservationIgnored private var recordingStartUptime: Double?
    @ObservationIgnored private var lastResult: WatchRecorderResult?
    @ObservationIgnored private var started = false

    private init() {}

    var permissionsGranted: Bool {
        healthStatus == "authorized" && motionStatus == "authorized"
    }

    var isRecording: Bool {
        phase == .starting || phase == .recording || phase == .finalizing
    }

    var waterLockSupported: Bool {
        WKInterfaceDevice.current().waterResistanceRating == .wr50
    }

    // MARK: - Launch

    func start() {
        guard !started else { return }
        started = true
        store.prepare()
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = true

        let box = statusBox
        let recorder = recorder
        link.statusProvider = { @Sendable in WatchController.status(box: box, recorder: recorder) }
        link.onRequest = { [weak self] envelope, reply in self?.handleRequest(envelope, reply: reply) }
        link.onMessage = { [weak self] envelope in self?.handleMessage(envelope) }
        link.onTransferFinished = { [weak self] sid, kind, error in self?.transferFinished(sid: sid, kind: kind, error: error) }
        link.onReachability = { [weak self] reachable in
            self?.phoneReachable = reachable
            self?.resumeTransfers()
        }
        workout.onUnexpectedEnd = { [weak self] message in
            self?.events?.log("workout_failed", detail: message)
            self?.apply(.workoutFailed(message))
        }
        recorder.onFirstSamples = { [weak self] in self?.apply(.firstSamples) }

        link.activate()
        refreshAuthorization()
        finalizeLeftoverSessions()
        publishStatus()
    }

    func launchedForWorkout() {
        start()
        apply(.launched)
    }

    func recoverAfterCrash() {
        start()
        Task { await workout.recoverAndEnd() }
    }

    func applicationDidBecomeActive() {
        refreshAuthorization()
        applyWaterLockIfPossible()
        publishStatus()
    }

    // MARK: - Permissions

    func requestPermissions() async {
        do {
            try await workout.requestAuthorization()
        } catch {
            lastError = "Health: \(error.localizedDescription)"
        }
        if CMMotionActivityManager.isActivityAvailable() {
            let manager = CMMotionActivityManager()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                manager.queryActivityStarting(from: Date().addingTimeInterval(-60), to: Date(), to: .main) { _, _ in
                    continuation.resume()
                }
            }
        }
        refreshAuthorization()
        publishStatus()
    }

    private func refreshAuthorization() {
        healthStatus = workout.authorizationStatus
        switch CMMotionActivityManager.authorizationStatus() {
        case .authorized: motionStatus = "authorized"
        case .denied: motionStatus = "denied"
        case .restricted: motionStatus = "restricted"
        default: motionStatus = "notDetermined"
        }
    }

    // MARK: - Buttons on the Watch

    func addMarker() {
        guard isRecording else { return }
        markerCount += 1
        let label = "W\(markerCount)"
        events?.log("marker", detail: "watch: \(label)")
        link.send(.marker(MarkerPayload(label: label)), sid: sid)
    }

    func endTrial() {
        guard isRecording else { return }
        events?.log("end_trial_pressed")
        link.send(.endTrial, sid: sid)
    }

    func stopLocally() {
        apply(.localStop)
    }

    func lockScreen() {
        pendingWaterLock = true
        applyWaterLockIfPossible()
    }

    func resendPending() {
        for state in store.pending() where canTransfer(state.sid) {
            link.cancelTransfers(for: state.sid)
            enqueueTransfers(state.sid)
        }
    }

    // MARK: - Messages from the iPhone

    private func handleRequest(_ envelope: Envelope, reply: @escaping (Envelope) -> Void) {
        let ack: (CommandAck) -> Void = { reply(Envelope(.ack($0), sid: envelope.sid)) }
        switch envelope.body {
        case .hello:
            refreshAuthorization()
            reply(Envelope(.helloReply(helloPayload())))
        case .arm:
            apply(.armCommand, reply: ack)
        case .disarm:
            apply(.disarmCommand, reply: ack)
        case .start(let command):
            handleStart(command, sid: envelope.sid, ack: ack)
        case .stop(let command):
            events?.log("command_received", detail: "stop (\(command.reason))")
            apply(.stopCommand(sid: envelope.sid, reason: command.reason), reply: ack)
        default:
            ack(CommandAck(accepted: false, phase: phase, error: "unsupported request \(envelope.body.type)"))
        }
    }

    private func handleMessage(_ envelope: Envelope) {
        switch envelope.body {
        case .step(let notice):
            stepId = notice.stepId
            events?.log("step_received", step: notice.stepId, detail: notice.kind.rawValue)
            if let haptic = notice.haptic {
                WKInterfaceDevice.current().play(haptic.watchHaptic)
                events?.log("haptic_played", step: notice.stepId, detail: haptic.rawValue)
            }
        case .marker(let marker):
            events?.log("marker", detail: "phone: \(marker.label)")
        case .stop(let command):
            events?.log("command_received", detail: "stop, queued (\(command.reason))")
            apply(.stopCommand(sid: envelope.sid, reason: command.reason))
        case .disarm:
            apply(.disarmCommand)
        case .ingestAck(let ack):
            if ack.ok, let sid = envelope.sid {
                store.delete(sid)
                refreshPending()
            }
        case .resend:
            if let sid = envelope.sid, canTransfer(sid) {
                link.cancelTransfers(for: sid)
                enqueueTransfers(sid)
            }
        default:
            break
        }
    }

    private func handleStart(_ command: StartCommand, sid: UUID?, ack: @escaping (CommandAck) -> Void) {
        guard let sid else {
            ack(CommandAck(accepted: false, phase: phase, error: "missing session id"))
            return
        }
        // Retries of the current session and starts while busy are answered by the state machine.
        if machine.sid == sid || isRecording {
            apply(.startCommand(sid: sid, maxDurationS: command.maxDurationS), reply: ack)
            return
        }
        guard permissionsGranted else {
            ack(CommandAck(accepted: false, phase: phase, error: "Health or Motion access is not granted on the Watch"))
            return
        }
        do {
            let device = DeviceSection(
                info: currentDeviceInfo(),
                placement: command.placement,
                battery: BatteryInfo(start: battery),
                lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                eventsFile: FileKind.events.watchFileName
            )
            let state = WatchSessionState(sid: sid, command: command, phase: .recording, created: .now(), device: device)
            try store.create(state)
            events = try EventLog(url: store.url(.events, sid: sid), attributes: WatchSessionStore.protection)
            session = state
            markerCount = 0
            stepId = nil
            lastError = nil
            events?.log("command_received", detail: "start \(command.folder)")
        } catch {
            ack(CommandAck(accepted: false, phase: phase, error: "cannot create the session files: \(error.localizedDescription)"))
            return
        }
        apply(.startCommand(sid: sid, maxDurationS: command.maxDurationS), reply: ack)
    }

    // MARK: - State machine

    private func apply(_ event: WatchStateMachine.Event, reply: ((CommandAck) -> Void)? = nil) {
        let effects = machine.handle(event, now: MonotonicClock.uptime())
        phase = machine.phase
        sid = machine.sid
        var replied = false
        for effect in effects {
            switch effect {
            case .startWorkout:
                startWorkout()
            case .endWorkout:
                workout.end()
            case .startSensors(let id):
                startSensors(id)
            case .stopSensors(let drainUntil):
                drain(until: drainUntil)
            case .finalize(let id, let reason, let interrupted):
                finalize(id, reason: reason, interrupted: interrupted)
            case .enqueueTransfers(let id):
                enqueueTransfers(id)
            case .schedule(let timer, let at):
                schedule(timer, at: at)
            case .cancel(let timer):
                timers[timer]?.cancel()
                timers[timer] = nil
            case .reply(let accepted, let error):
                if let reply, !replied {
                    replied = true
                    reply(CommandAck(accepted: accepted, phase: machine.phase, error: error))
                }
            case .log(let name, let detail):
                events?.log(name, detail: detail)
            }
        }
        if let reply, !replied {
            reply(CommandAck(accepted: true, phase: machine.phase))
        }
        publishStatus()
    }

    private func startWorkout() {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.workout.start()
                self.events?.log("workout_started")
                self.apply(.workoutRunning)
            } catch {
                self.lastError = "Workout: \(error.localizedDescription)"
                self.events?.log("workout_failed", detail: error.localizedDescription)
                self.apply(.workoutFailed(error.localizedDescription))
            }
        }
    }

    private func startSensors(_ id: UUID) {
        guard var state = session, state.sid == id else { return }
        do {
            let streams = try recorder.start(
                config: state.command.sensors,
                motionURL: store.url(.motion, sid: id),
                accelURL: store.url(.accel, sid: id),
                attributes: WatchSessionStore.protection
            )
            state.device.streams = streams
            state.device.anchorStart = .now()
            session = state
            try? store.save(state)
            recordingStartUptime = MonotonicClock.uptime()
            recordingStartDate = Date()
            events?.log("sensors_started", detail: streams.map { "\($0.sourceApi) \(Int($0.reportedHz ?? $0.requestedHz ?? 0)) Hz" }.joined(separator: "; "))
            pendingWaterLock = state.command.waterLock
            applyWaterLockIfPossible()
            startBatteryWatch()
            startAnchorTimer()
        } catch {
            let message = "Could not start the sensors: \(error.localizedDescription)"
            lastError = message
            events?.log("sensor_error", detail: message)
            // Let the command being handled finish (its reply reports this session), then stop it
            // as interrupted; the iPhone sees the error in the next status.
            Task { [weak self] in self?.apply(.workoutFailed(message)) }
        }
    }

    private func drain(until drainUntil: Double) {
        Task { [weak self] in
            guard let self else { return }
            self.lastResult = await self.recorder.stop(drainUntil: drainUntil)
            self.apply(.drained)
        }
    }

    private func finalize(_ id: UUID, reason: String, interrupted: Bool) {
        guard var state = session, state.sid == id else { return }
        batteryTask?.cancel()
        anchorTask?.cancel()
        pendingWaterLock = false
        state.device.anchorEnd = .now()
        state.device.battery.end = battery
        state.device.streams = state.device.streams.map { stream in
            var updated = stream
            updated.stats = stream.kind == .motion ? lastResult?.motion : lastResult?.accel
            return updated
        }
        var warnings: [String] = []
        if let error = lastResult?.error {
            warnings.append("Sensor or storage error: \(error)")
        }
        if interrupted, let lastError {
            warnings.append(lastError)
        }
        events?.log("recording_end", detail: reason)
        events?.close()
        events = nil

        let files = store.files(for: id).filter { $0.0 != .manifest }.map { kind, url in
            WatchFile(
                kind: kind, name: url.lastPathComponent,
                records: kind == .motion ? lastResult?.motion?.count : (kind == .accel ? lastResult?.accel?.count : nil),
                bytes: store.fileSize(url)
            )
        }
        let manifest = WatchManifest(
            sessionId: id, start: state.command, device: state.device,
            status: interrupted ? .interrupted : .complete, stopReason: reason,
            files: files, warnings: warnings, created: state.created, ended: .now()
        )
        try? ManifestCoding.write(manifest, to: store.url(.manifest, sid: id))
        // Transfers of half-written files (e.g. an early resend request) must not count.
        link.cancelTransfers(for: id)
        state.sentKinds = []
        state.transferAttempts = 0
        state.phase = .finalized
        try? store.save(state)
        session = nil
        recordingStartUptime = nil
        recordingStartDate = nil
        stepId = nil
        lastResult = nil
        refreshPending()
    }

    private func schedule(_ timer: WatchStateMachine.Timer, at: Double) {
        timers[timer]?.cancel()
        timers[timer] = Task { [weak self] in
            let delay = max(0, at - MonotonicClock.uptime())
            try? await Task.sleep(nanoseconds: UInt64(delay * 1e9))
            guard !Task.isCancelled, let self else { return }
            self.timers[timer] = nil
            self.apply(.timerFired(timer))
        }
    }

    private func startBatteryWatch() {
        batteryTask?.cancel()
        batteryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.publishStatus()
                if let level = self.battery, level < 0.05, self.phase == .recording {
                    self.events?.log("low_battery", detail: FixedPoint.string(Double(level), decimals: 2))
                    self.apply(.lowBattery)
                }
            }
        }
    }

    /// Logs the three clocks every 10 s, so pauses or sleep show up in the events file.
    private func startAnchorTimer() {
        anchorTask?.cancel()
        anchorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.events?.log("clock_anchor")
            }
        }
    }

    private func applyWaterLockIfPossible() {
        guard pendingWaterLock, phase == .starting || phase == .recording, workout.isRunning else { return }
        guard waterLockSupported else {
            pendingWaterLock = false
            return
        }
        guard WKApplication.shared().applicationState == .active else { return }
        WKInterfaceDevice.current().enableWaterLock()
        pendingWaterLock = false
        events?.log("water_lock", detail: "enabled")
        publishStatus()
    }

    // MARK: - Transfers

    /// Only complete sessions are sent: never the one being recorded.
    private func canTransfer(_ id: UUID) -> Bool {
        id != machine.sid && store.load(id)?.phase == .finalized
    }

    private func enqueueTransfers(_ id: UUID, kinds: [FileKind]? = nil) {
        guard canTransfer(id) else { return }
        let outstanding = Set(link.outstandingTransfers().filter { $0.0 == id }.map(\.1))
        for (kind, url) in store.files(for: id) where (kinds?.contains(kind) ?? true) && !outstanding.contains(kind) {
            link.transfer(file: url, info: FileInfo(kind: kind, bytes: store.fileSize(url)), sid: id)
        }
    }

    private func transferFinished(sid: UUID, kind: FileKind, error: Error?) {
        guard var state = store.load(sid) else { return }
        if error != nil {
            state.transferAttempts += 1
            try? store.save(state)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                self?.enqueueTransfers(sid, kinds: [kind])
            }
        } else if !state.sentKinds.contains(kind) {
            state.sentKinds.append(kind)
            try? store.save(state)
        }
        refreshPending()
    }

    /// Re-queues files of finished sessions that were neither delivered nor are being transferred.
    private func resumeTransfers() {
        let outstanding = link.outstandingTransfers()
        for state in store.pending() {
            let missing = store.files(for: state.sid).map(\.0).filter { kind in
                !state.sentKinds.contains(kind) && !outstanding.contains { $0.0 == state.sid && $0.1 == kind }
            }
            if !missing.isEmpty {
                enqueueTransfers(state.sid, kinds: missing)
            }
        }
    }

    /// Sessions left in "recording" by a crash or a kill: close them as interrupted.
    private func finalizeLeftoverSessions() {
        for var state in store.all() where state.phase == .recording && state.sid != machine.sid {
            let files = store.files(for: state.sid).filter { $0.0 != .manifest }.map { kind, url in
                WatchFile(kind: kind, name: url.lastPathComponent, bytes: store.fileSize(url))
            }
            let manifest = WatchManifest(
                sessionId: state.sid, start: state.command, device: state.device,
                status: .interrupted, stopReason: "watch_app_stopped",
                files: files,
                warnings: ["The Watch app stopped during the recording; the data up to that moment is included."],
                created: state.created, ended: nil
            )
            try? ManifestCoding.write(manifest, to: store.url(.manifest, sid: state.sid))
            state.phase = .finalized
            try? store.save(state)
        }
        refreshPending()
    }

    private func refreshPending() {
        pendingSessions = store.pending().count
        publishStatus()
    }

    // MARK: - Status

    private var battery: Float? {
        let level = WKInterfaceDevice.current().batteryLevel
        return level >= 0 ? level : nil
    }

    private func publishStatus() {
        statusBox.set(
            WatchStatus(
                phase: phase, sid: sid, battery: battery,
                waterLock: WKInterfaceDevice.current().isWaterLockEnabled,
                lastError: lastError, pendingTransfers: pendingSessions
            ),
            startUptime: recordingStartUptime
        )
    }

    nonisolated static func status(box: StatusBox, recorder: WatchMotionRecorder) -> WatchStatus {
        var (status, startUptime) = box.get()
        let snapshot = recorder.snapshot()
        if let motion = snapshot.motion {
            status.motion = StreamProgress(count: motion.count, hz: motion.achievedHz, gaps: motion.gapCount)
        }
        if let accel = snapshot.accel {
            status.accel = StreamProgress(count: accel.count, hz: accel.achievedHz, gaps: accel.gapCount)
        }
        status.batchLatencyS = snapshot.batchLatency
        status.lastError = status.lastError ?? snapshot.lastError
        if let startUptime {
            status.elapsedS = MonotonicClock.uptime() - startUptime
        }
        return status
    }

    private func helloPayload() -> HelloReplyPayload {
        publishStatus()
        return HelloReplyPayload(
            device: currentDeviceInfo(),
            capabilities: WatchCapabilities(
                batchedDeviceMotion: WatchMotionRecorder.batchedDeviceMotionSupported,
                batchedAccelerometer: WatchMotionRecorder.batchedAccelerometerSupported,
                legacyReferenceFrames: ReferenceFrames.availableNames(),
                waterLockSupported: waterLockSupported
            ),
            authorization: WatchAuthorization(health: healthStatus, motion: motionStatus),
            status: Self.status(box: statusBox, recorder: recorder),
            pendingSessions: store.pending().map(\.sid),
            freeBytes: store.freeBytes,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }

    private func currentDeviceInfo() -> DeviceInfo {
        var info = DeviceInfo.current()
        let device = WKInterfaceDevice.current()
        info.wristLocation = device.wristLocation == .left ? "left" : "right"
        info.crownOrientation = device.crownOrientation == .left ? "left" : "right"
        return info
    }
}

private extension HapticKind {
    var watchHaptic: WKHapticType {
        switch self {
        case .start: return .start
        case .stop: return .stop
        case .directionUp: return .directionUp
        case .success: return .success
        case .notification: return .notification
        case .click: return .click
        }
    }
}
