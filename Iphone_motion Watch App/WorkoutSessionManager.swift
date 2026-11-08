//
//  WorkoutSessionManager.swift
//  Iphone_motion Watch App
//
//  The workout session keeps the app running with the wrist down and is required for the
//  high-rate sensor API. No workout builder is used, so nothing is saved to Health.
//
//  Delegate callbacks are matched to the session they belong to: a late callback of a session
//  that was ended (or timed out) never affects the current one.
//

import Foundation
import HealthKit

@MainActor
final class WorkoutSessionManager: NSObject {
    private let healthStore = HKHealthStore()
    /// The session in use.
    private var session: HKWorkoutSession?
    /// Sessions asked to end, kept until HealthKit reports them ended.
    private var ending: [ObjectIdentifier: HKWorkoutSession] = [:]
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var startTimeout: Task<Void, Never>?

    /// The current workout stopped without being asked to (error message).
    var onUnexpectedEnd: ((String) -> Void)?

    var isRunning: Bool {
        session?.state == .running
    }

    var authorizationStatus: String {
        switch healthStore.authorizationStatus(for: HKObjectType.workoutType()) {
        case .sharingAuthorized: return "authorized"
        case .sharingDenied: return "denied"
        default: return "notDetermined"
        }
    }

    func requestAuthorization() async throws {
        try await healthStore.requestAuthorization(toShare: [HKObjectType.workoutType()], read: [])
    }

    /// Starts a workout session and returns once it is running.
    func start() async throws {
        if isRunning { return }
        guard startContinuation == nil else { throw WorkoutError.alreadyStarting }
        if let leftover = session {
            retire(leftover)
        }
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .other
        configuration.locationType = .unknown
        let newSession = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
        newSession.delegate = self
        session = newSession
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            startContinuation = continuation
            newSession.startActivity(with: Date())
            startTimeout = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled, let self, self.session === newSession, self.startContinuation != nil else { return }
                // End it, so a late start cannot leave a workout running that nobody uses.
                self.retire(newSession)
                self.resumeStart(throwing: WorkoutError.timedOut)
            }
        }
    }

    func end() {
        if let session {
            retire(session)
        }
    }

    /// Ends a workout session left running by a crash.
    func recoverAndEnd() async {
        let recovered: HKWorkoutSession? = await withCheckedContinuation { continuation in
            healthStore.recoverActiveWorkoutSession { session, _ in
                continuation.resume(returning: session)
            }
        }
        guard let recovered else { return }
        recovered.delegate = self
        retire(recovered)
    }

    private func retire(_ workoutSession: HKWorkoutSession) {
        if session === workoutSession {
            session = nil
        }
        ending[ObjectIdentifier(workoutSession)] = workoutSession
        workoutSession.end()
    }

    private func resumeStart(throwing error: Error? = nil) {
        startTimeout?.cancel()
        startTimeout = nil
        guard let continuation = startContinuation else { return }
        startContinuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    fileprivate func sessionChanged(_ id: ObjectIdentifier, to state: HKWorkoutSessionState) {
        if ending[id] != nil {
            if state == .ended {
                ending[id] = nil
            }
            return
        }
        guard let current = session, ObjectIdentifier(current) == id else { return }
        switch state {
        case .running:
            resumeStart()
        case .stopped, .ended:
            retire(current)
            if startContinuation != nil {
                resumeStart(throwing: WorkoutError.endedEarly)
            } else {
                onUnexpectedEnd?("the workout session ended")
            }
        default:
            break
        }
    }

    fileprivate func sessionFailed(_ id: ObjectIdentifier, error: Error) {
        guard ending[id] == nil, let current = session, ObjectIdentifier(current) == id else { return }
        retire(current)
        if startContinuation != nil {
            resumeStart(throwing: error)
        } else {
            onUnexpectedEnd?(error.localizedDescription)
        }
    }

    enum WorkoutError: LocalizedError {
        case timedOut
        case alreadyStarting
        case endedEarly

        var errorDescription: String? {
            switch self {
            case .timedOut: return "The workout session did not start within 10 s."
            case .alreadyStarting: return "A workout session is already starting."
            case .endedEarly: return "The workout session ended while starting."
            }
        }
    }
}

extension WorkoutSessionManager: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        let id = ObjectIdentifier(workoutSession)
        Task { @MainActor in
            self.sessionChanged(id, to: toState)
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        let id = ObjectIdentifier(workoutSession)
        Task { @MainActor in
            self.sessionFailed(id, error: error)
        }
    }
}
