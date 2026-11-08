//
//  OneShot.swift
//  RecorderCore
//

import Foundation

public enum OneShotError: Error, Equatable {
    case timedOut
}

/// Resumes a continuation exactly once: whichever of the reply, the error callback or the timeout
/// comes first wins; later calls are ignored.
public final class OneShot<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    /// Returns true if this call resumed the continuation.
    @discardableResult
    public func resume(_ result: Result<T, Error>) -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return false }
        pending.resume(with: result)
        return true
    }
}

/// Runs `start`, which must eventually call `shot.resume`, and fails with `OneShotError.timedOut`
/// if nobody resumes within `timeout` seconds.
public func withOneShot<T>(timeout: Double, _ start: @escaping (OneShot<T>) -> Void) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        let shot = OneShot(continuation)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
            shot.resume(.failure(OneShotError.timedOut))
        }
        start(shot)
    }
}
