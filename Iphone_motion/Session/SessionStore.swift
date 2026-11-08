//
//  SessionStore.swift
//  Iphone_motion
//
//  Layout:
//    Documents/Sessions/<name>/                  session folders (visible in the Files app)
//    Application Support/Journal/<sid>/          binary journals while recording
//    Application Support/WatchInbox/<sid>/       files received from the Watch, before ingestion
//    Application Support/deleted_sessions.json   sessions deleted while Watch data was pending
//

import Foundation
import RecorderCore

struct SessionFolder: Sendable {
    let sid: UUID
    let name: String
    let url: URL
    let journalDirectory: URL
}

struct SessionSummary: Identifiable, Hashable, Sendable {
    let url: URL
    let manifest: SessionManifest

    var id: URL { url }

    static func == (lhs: SessionSummary, rhs: SessionSummary) -> Bool {
        lhs.url == rhs.url && lhs.manifest == rhs.manifest
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }
}

final class SessionStore: @unchecked Sendable {
    /// Files stay writable while the device is locked (after the first unlock since boot).
    static let protection: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
    static let manifestName = "session.json"

    let sessionsRoot: URL
    let journalsRoot: URL
    let inboxRoot: URL
    private let tombstonesURL: URL
    private let fileManager = FileManager.default
    private let lock = NSLock()

    init(
        documents: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0],
        support: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    ) {
        sessionsRoot = documents.appendingPathComponent("Sessions", isDirectory: true)
        journalsRoot = support.appendingPathComponent("Journal", isDirectory: true)
        inboxRoot = support.appendingPathComponent("WatchInbox", isDirectory: true)
        tombstonesURL = support.appendingPathComponent("deleted_sessions.json")
    }

    func prepareDirectories() {
        for directory in [sessionsRoot, journalsRoot, inboxRoot] {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: Self.protection)
        }
    }

    // MARK: Sessions

    func existingNames() -> Set<String> {
        let names = (try? fileManager.contentsOfDirectory(atPath: sessionsRoot.path)) ?? []
        return Set(names)
    }

    func create(name: String, sid: UUID) throws -> SessionFolder {
        let url = sessionsRoot.appendingPathComponent(name, isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: Self.protection)
        let journal = journalDirectory(for: sid)
        try fileManager.createDirectory(at: journal, withIntermediateDirectories: true, attributes: Self.protection)
        return SessionFolder(sid: sid, name: name, url: url, journalDirectory: journal)
    }

    func readManifest(at folder: URL) -> SessionManifest? {
        try? ManifestCoding.read(SessionManifest.self, from: folder.appendingPathComponent(Self.manifestName))
    }

    func writeManifest(_ manifest: SessionManifest, to folder: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        try ManifestCoding.write(manifest, to: folder.appendingPathComponent(Self.manifestName))
    }

    /// All sessions, newest first.
    func list() -> [SessionSummary] {
        let urls = (try? fileManager.contentsOfDirectory(at: sessionsRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return urls
            .compactMap { url in readManifest(at: url).map { SessionSummary(url: url, manifest: $0) } }
            .sorted { $0.manifest.created.unixS > $1.manifest.created.unixS }
    }

    func folder(for sid: UUID) -> URL? {
        list().first { $0.manifest.sessionId == sid }?.url
    }

    func copyDataFormat(to folder: URL) {
        guard let source = RecorderCoreResources.dataFormatURL else { return }
        let destination = folder.appendingPathComponent("DATA_FORMAT.md")
        try? fileManager.removeItem(at: destination)
        try? fileManager.copyItem(at: source, to: destination)
    }

    /// Files in the session folder with their sizes (rows for the sensor CSV files).
    func fileEntries(in folder: URL, manifest: SessionManifest) -> [FileEntry] {
        var rows: [String: Int] = [:]
        for section in [manifest.devices.iphone, manifest.devices.watch].compactMap({ $0 }) {
            for stream in section.streams {
                rows[stream.file] = stream.stats?.count
            }
        }
        let urls = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
        return urls
            .filter { $0.lastPathComponent != Self.manifestName && $0.pathExtension != "partial" }
            .map { url in
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }
                return FileEntry(name: url.lastPathComponent, rows: rows[url.lastPathComponent], bytes: size.map(Int64.init))
            }
            .sorted { $0.name < $1.name }
    }

    func delete(_ summary: SessionSummary) throws {
        if summary.manifest.status == .awaitingWatchData || summary.manifest.status == .recording {
            markDeleted(summary.manifest.sessionId)
        }
        try fileManager.removeItem(at: summary.url)
        removeJournal(for: summary.manifest.sessionId)
    }

    // MARK: Journals

    func journalDirectory(for sid: UUID) -> URL {
        journalsRoot.appendingPathComponent(sid.uuidString, isDirectory: true)
    }

    func removeJournal(for sid: UUID) {
        try? fileManager.removeItem(at: journalDirectory(for: sid))
    }

    /// Moves the raw iPhone journal into the session folder when it could not be converted, so the
    /// data stays with the session (and in the zip export). Returns the new file name.
    func preserveJournal(sid: UUID, in folder: URL) -> String? {
        let source = journalDirectory(for: sid).appendingPathComponent("iphone_motion.bin")
        guard fileManager.fileExists(atPath: source.path) else { return nil }
        let name = "iphone_motion.journal.bin"
        let destination = folder.appendingPathComponent(name)
        try? fileManager.removeItem(at: destination)
        guard (try? fileManager.moveItem(at: source, to: destination)) != nil else { return nil }
        removeJournal(for: sid)
        return name
    }

    /// Converts the journals of sessions that were still recording when the app stopped
    /// (crash, kill, battery). Returns the recovered folder names.
    func recoverInterrupted(except activeSid: UUID?) -> [String] {
        var recovered: [String] = []
        for summary in list() where summary.manifest.status == .recording && summary.manifest.sessionId != activeSid {
            var manifest = summary.manifest
            let journal = journalDirectory(for: manifest.sessionId).appendingPathComponent("iphone_motion.bin")
            var converted = true
            if fileManager.fileExists(atPath: journal.path), var stream = manifest.devices.iphone?.streams.first {
                let csv = summary.url.appendingPathComponent(stream.file)
                do {
                    let result = try CSVConverter.convertMotion(journal: journal, to: csv, nominalHz: stream.requestedHz ?? 100, attributes: Self.protection)
                    stream.stats = result.stats
                    stream.truncatedTailBytes = result.truncatedTailBytes
                    manifest.devices.iphone?.streams = [stream]
                } catch {
                    converted = false
                    let kept = preserveJournal(sid: manifest.sessionId, in: summary.url) ?? "nothing"
                    manifest.warnings.append("Converting the iPhone data failed (\(error.localizedDescription)); the raw journal was kept as \(kept) (format in DATA_FORMAT.md).")
                }
            }
            manifest.status = .interrupted
            manifest.warnings.append("The app stopped during the recording; the iPhone data up to that moment was recovered.")
            manifest.files = fileEntries(in: summary.url, manifest: manifest)
            try? writeManifest(manifest, to: summary.url)
            if converted {
                removeJournal(for: manifest.sessionId)
            }
            recovered.append(manifest.folder)
        }
        return recovered
    }

    // MARK: Watch inbox

    func inboxDirectory(for sid: UUID) -> URL {
        inboxRoot.appendingPathComponent(sid.uuidString, isDirectory: true)
    }

    func inboxSessionIds() -> [UUID] {
        let names = (try? fileManager.contentsOfDirectory(atPath: inboxRoot.path)) ?? []
        return names.compactMap(UUID.init(uuidString:))
    }

    /// Creates a session folder for Watch data whose iPhone session does not exist.
    func createOrphanFolder(for watch: WatchManifest) throws -> URL {
        let created = Date(timeIntervalSince1970: watch.created.unixS)
        let base = watch.start?.folder ?? SessionNaming.folderName(
            start: created, subject: watch.start?.subject ?? "watch", trial: watch.start?.trial ?? ""
        )
        let name = SessionNaming.uniqued(SessionNaming.sanitize(base).isEmpty ? "watch-session" : base, existing: existingNames())
        let url = sessionsRoot.appendingPathComponent(name, isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: Self.protection)
        let manifest = SessionManifest(
            sessionId: watch.sessionId,
            folder: name,
            status: .awaitingWatchData,
            mode: .watch,
            subject: watch.start?.subject ?? "",
            trial: watch.start?.trial ?? "",
            notes: "",
            created: watch.created,
            ended: watch.ended,
            warnings: ["The iPhone had no record of this session; it was rebuilt from the Watch data."]
        )
        try writeManifest(manifest, to: url)
        copyDataFormat(to: url)
        return url
    }

    // MARK: Tombstones

    func isDeleted(_ sid: UUID) -> Bool {
        tombstones().contains(sid)
    }

    private func tombstones() -> Set<UUID> {
        guard let data = try? Data(contentsOf: tombstonesURL),
              let ids = try? JSONDecoder().decode([UUID].self, from: data) else { return [] }
        return Set(ids)
    }

    /// Remembers a session as deleted so Watch files arriving later are discarded (and acknowledged).
    func markDeleted(_ sid: UUID) {
        lock.lock()
        defer { lock.unlock() }
        var ids = tombstones()
        ids.insert(sid)
        if let data = try? JSONEncoder().encode(Array(ids)) {
            try? data.write(to: tombstonesURL, options: .atomic)
        }
    }
}
