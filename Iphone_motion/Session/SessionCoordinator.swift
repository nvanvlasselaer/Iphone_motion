//
//  SessionCoordinator.swift
//  Iphone_motion
//
//  Orchestrates a recording session in iPhone, Watch or Both mode:
//  preflight → session folder → Watch start command → iPhone sensors → Watch confirmation and
//  clock-sync burst → guided protocol → (trial end: end burst) → stop → conversion → session.json.
//

import AVFoundation
import Foundation
import Observation
import RecorderCore
import UIKit

/// Mutable state of the session being recorded (not shown directly in the UI).
@MainActor
final class RecordingContext {
    let sid: UUID
    let folder: SessionFolder
    let settings: RecorderSettings
    let events: EventLog
    var manifest: SessionManifest
    var sync: ClockSyncController?
    var anchorTask: Task<Void, Never>?
    var watchTask: Task<Void, Never>?
    var endBurstTask: Task<Void, Never>?
    var lastWatchContact: Double
    var linkLost = false
    var watchStopNoticed = false

    init(sid: UUID, folder: SessionFolder, settings: RecorderSettings, events: EventLog, manifest: SessionManifest) {
        self.sid = sid
        self.folder = folder
        self.settings = settings
        self.events = events
        self.manifest = manifest
        self.lastWatchContact = MonotonicClock.uptime()
    }
}

@MainActor
@Observable
final class SessionCoordinator {
    enum Phase: Equatable {
        case idle
        case starting
        case recording
        case stopping
    }

    struct WatchState: Equatable {
        var supported = false
        var paired = false
        var installed = false
        var reachable = false
        var connecting = false
        var hello: HelloReplyPayload?
        var status: WatchStatus?
        var lastContactUptime: Double?
        var message: String?
    }

    struct RecordingInfo: Equatable {
        let sid: UUID
        let folderName: String
        let mode: RecordingMode
        let startDate: Date
        var watchConfirmed = false
        var markerCount = 0
    }

    private(set) var phase: Phase = .idle
    private(set) var watch = WatchState()
    private(set) var recording: RecordingInfo?
    private(set) var preview = RingBuffer<PreviewSample>(capacity: 200)
    private(set) var preflight: [PreflightItem] = []
    /// Incremented whenever the list of sessions on disk changes.
    private(set) var sessionsVersion = 0
    var alertMessage: String?

    @ObservationIgnored private unowned let env: AppEnvironment
    @ObservationIgnored private var context: RecordingContext?
    @ObservationIgnored private var bootstrapped = false
    @ObservationIgnored private var recordTabVisible = false
    /// Watch files are ingested only after interrupted sessions were recovered at launch.
    @ObservationIgnored private var recoveryFinished = false

    init(environment: AppEnvironment) {
        env = environment
    }

    var isBusy: Bool { phase != .idle }

    var watchHasOrphanRecording: Bool {
        guard let status = watch.status, let sid = status.sid else { return false }
        let active = status.phase == .recording || status.phase == .starting
        return active && sid != recording?.sid
    }

    // MARK: - Setup

    func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true

        env.link.onState = { [weak self] state in self?.updateLinkState(state) }
        env.link.onEnvelope = { [weak self] envelope in self?.receive(envelope) }
        env.link.onFileReceived = { [weak self] _ in self?.processInbox() }
        env.ingestor.isBusy = { [weak self] sid in self?.context?.sid == sid }
        env.ingestor.onChange = { [weak self] in self?.sessionsVersion += 1 }
        env.speech.onStart = { [weak self] token in self?.env.runner.send(.cueStarted(token: token)) }
        env.speech.onFinish = { [weak self] token in self?.env.runner.send(.cueFinished(token: token)) }
        env.pocket.onEvent = { [weak self] event, detail in self?.context?.events.log(event, detail: detail) }

        let lifecycle = env.lifecycle
        lifecycle.onEvent = { [weak self] event, detail in self?.context?.events.log(event, detail: detail) }
        lifecycle.onActive = { [weak self] in self?.appDidBecomeActive() }
        lifecycle.onResignActive = { [weak self] in self?.env.pocket.appDidResignActive() }
        lifecycle.onBackground = { [weak self] in self?.appDidEnterBackground() }
        lifecycle.onForeground = { [weak self] in self?.appWillEnterForeground() }
        lifecycle.start()

        UIDevice.current.isBatteryMonitoringEnabled = true
        updateLinkState(env.link.state)

        let store = env.store
        Task { [weak self] in
            let recovered = await Task.detached(priority: .utility) {
                store.recoverInterrupted(except: nil)
            }.value
            guard let self else { return }
            self.recoveryFinished = true
            if !recovered.isEmpty {
                self.sessionsVersion += 1
                self.alertMessage = "Recovered \(recovered.count) session(s) interrupted by an app stop: \(recovered.joined(separator: ", "))."
            }
            self.processInbox()
        }
    }

    // MARK: - Record tab

    func recordTabAppeared() {
        recordTabVisible = true
        startPreviewIfNeeded()
        env.speech.warmUp()
        refreshPreflight()
        if env.settings.value.mode.usesWatch && watch.reachable && phase == .idle {
            Task { await hello() }
        }
    }

    func recordTabDisappeared() {
        recordTabVisible = false
        if phase == .idle {
            env.recorder.stopPreview()
        }
    }

    func settingsChanged() {
        if phase == .idle {
            startPreviewIfNeeded()
        }
        refreshPreflight()
    }

    private func startPreviewIfNeeded() {
        let settings = env.settings.value
        guard recordTabVisible || phase != .idle, settings.mode.usesIphone else {
            if phase == .idle {
                env.recorder.stopPreview()
                preview.removeAll()
            }
            return
        }
        env.recorder.startPreview(rateHz: settings.iphoneRateHz, frameName: settings.iphoneReferenceFrame) { [weak self] batch in
            guard let self else { return }
            for sample in batch {
                self.preview.append(sample)
            }
        }
    }

    func refreshPreflight() {
        let settings = env.settings.value
        let watchPreflight = settings.mode.usesWatch ? WatchPreflight(
            paired: watch.paired,
            appInstalled: watch.installed,
            reachable: watch.reachable,
            authorization: watch.hello?.authorization,
            freeBytes: watch.hello?.freeBytes,
            battery: watch.status?.battery ?? watch.hello?.status.battery,
            lowPowerMode: watch.hello?.lowPowerMode ?? false,
            phase: watch.status?.phase
        ) : nil
        preflight = Preflight.evaluate(PreflightInput(
            mode: settings.mode,
            deviceMotionAvailable: env.recorder.isDeviceMotionAvailable,
            phoneFreeBytes: Self.freeBytes(),
            phoneBattery: Self.batteryLevel(),
            phoneLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            guidedAccess: UIAccessibility.isGuidedAccessEnabled,
            pocketMode: settings.pocketMode,
            voiceCues: settings.guidedProtocol && settings.voiceCues,
            outputVolume: AVAudioSession.sharedInstance().outputVolume,
            watch: watchPreflight
        ))
    }

    // MARK: - Watch connection

    func connectWatch() async {
        guard watch.supported else {
            watch.message = "This device cannot be paired with an Apple Watch."
            return
        }
        guard watch.paired else {
            watch.message = "No Apple Watch is paired with this iPhone."
            return
        }
        guard watch.installed else {
            watch.message = "Install the app on the Watch first: Watch app on iPhone ▸ Available Apps."
            return
        }
        watch.connecting = true
        watch.message = nil
        defer {
            watch.connecting = false
            refreshPreflight()
        }
        do {
            try await env.launcher.ensureAuthorization()
        } catch {
            watch.message = "Health permission on iPhone: \(Self.describe(error))"
        }
        var launched = true
        do {
            try await env.launcher.launch()
        } catch {
            launched = false
            watch.message = "Could not launch the Watch app (\(Self.describe(error))). Open it on the Watch."
        }
        guard await env.link.waitForReachability(timeout: 15) else {
            if watch.message == nil {
                watch.message = "The Watch app did not respond. Open it on the Watch and tap Connect again."
            }
            return
        }
        if !launched {
            // Already open on the Watch: ask it to start its workout session directly.
            _ = try? await env.link.request(.arm, sid: nil)
        }
        await hello()
    }

    func hello() async {
        do {
            let reply = try await env.link.requestWithRetry(.hello(HelloPayload(appVersion: DeviceInfo.appVersion())), sid: nil, attempts: 2)
            guard case .helloReply(let payload) = reply.body else {
                throw LinkError.unexpectedReply(reply.body.type)
            }
            watch.hello = payload
            watch.status = payload.status
            watch.lastContactUptime = MonotonicClock.uptime()
            watch.message = payload.authorization.isReady ? nil : "Open the app on the Watch and allow Health and Motion access."
        } catch {
            watch.message = Self.describe(error)
        }
        refreshPreflight()
    }

    /// Stops a Watch recording the iPhone no longer controls (e.g. after the iPhone app was killed).
    func stopOrphanWatchRecording() async {
        guard let sid = watch.status?.sid else { return }
        let stop = LinkMessage.stop(StopCommand(reason: "phone_recovery"))
        do {
            _ = try await env.link.requestWithRetry(stop, sid: sid)
        } catch {
            env.link.enqueue(stop, sid: sid)
        }
        await hello()
    }

    /// Asks the Watch to send the files of a session again.
    func requestResend(sid: UUID) {
        env.link.send(.resend, sid: sid, queueIfUnreachable: true)
    }

    private func updateLinkState(_ state: PhoneLink.State) {
        let wasReachable = watch.reachable
        watch.supported = state.supported
        watch.paired = state.paired
        watch.installed = state.installed
        watch.reachable = state.reachable
        if let context, context.settings.mode.usesWatch, wasReachable != state.reachable {
            context.events.log("watch_link", detail: state.reachable ? "reachable" : "unreachable")
        }
        if state.activated {
            processInbox()
        }
        if !wasReachable && state.reachable && phase == .idle && env.settings.value.mode.usesWatch {
            Task { await hello() }
        }
        refreshPreflight()
    }

    private func receive(_ envelope: Envelope) {
        guard let context, envelope.sid == context.sid else { return }
        switch envelope.body {
        case .endTrial:
            context.events.log("end_trial_pressed", detail: "watch")
            env.runner.send(.advance(source: "watch"))
        case .marker(let marker):
            context.events.log("marker", detail: "watch: \(marker.label)")
        default:
            break
        }
    }

    // MARK: - Start

    func start() async {
        guard phase == .idle else { return }
        refreshPreflight()
        guard Preflight.canStart(preflight) else {
            alertMessage = preflight.filter { $0.severity == .error }.map(\.message).joined(separator: "\n")
            return
        }
        let settings = env.settings.value
        phase = .starting
        UIApplication.shared.isIdleTimerDisabled = true

        let sid = UUID()
        let startDate = Date()
        let name = SessionNaming.uniqued(
            SessionNaming.folderName(start: startDate, subject: settings.subject, trial: settings.trial),
            existing: env.store.existingNames()
        )
        let context: RecordingContext
        do {
            let folder = try env.store.create(name: name, sid: sid)
            let events = try EventLog(url: folder.url.appendingPathComponent("iphone_events.csv"), attributes: SessionStore.protection)
            var manifest = SessionManifest(
                sessionId: sid, folder: name, status: .recording, mode: settings.mode,
                subject: settings.subject, trial: settings.trial, notes: settings.notes,
                created: Timestamp(unixS: startDate.timeIntervalSince1970)
            )
            manifest.devices.iphone = DeviceSection(
                info: DeviceInfo.current(),
                placement: settings.mode.usesIphone
                    ? settings.iphonePlacement
                    : Placement(segment: .other, side: .center, site: "not worn (controller)", orientation: ""),
                anchorStart: .now(),
                battery: BatteryInfo(start: Self.batteryLevel()),
                guidedAccess: UIAccessibility.isGuidedAccessEnabled,
                lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                eventsFile: "iphone_events.csv"
            )
            if settings.guidedProtocol {
                manifest.guidedProtocol = ProtocolRecord(definition: settings.protocolDefinition, instrumentedSide: settings.instrumentedSide)
            }
            try env.store.writeManifest(manifest, to: folder.url)
            env.store.copyDataFormat(to: folder.url)
            context = RecordingContext(sid: sid, folder: folder, settings: settings, events: events, manifest: manifest)
        } catch {
            phase = .idle
            alertMessage = "Could not create the session folder: \(error.localizedDescription)"
            return
        }
        self.context = context
        context.events.log("session_created", detail: "\(settings.mode.rawValue) \(name)")

        // 1. Watch: start command (the Watch creates its files and starts its sensors).
        if settings.mode.usesWatch {
            do {
                let sync = try ClockSyncController(link: env.link, csvURL: context.folder.url.appendingPathComponent("clock_sync.csv"))
                sync.onPing = { [weak self, weak context] ping, status in
                    guard let self, let context else { return }
                    self.handlePing(ping, status: status, context: context)
                }
                context.sync = sync
                let command = StartCommand(
                    folder: name, mode: settings.mode, subject: settings.subject, trial: settings.trial,
                    placement: settings.watchPlacement, sensors: settings.watchSensors,
                    maxDurationS: settings.maxDurationMin * 60, waterLock: settings.waterLock
                )
                let reply = try await env.link.requestWithRetry(.start(command), sid: sid)
                guard case .ack(let ack) = reply.body else { throw LinkError.unexpectedReply(reply.body.type) }
                guard ack.accepted, ack.phase == .starting || ack.phase == .recording else {
                    throw LinkError.rejected(ack.error ?? "the Watch is \(ack.phase.rawValue)")
                }
                context.events.log("watch_command", detail: "start accepted")
            } catch {
                context.events.log("watch_command", detail: "start failed: \(Self.describe(error))")
                env.link.send(.stop(StopCommand(reason: "phone_start_failed")), sid: sid, queueIfUnreachable: true)
                abandon(context, message: "The Watch did not start recording: \(Self.describe(error))\n\nCheck the Watch, or switch to iPhone mode.")
                return
            }
        }

        // 2. iPhone sensors (device motion restarts: heading reference = now).
        if settings.mode.usesIphone {
            do {
                let start = try env.recorder.beginRecording(
                    journalURL: context.folder.journalDirectory.appendingPathComponent("iphone_motion.bin"),
                    rateHz: settings.iphoneRateHz,
                    frameName: settings.iphoneReferenceFrame,
                    attributes: SessionStore.protection
                )
                context.manifest.devices.iphone?.streams = [StreamInfo(
                    kind: .motion, file: "iphone_motion.csv", sourceApi: "CMMotionManager.deviceMotion",
                    requestedHz: start.rateHz, referenceFrame: start.referenceFrame, dmStartUptimeS: start.dmStartUptime
                )]
                context.events.log("recording_start", detail: "iphone \(start.referenceFrame) \(Int(start.rateHz)) Hz")
            } catch {
                if settings.mode.usesWatch {
                    env.link.send(.stop(StopCommand(reason: "phone_failed")), sid: sid, queueIfUnreachable: true)
                }
                abandon(context, message: "Could not start the iPhone sensors: \(error.localizedDescription)")
                return
            }
        }
        try? env.store.writeManifest(context.manifest, to: context.folder.url)

        recording = RecordingInfo(sid: sid, folderName: name, mode: settings.mode, startDate: startDate)
        phase = .recording
        startAnchorTimer(context)
        if settings.mode.usesIphone && settings.pocketMode {
            env.pocket.engage(proximity: settings.proximityBlanking, dim: settings.dimScreen)
        }
        if settings.guidedProtocol && settings.voiceCues {
            env.speech.activateAudio()
        }

        // 3. Wait until the Watch delivers data, sync clocks, then guide.
        if settings.mode.usesWatch {
            context.watchTask = Task { [weak self] in
                guard let self else { return }
                let confirmation = await self.waitForWatchRecording(context, timeout: 8)
                guard self.context === context, self.phase == .recording else { return }
                switch confirmation {
                case .recording:
                    break
                case .failed(let reason):
                    context.events.log("watch_status", detail: "the Watch could not start recording: \(reason)")
                    context.manifest.warnings.append("The Watch could not start recording: \(reason).")
                    if context.settings.mode == .watch {
                        self.alertMessage = "The Watch could not start recording (\(reason)). The session was stopped."
                        await self.stop(reason: "watch_failed")
                        return
                    }
                    self.alertMessage = "The Watch could not start recording (\(reason)). The iPhone keeps recording."
                case .unconfirmed:
                    context.events.log("watch_status", detail: "recording not confirmed within 8 s")
                    context.manifest.warnings.append("The Watch did not confirm it was recording within 8 s after the start.")
                    self.alertMessage = "The Watch has not confirmed it is recording. Check the Watch."
                }
                self.startProtocolIfNeeded(context)
                await context.sync?.burst(.start)
                if self.context === context, self.phase == .recording, context.endBurstTask == nil {
                    context.sync?.startPeriodic()
                }
            }
        } else {
            startProtocolIfNeeded(context)
        }
    }

    private enum WatchConfirmation {
        case recording
        case failed(String)
        case unconfirmed
    }

    private func waitForWatchRecording(_ context: RecordingContext, timeout: Double) async -> WatchConfirmation {
        guard let sync = context.sync else { return .unconfirmed }
        let deadline = MonotonicClock.uptime() + timeout
        while MonotonicClock.uptime() < deadline && !Task.isCancelled {
            let (_, status) = await sync.pingOnce(burst: .periodic, wantStatus: true)
            if let status {
                if status.sid == context.sid, status.phase == .recording, (status.motion?.count ?? 0) > 0 {
                    return .recording
                }
                let stopped = status.phase == .idle || (status.phase == .finalizing && status.sid == context.sid)
                if stopped, let error = status.lastError {
                    return .failed(error)
                }
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return .unconfirmed
    }

    private func handlePing(_ ping: PingSample, status: WatchStatus?, context: RecordingContext) {
        guard self.context === context else { return }
        let now = MonotonicClock.uptime()
        if ping.status == .ok {
            context.lastWatchContact = now
            watch.lastContactUptime = now
            if context.linkLost {
                context.linkLost = false
                context.events.log("watch_link", detail: "replies restored")
            }
        } else if !context.linkLost && now - context.lastWatchContact > 30 {
            context.linkLost = true
            context.events.log("watch_link", detail: "no reply for 30 s (the Watch keeps recording)")
        }
        guard let status else { return }
        watch.status = status
        if status.phase == .recording && status.sid == context.sid {
            recording?.watchConfirmed = true
        }
        let watchStopped = status.sid != context.sid || status.phase == .idle || status.phase == .finalizing
        if recording?.watchConfirmed == true, watchStopped, !context.watchStopNoticed, phase == .recording {
            context.watchStopNoticed = true
            let reason = status.lastError ?? status.phase.rawValue
            context.events.log("watch_status", detail: "the Watch stopped recording (\(reason))")
            context.manifest.warnings.append("The Watch stopped recording before the iPhone (\(reason)).")
            alertMessage = "The Watch stopped recording (\(reason))."
        }
    }

    private func startProtocolIfNeeded(_ context: RecordingContext) {
        guard context.settings.guidedProtocol, self.context === context, phase == .recording else { return }
        env.runner.start(
            definition: context.settings.protocolDefinition,
            instrumentedSide: context.settings.instrumentedSide,
            watchPresent: context.settings.mode.usesWatch,
            voice: context.settings.voiceCues
        ) { [weak self] effect in
            self?.handleProtocolEffect(effect)
        }
    }

    private func handleProtocolEffect(_ effect: ProtocolEngine.Effect) {
        guard let context else { return }
        switch effect {
        case .speak(let text, let token):
            env.speech.speak(text, token: token)
        case .stopSpeaking:
            env.speech.stop()
        case .watchStep(let notice):
            env.link.send(.step(notice), sid: context.sid)
        case .log(let event, let step, let detail):
            context.events.log(event, step: step, detail: detail)
        case .trialEnded:
            runEndBurst(context)
        case .completed:
            Task { await self.stop(reason: "protocol_complete") }
        }
    }

    private func runEndBurst(_ context: RecordingContext) {
        guard let sync = context.sync, context.endBurstTask == nil else { return }
        context.endBurstTask = Task { [weak self] in
            sync.stopPeriodic()
            await sync.burst(.end)
            guard let self, self.context === context, self.phase == .recording else { return }
            sync.startPeriodic()
        }
    }

    private func startAnchorTimer(_ context: RecordingContext) {
        context.anchorTask = Task { [weak context] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let context, !Task.isCancelled else { return }
                context.events.log("clock_anchor")
            }
        }
    }

    // MARK: - During the recording

    func addMarker() {
        guard let context, var info = recording else { return }
        info.markerCount += 1
        recording = info
        let label = "M\(info.markerCount)"
        context.events.log("marker", detail: label)
        if context.settings.mode.usesWatch {
            env.link.send(.marker(MarkerPayload(label: label)), sid: context.sid)
        }
    }

    func endTrial() {
        context?.events.log("end_trial_pressed", detail: "phone")
        env.runner.send(.advance(source: "phone"))
    }

    var phoneSnapshot: RecorderSnapshot {
        env.recorder.snapshot()
    }

    // MARK: - Stop

    func stop(reason: String) async {
        guard phase == .recording, let context else { return }
        phase = .stopping
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "StopSession")
        defer {
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
            }
        }
        let settings = context.settings
        context.events.log("stop_requested", detail: reason)

        if env.runner.isActive {
            env.runner.send(.abort(reason: reason))
        }
        env.runner.finish()
        context.anchorTask?.cancel()
        context.watchTask?.cancel()
        env.pocket.disengage()

        if settings.mode.usesWatch, let sync = context.sync {
            if let endBurst = context.endBurstTask {
                await endBurst.value
            } else {
                sync.stopPeriodic()
                await sync.burst(.end)
            }
            sync.stopPeriodic()
            let stop = LinkMessage.stop(StopCommand(reason: reason))
            do {
                _ = try await env.link.requestWithRetry(stop, sid: context.sid)
                context.events.log("watch_command", detail: "stop accepted")
            } catch {
                env.link.enqueue(stop, sid: context.sid)
                context.events.log("watch_command", detail: "stop queued: \(Self.describe(error))")
                context.manifest.warnings.append(
                    "The Watch did not confirm the stop. It stops when the queued command arrives, with its Stop button, or after \(Int(settings.maxDurationMin)) min."
                )
            }
            watch.status = nil
            context.manifest.clockSync = sync.finish()
        }

        if settings.mode.usesIphone {
            let snapshot = env.recorder.endRecording()
            if let error = snapshot.writeError {
                context.manifest.warnings.append("iPhone write error: \(error)")
            }
            let journal = context.folder.journalDirectory.appendingPathComponent("iphone_motion.bin")
            let csv = context.folder.url.appendingPathComponent("iphone_motion.csv")
            let nominal = settings.iphoneRateHz
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try CSVConverter.convertMotion(journal: journal, to: csv, nominalHz: nominal, attributes: SessionStore.protection)
                }.value
                if var stream = context.manifest.devices.iphone?.streams.first {
                    stream.stats = result.stats
                    stream.truncatedTailBytes = result.truncatedTailBytes
                    context.manifest.devices.iphone?.streams = [stream]
                }
                env.store.removeJournal(for: context.sid)
            } catch {
                let kept = env.store.preserveJournal(sid: context.sid, in: context.folder.url) ?? "nothing"
                context.manifest.warnings.append(
                    "Converting the iPhone data failed (\(error.localizedDescription)); the raw journal was kept as \(kept) (format in DATA_FORMAT.md)."
                )
            }
        } else {
            env.store.removeJournal(for: context.sid)
        }

        if context.manifest.guidedProtocol != nil {
            context.manifest.guidedProtocol?.timeline = env.runner.timeline
            context.manifest.guidedProtocol?.outcome = env.runner.outcome ?? "not started"
        }
        env.runner.reset()
        context.manifest.devices.iphone?.anchorEnd = .now()
        context.manifest.devices.iphone?.battery.end = Self.batteryLevel()
        context.manifest.ended = .now()
        context.manifest.status = settings.mode.usesWatch ? .awaitingWatchData : .complete
        context.events.log("recording_stop", detail: reason)
        context.events.close()
        context.manifest.files = env.store.fileEntries(in: context.folder.url, manifest: context.manifest)
        do {
            try env.store.writeManifest(context.manifest, to: context.folder.url)
        } catch {
            alertMessage = "Could not write session.json: \(error.localizedDescription)"
        }
        if settings.guidedProtocol && settings.voiceCues {
            env.speech.deactivateAudio()
        }
        if settings.autoIncrementTrial {
            env.settings.value.trial = SessionNaming.nextTrialLabel(settings.trial)
        }

        UIApplication.shared.isIdleTimerDisabled = false
        self.context = nil
        recording = nil
        phase = .idle
        sessionsVersion += 1
        startPreviewIfNeeded()
        processInbox()
        if settings.mode.usesWatch {
            // Ask again once the Watch has finished saving.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard let self, self.phase == .idle else { return }
                await self.hello()
            }
        }
    }

    /// Cleans up a session that failed to start.
    private func abandon(_ context: RecordingContext, message: String) {
        context.events.close()
        context.anchorTask?.cancel()
        try? FileManager.default.removeItem(at: context.folder.url)
        env.store.removeJournal(for: context.sid)
        env.store.markDeleted(context.sid)
        UIApplication.shared.isIdleTimerDisabled = false
        watch.status = nil
        self.context = nil
        recording = nil
        phase = .idle
        alertMessage = message
    }

    // MARK: - App life cycle

    private func appDidEnterBackground() {
        guard let context, phase == .recording else { return }
        env.recorder.flush(fsync: true)
        context.events.flush(fsync: true)
        if env.runner.isActive {
            env.runner.send(.appInterrupted)
        }
    }

    private func appWillEnterForeground() {
        guard let context, phase == .recording, context.settings.mode.usesIphone else { return }
        // Give CoreMotion a moment to resume by itself before restarting it.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, self.context === context,
                  let restart = self.env.recorder.restartIfStalled(now: MonotonicClock.uptime()) else { return }
            context.events.log("motion_restart", detail: "device motion stalled in the background; heading reference reset")
            context.manifest.warnings.append(
                "iPhone device motion stopped while the app was in the background and restarted at uptime \(FixedPoint.string(restart.dmStartUptime, decimals: 3)) s; the heading reference changed."
            )
        }
    }

    private func appDidBecomeActive() {
        env.pocket.appDidBecomeActive()
        processInbox()
        refreshPreflight()
    }

    func processInbox() {
        guard recoveryFinished, env.link.state.activated, UIApplication.shared.applicationState == .active else { return }
        Task { await env.ingestor.processAll() }
    }

    // MARK: - Sessions on disk

    func listSessions() -> [SessionSummary] {
        env.store.list()
    }

    func delete(_ summary: SessionSummary) {
        guard summary.manifest.sessionId != recording?.sid else {
            alertMessage = "This session is still being recorded."
            return
        }
        do {
            try env.store.delete(summary)
            sessionsVersion += 1
        } catch {
            alertMessage = "Could not delete the session: \(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    static func batteryLevel() -> Float? {
        let level = UIDevice.current.batteryLevel
        return level >= 0 ? level : nil
    }

    static func freeBytes() -> Int64? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    static func describe(_ error: Error) -> String {
        if let error = error as? LinkError { return error.description }
        return error.localizedDescription
    }
}
