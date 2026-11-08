//
//  PhoneMotionRecorder.swift
//  Iphone_motion
//
//  Owns the app's only CMMotionManager. Samples are handled on a private serial queue: every
//  sample goes to the journal while recording; every 5th one feeds the live preview.
//

import CoreMotion
import Foundation
import RecorderCore

/// A decimated sample for the live chart.
struct PreviewSample: Sendable {
    let t: Double
    let roll: Double
    let pitch: Double
    let yaw: Double
    let gyroNorm: Double
}

struct RecordingStart: Sendable {
    /// Uptime when device motion (re)started, i.e. when the heading reference was set.
    let dmStartUptime: Double
    let referenceFrame: String
    let rateHz: Double
}

struct RecorderSnapshot: Sendable {
    var isRecording = false
    var stats: StreamStats?
    var lastSampleUptime: Double?
    var writeError: String?
}

final class PhoneMotionRecorder: @unchecked Sendable {
    private let manager = CMMotionManager()
    private let queue = DispatchQueue(label: "Iphone_motion.PhoneMotionRecorder", qos: .userInitiated)
    private let operationQueue = OperationQueue()

    // Confined to `queue`.
    private var journal: JournalWriter<MotionRecord>?
    private var stats: StreamStats?
    private var decimator = Decimator(factor: 5)
    private var pendingPreview: [PreviewSample] = []
    private var lastPreviewDelivery = 0.0
    private var previewHandler: (@MainActor ([PreviewSample]) -> Void)?
    private var running: (rateHz: Double, frame: CMAttitudeReferenceFrame)?
    private var lastSampleUptime: Double?
    private var writeError: String?

    private let snapshotLock = NSLock()
    private var latestSnapshot = RecorderSnapshot()

    init() {
        operationQueue.maxConcurrentOperationCount = 1
        operationQueue.underlyingQueue = queue
        operationQueue.name = "Iphone_motion.PhoneMotionRecorder.updates"
    }

    var isDeviceMotionAvailable: Bool {
        manager.isDeviceMotionAvailable
    }

    func snapshot() -> RecorderSnapshot {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return latestSnapshot
    }

    /// Starts device motion for the live preview, or adapts a running stream to new settings.
    func startPreview(rateHz: Double, frameName: String, onPreview: @escaping @MainActor ([PreviewSample]) -> Void) {
        queue.async {
            self.previewHandler = onPreview
            if self.journal == nil {
                self.startUpdates(rateHz: rateHz, frameName: frameName, forceRestart: false)
            }
        }
    }

    /// Stops device motion unless a recording is running.
    func stopPreview() {
        queue.async {
            self.previewHandler = nil
            if self.journal == nil {
                self.manager.stopDeviceMotionUpdates()
                self.running = nil
            }
        }
    }

    /// Opens the journal and restarts device motion so the heading reference is set now.
    func beginRecording(journalURL: URL, rateHz: Double, frameName: String, attributes: [FileAttributeKey: Any]) throws -> RecordingStart {
        try queue.sync {
            journal = try JournalWriter<MotionRecord>(url: journalURL, attributes: attributes)
            stats = StreamStats(nominalHz: rateHz)
            writeError = nil
            let start = startUpdates(rateHz: rateHz, frameName: frameName, forceRestart: true)
            publishSnapshot()
            return start
        }
    }

    /// Closes the journal. Device motion keeps running for the preview if one is attached.
    func endRecording() -> RecorderSnapshot {
        queue.sync {
            do {
                try journal?.close()
            } catch {
                writeError = error.localizedDescription
            }
            journal = nil
            if previewHandler == nil {
                manager.stopDeviceMotionUpdates()
                running = nil
            }
            var result = RecorderSnapshot()
            result.stats = stats
            result.lastSampleUptime = lastSampleUptime
            result.writeError = writeError
            stats = nil
            publishSnapshot()
            return result
        }
    }

    /// Writes buffered samples to disk; with `fsync` also forces them to storage.
    func flush(fsync: Bool) {
        queue.sync {
            do {
                try journal?.flush(fsync: fsync)
            } catch {
                writeError = error.localizedDescription
            }
        }
    }

    /// Restarts device motion if a recording stopped receiving samples (e.g. after the app was
    /// suspended). Returns the restart time, which resets the heading reference.
    func restartIfStalled(now: Double, threshold: Double = 1) -> RecordingStart? {
        queue.sync {
            guard journal != nil, let running else { return nil }
            if let last = lastSampleUptime, now - last < threshold { return nil }
            return startUpdates(rateHz: running.rateHz, frameName: ReferenceFrames.name(of: running.frame), forceRestart: true)
        }
    }

    // MARK: - Queue-confined

    @discardableResult
    private func startUpdates(rateHz: Double, frameName: String, forceRestart: Bool) -> RecordingStart {
        let available = CMMotionManager.availableAttitudeReferenceFrames()
        let requested = ReferenceFrames.frame(named: frameName) ?? .xArbitraryZVertical
        let frame = available.contains(requested) ? requested : .xArbitraryZVertical
        if manager.isDeviceMotionActive {
            if !forceRestart, let running, running.rateHz == rateHz, running.frame == frame {
                return RecordingStart(dmStartUptime: MonotonicClock.uptime(), referenceFrame: ReferenceFrames.name(of: frame), rateHz: rateHz)
            }
            manager.stopDeviceMotionUpdates()
        }
        manager.deviceMotionUpdateInterval = 1 / rateHz
        lastSampleUptime = nil
        manager.startDeviceMotionUpdates(using: frame, to: operationQueue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.handle(motion)
        }
        running = (rateHz, frame)
        return RecordingStart(dmStartUptime: MonotonicClock.uptime(), referenceFrame: ReferenceFrames.name(of: frame), rateHz: rateHz)
    }

    private func handle(_ motion: CMDeviceMotion) {
        let record = MotionRecord(motion)
        lastSampleUptime = record.t
        if let journal {
            do {
                try journal.append(record)
            } catch {
                writeError = error.localizedDescription
            }
            stats?.add(record.t)
        }
        if previewHandler != nil, decimator.shouldEmit() {
            let gyro = record.gyro
            pendingPreview.append(PreviewSample(
                t: record.t,
                roll: Double(record.roll) * 180 / .pi,
                pitch: Double(record.pitch) * 180 / .pi,
                yaw: Double(record.yaw) * 180 / .pi,
                gyroNorm: Double((gyro * gyro).sum().squareRoot())
            ))
            if record.t - lastPreviewDelivery >= 0.1, let handler = previewHandler {
                let batch = pendingPreview
                pendingPreview.removeAll(keepingCapacity: true)
                lastPreviewDelivery = record.t
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { handler(batch) }
                }
            }
        }
        if journal != nil, let count = stats?.count, count % 50 == 0 {
            publishSnapshot()
        }
    }

    private func publishSnapshot() {
        snapshotLock.lock()
        latestSnapshot = RecorderSnapshot(
            isRecording: journal != nil,
            stats: stats,
            lastSampleUptime: lastSampleUptime,
            writeError: writeError
        )
        snapshotLock.unlock()
    }
}
