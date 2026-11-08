//
//  ExportService.swift
//  Iphone_motion
//

import Foundation

enum ExportService {
    /// Zips a session folder (system zip via NSFileCoordinator) into tmp/Exports.
    static func zip(folder: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            let exports = fileManager.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
            try fileManager.createDirectory(at: exports, withIntermediateDirectories: true)
            let destination = exports.appendingPathComponent(folder.lastPathComponent).appendingPathExtension("zip")
            try? fileManager.removeItem(at: destination)

            var coordinationError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordinationError) { zipURL in
                do {
                    try fileManager.copyItem(at: zipURL, to: destination)
                } catch {
                    copyError = error
                }
            }
            if let coordinationError { throw coordinationError }
            if let copyError { throw copyError }
            return destination
        }.value
    }
}
