//
//  WatchSessionStore.swift
//  Iphone_motion Watch App
//
//  WatchSessions/<sid>/ holds state.json, the journals, watch_events.csv and manifest.json.
//  A session is kept until the iPhone acknowledges it ingested the files.
//

import Foundation
import RecorderCore

struct WatchSessionState: Codable, Sendable {
    enum Phase: String, Codable, Sendable {
        case recording
        case finalized
    }

    var sid: UUID
    var command: StartCommand
    var phase: Phase
    var created: Timestamp
    var device: DeviceSection
    var sentKinds: [FileKind] = []
    var transferAttempts = 0
}

final class WatchSessionStore: @unchecked Sendable {
    static let protection: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]

    let root: URL
    private let fileManager = FileManager.default

    init() {
        root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WatchSessions", isDirectory: true)
    }

    func prepare() {
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true, attributes: Self.protection)
    }

    func directory(for sid: UUID) -> URL {
        root.appendingPathComponent(sid.uuidString, isDirectory: true)
    }

    func url(_ kind: FileKind, sid: UUID) -> URL {
        directory(for: sid).appendingPathComponent(kind.watchFileName)
    }

    func create(_ state: WatchSessionState) throws {
        try fileManager.createDirectory(at: directory(for: state.sid), withIntermediateDirectories: true, attributes: Self.protection)
        try save(state)
    }

    func save(_ state: WatchSessionState) throws {
        try ManifestCoding.write(state, to: directory(for: state.sid).appendingPathComponent("state.json"))
    }

    func load(_ sid: UUID) -> WatchSessionState? {
        try? ManifestCoding.read(WatchSessionState.self, from: directory(for: sid).appendingPathComponent("state.json"))
    }

    func all() -> [WatchSessionState] {
        let names = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        return names.compactMap(UUID.init(uuidString:)).compactMap(load)
    }

    /// Finalized sessions not yet acknowledged by the iPhone.
    func pending() -> [WatchSessionState] {
        all().filter { $0.phase == .finalized }
    }

    func delete(_ sid: UUID) {
        try? fileManager.removeItem(at: directory(for: sid))
    }

    /// Files of a session that exist on disk.
    func files(for sid: UUID) -> [(FileKind, URL)] {
        FileKind.allCases.compactMap { kind in
            let url = url(kind, sid: sid)
            return fileManager.fileExists(atPath: url.path) ? (kind, url) : nil
        }
    }

    func fileSize(_ url: URL) -> Int64? {
        (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    var freeBytes: Int64? {
        (try? fileManager.attributesOfFileSystem(forPath: NSHomeDirectory())[.systemFreeSize] as? NSNumber)?.int64Value
    }
}
