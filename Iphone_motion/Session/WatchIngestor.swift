//
//  WatchIngestor.swift
//  Iphone_motion
//
//  Turns files received from the Watch (journals, events, manifest) into CSV files in the session
//  folder, merges the Watch section into session.json and acknowledges, so the Watch can free
//  its storage. Runs only while the app is active.
//

import Foundation
import RecorderCore

@MainActor
final class WatchIngestor {
    private let store: SessionStore
    private let link: PhoneLink
    private var isRunning = false
    private var runAgain = false

    /// Sessions that must not be touched yet (the one being recorded or stopped).
    var isBusy: (UUID) -> Bool = { _ in false }
    var onChange: (() -> Void)?

    init(store: SessionStore, link: PhoneLink) {
        self.store = store
        self.link = link
    }

    func processAll() async {
        if isRunning {
            runAgain = true
            return
        }
        isRunning = true
        repeat {
            runAgain = false
            for sid in store.inboxSessionIds() where !isBusy(sid) {
                await process(sid)
            }
        } while runAgain
        isRunning = false
    }

    private func process(_ sid: UUID) async {
        let fileManager = FileManager.default
        let directory = store.inboxDirectory(for: sid)
        let received = Set(FileKind.allCases.filter {
            fileManager.fileExists(atPath: directory.appendingPathComponent($0.watchFileName).path)
        })
        let manifest = try? ManifestCoding.read(WatchManifest.self, from: directory.appendingPathComponent(FileKind.manifest.watchFileName))
        let phoneFolder = store.folder(for: sid)
        let action = IngestPlanner.plan(
            manifest: manifest,
            received: received,
            phoneSessionExists: phoneFolder != nil,
            phoneSessionDeleted: store.isDeleted(sid)
        )
        switch action {
        case .waitForManifest, .waitForFiles:
            return
        case .discard:
            try? fileManager.removeItem(at: directory)
            link.enqueue(.ingestAck(IngestAckPayload(ok: true, kinds: Array(received))), sid: sid)
        case .ingest(let createFolder):
            guard let manifest else { return }
            do {
                let folder: URL
                if createFolder {
                    folder = try store.createOrphanFolder(for: manifest)
                } else if let phoneFolder {
                    folder = phoneFolder
                } else {
                    return
                }
                let converted = try await Task.detached(priority: .utility) {
                    try WatchIngestor.convert(directory: directory, manifest: manifest, into: folder)
                }.value
                try merge(manifest, converted: converted, into: folder)
                try? fileManager.removeItem(at: directory)
                link.enqueue(.ingestAck(IngestAckPayload(ok: true, kinds: Array(received))), sid: sid)
                onChange?()
            } catch {
                // Keep the files: the next activation retries.
            }
        }
    }

    struct Converted: Sendable {
        var motion: CSVConverter.Result?
        var accel: CSVConverter.Result?
        var hasEvents = false
    }

    nonisolated static func convert(directory: URL, manifest: WatchManifest, into folder: URL) throws -> Converted {
        let fileManager = FileManager.default
        func nominal(_ kind: StreamKind) -> Double {
            let stream = manifest.device.streams.first { $0.kind == kind }
            return stream?.reportedHz ?? stream?.requestedHz ?? 0
        }
        var converted = Converted()
        let motion = directory.appendingPathComponent(FileKind.motion.watchFileName)
        if fileManager.fileExists(atPath: motion.path) {
            converted.motion = try CSVConverter.convertMotion(
                journal: motion, to: folder.appendingPathComponent("watch_motion.csv"),
                nominalHz: nominal(.motion), attributes: SessionStore.protection
            )
        }
        let accel = directory.appendingPathComponent(FileKind.accel.watchFileName)
        if fileManager.fileExists(atPath: accel.path) {
            converted.accel = try CSVConverter.convertAccel(
                journal: accel, to: folder.appendingPathComponent("watch_accel.csv"),
                nominalHz: nominal(.accel), attributes: SessionStore.protection
            )
        }
        let events = directory.appendingPathComponent(FileKind.events.watchFileName)
        if fileManager.fileExists(atPath: events.path) {
            let destination = folder.appendingPathComponent("watch_events.csv")
            try? fileManager.removeItem(at: destination)
            try fileManager.copyItem(at: events, to: destination)
            converted.hasEvents = true
        }
        return converted
    }

    private func merge(_ watch: WatchManifest, converted: Converted, into folder: URL) throws {
        guard var session = store.readManifest(at: folder) else { return }
        var section = watch.device
        section.eventsFile = converted.hasEvents ? "watch_events.csv" : nil
        section.streams = watch.device.streams.map { stream in
            var updated = stream
            let result: CSVConverter.Result?
            switch stream.kind {
            case .motion:
                updated.file = "watch_motion.csv"
                result = converted.motion
            case .accel:
                updated.file = "watch_accel.csv"
                result = converted.accel
            }
            if let result {
                updated.stats = result.stats
                updated.truncatedTailBytes = result.truncatedTailBytes
            }
            return updated
        }
        session.devices.watch = section
        session.warnings.append(contentsOf: watch.warnings.map { "Watch: \($0)" })
        if watch.status == .interrupted {
            session.warnings.append("The Watch recording ended unexpectedly (\(watch.stopReason)).")
        }
        if session.status == .awaitingWatchData {
            session.status = watch.status == .interrupted ? .interrupted : .complete
        }
        session.files = store.fileEntries(in: folder, manifest: session)
        try store.writeManifest(session, to: folder)
    }
}
