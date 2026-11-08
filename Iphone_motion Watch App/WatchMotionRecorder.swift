//
//  WatchMotionRecorder.swift
//  Iphone_motion Watch App
//
//  High rate: CMBatchedSensorManager delivers ~1 s batches of 200 Hz device motion and 800 Hz
//  accelerometer data (needs a running workout session). Standard: CMMotionManager up to 100 Hz
//  with a selectable reference frame. All samples go to binary journals on a serial queue; no
//  number formatting happens on the Watch.
//

import CoreMotion
import Foundation
import RecorderCore

struct WatchRecorderSnapshot: Sendable {
    var motion: StreamStats?
    var accel: StreamStats?
    /// Uptime at delivery minus the timestamp of the newest sample in the batch.
    var batchLatency: Double?
    var lastError: String?
}

struct WatchRecorderResult: Sendable {
    var motion: StreamStats?
    var accel: StreamStats?
    var error: String?
}

final class WatchMotionRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Iphone_motion.WatchMotionRecorder", qos: .userInitiated)
    private let operationQueue = OperationQueue()
    private let legacy = CMMotionManager()

    // Confined to `queue`.
    private var batched: CMBatchedSensorManager?
    private var motionJournal: JournalWriter<MotionRecord>?
    private var accelJournal: JournalWriter<AccelRecord>?
    private var motionStats: StreamStats?
    private var accelStats: StreamStats?
    private var batchLatency: Double?
    private var lastError: String?
    private var reportedFirstSamples = false

    private let lock = NSLock()
    private var latest = WatchRecorderSnapshot()

    /// Called on the main actor when the first samples have been written.
    var onFirstSamples: (@MainActor () -> Void)?

    init() {
        operationQueue.maxConcurrentOperationCount = 1
        operationQueue.underlyingQueue = queue
    }

    static var batchedDeviceMotionSupported: Bool { CMBatchedSensorManager.isDeviceMotionSupported }
    static var batchedAccelerometerSupported: Bool { CMBatchedSensorManager.isAccelerometerSupported }

    func snapshot() -> WatchRecorderSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    /// Opens the journals and starts the sensors. Returns the stream descriptions for the manifest.
    func start(config: WatchSensorConfig, motionURL: URL, accelURL: URL, attributes: [FileAttributeKey: Any]) throws -> [StreamInfo] {
        try queue.sync {
            motionJournal = try JournalWriter<MotionRecord>(url: motionURL, attributes: attributes)
            reportedFirstSamples = false
            batchLatency = nil
            lastError = nil
            var streams: [StreamInfo] = []
            let startUptime = MonotonicClock.uptime()

            if config.source == .batched && CMBatchedSensorManager.isDeviceMotionSupported {
                let manager = CMBatchedSensorManager()
                batched = manager
                let motionHz = Double(manager.deviceMotionDataFrequency)
                motionStats = StreamStats(nominalHz: motionHz)
                manager.startDeviceMotionUpdates { [weak self] batch, error in
                    self?.queue.async { self?.handleMotion(batch: batch, error: error) }
                }
                streams.append(StreamInfo(
                    kind: .motion, file: FileKind.motion.watchFileName, sourceApi: "CMBatchedSensorManager.deviceMotion",
                    reportedHz: motionHz, referenceFrame: "arbitrary (not selectable)", dmStartUptimeS: startUptime
                ))
                if config.accel800 && CMBatchedSensorManager.isAccelerometerSupported {
                    accelJournal = try JournalWriter<AccelRecord>(url: accelURL, attributes: attributes)
                    let accelHz = Double(manager.accelerometerDataFrequency)
                    accelStats = StreamStats(nominalHz: accelHz)
                    manager.startAccelerometerUpdates { [weak self] batch, error in
                        self?.queue.async { self?.handleAccel(batch: batch, error: error) }
                    }
                    streams.append(StreamInfo(
                        kind: .accel, file: FileKind.accel.watchFileName, sourceApi: "CMBatchedSensorManager.accelerometer",
                        reportedHz: accelHz
                    ))
                }
            } else {
                let available = CMMotionManager.availableAttitudeReferenceFrames()
                let requested = ReferenceFrames.frame(named: config.legacyReferenceFrame) ?? .xArbitraryZVertical
                let frame = available.contains(requested) ? requested : .xArbitraryZVertical
                legacy.deviceMotionUpdateInterval = 1 / config.legacyHz
                motionStats = StreamStats(nominalHz: config.legacyHz)
                legacy.startDeviceMotionUpdates(using: frame, to: operationQueue) { [weak self] motion, error in
                    self?.handleMotion(batch: motion.map { [$0] }, error: error)
                }
                streams.append(StreamInfo(
                    kind: .motion, file: FileKind.motion.watchFileName, sourceApi: "CMMotionManager.deviceMotion",
                    requestedHz: config.legacyHz, referenceFrame: ReferenceFrames.name(of: frame), dmStartUptimeS: startUptime
                ))
            }
            publish()
            return streams
        }
    }

    /// Keeps writing until every stream delivered a sample at or after `drainUntil` (the batched API
    /// delivers about once per second), then stops the sensors and closes the journals.
    func stop(drainUntil: Double, timeout: Double = 2.5) async -> WatchRecorderResult {
        let deadline = MonotonicClock.uptime() + timeout
        while MonotonicClock.uptime() < deadline {
            let drained = queue.sync {
                (motionStats?.lastT ?? 0) >= drainUntil && (accelJournal == nil || (accelStats?.lastT ?? 0) >= drainUntil)
            }
            if drained { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return queue.sync {
            batched?.stopDeviceMotionUpdates()
            batched?.stopAccelerometerUpdates()
            batched = nil
            legacy.stopDeviceMotionUpdates()
            do {
                try motionJournal?.close()
                try accelJournal?.close()
            } catch {
                lastError = error.localizedDescription
            }
            let result = WatchRecorderResult(motion: motionStats, accel: accelStats, error: lastError)
            motionJournal = nil
            accelJournal = nil
            motionStats = nil
            accelStats = nil
            publish()
            return result
        }
    }

    // MARK: - Queue-confined

    private func handleMotion(batch: [CMDeviceMotion]?, error: Error?) {
        if let error {
            lastError = error.localizedDescription
        }
        guard let batch, !batch.isEmpty, let journal = motionJournal else { return }
        let records = batch.map(MotionRecord.init)
        do {
            try journal.append(contentsOf: records)
        } catch {
            lastError = error.localizedDescription
        }
        for record in records {
            motionStats?.add(record.t)
        }
        if let last = records.last {
            batchLatency = MonotonicClock.uptime() - last.t
        }
        reportFirstSamplesIfNeeded()
        publish()
    }

    private func handleAccel(batch: [CMAccelerometerData]?, error: Error?) {
        if let error {
            lastError = error.localizedDescription
        }
        guard let batch, !batch.isEmpty, let journal = accelJournal else { return }
        let records = batch.map(AccelRecord.init)
        do {
            try journal.append(contentsOf: records)
        } catch {
            lastError = error.localizedDescription
        }
        for record in records {
            accelStats?.add(record.t)
        }
        publish()
    }

    private func reportFirstSamplesIfNeeded() {
        guard !reportedFirstSamples, let callback = onFirstSamples else { return }
        reportedFirstSamples = true
        DispatchQueue.main.async {
            MainActor.assumeIsolated { callback() }
        }
    }

    private func publish() {
        lock.lock()
        latest = WatchRecorderSnapshot(motion: motionStats, accel: accelStats, batchLatency: batchLatency, lastError: lastError)
        lock.unlock()
    }
}
