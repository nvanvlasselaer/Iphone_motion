//
//  IngestPlanner.swift
//  RecorderCore
//
//  Decides what to do with Watch files that arrived on the iPhone. Files can arrive in any order,
//  more than once, or for a session the iPhone does not know (e.g. the iPhone app was reinstalled).
//

import Foundation

extension FileKind {
    /// File name used on the Watch and in the iPhone inbox.
    public var watchFileName: String {
        switch self {
        case .manifest: return "manifest.json"
        case .motion: return "watch_motion.bin"
        case .accel: return "watch_accel.bin"
        case .events: return "watch_events.csv"
        }
    }
}

public enum IngestAction: Equatable, Sendable {
    case waitForManifest
    case waitForFiles([FileKind])
    /// Everything is there: convert and merge into the session folder (creating it if needed).
    case ingest(createFolder: Bool)
    /// The iPhone session was deleted: drop the files and acknowledge so the Watch frees space.
    case discard
}

public enum IngestPlanner {
    public static func plan(
        manifest: WatchManifest?,
        received: Set<FileKind>,
        phoneSessionExists: Bool,
        phoneSessionDeleted: Bool
    ) -> IngestAction {
        if phoneSessionDeleted {
            return .discard
        }
        guard let manifest else {
            return .waitForManifest
        }
        let expected = Set(manifest.files.map(\.kind)).union([.manifest])
        let missing = FileKind.allCases.filter { expected.contains($0) && !received.contains($0) }
        if !missing.isEmpty {
            return .waitForFiles(missing)
        }
        return .ingest(createFolder: !phoneSessionExists)
    }
}
