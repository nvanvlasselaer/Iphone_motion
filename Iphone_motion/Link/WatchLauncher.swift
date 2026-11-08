//
//  WatchLauncher.swift
//  Iphone_motion
//
//  Launches the Watch app with a workout configuration. The Watch app then starts its workout
//  session right away, which keeps it running (and reachable) with the wrist down.
//

import HealthKit
import RecorderCore

@MainActor
final class WatchLauncher {
    private let healthStore = HKHealthStore()

    func ensureAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let workouts = HKObjectType.workoutType()
        if healthStore.authorizationStatus(for: workouts) == .notDetermined {
            try await healthStore.requestAuthorization(toShare: [workouts], read: [])
        }
    }

    func launch() async throws {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .other
        configuration.locationType = .unknown
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            healthStore.startWatchApp(with: configuration) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if !success {
                    continuation.resume(throwing: LinkError.transport("The Watch app could not be launched."))
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
