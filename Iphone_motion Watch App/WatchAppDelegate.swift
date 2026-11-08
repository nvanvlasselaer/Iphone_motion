//
//  WatchAppDelegate.swift
//  Iphone_motion Watch App
//

import HealthKit
import WatchKit

final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        MainActor.assumeIsolated {
            WatchController.shared.start()
        }
    }

    /// Called when the iPhone app launches this app with `HKHealthStore.startWatchApp`.
    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        MainActor.assumeIsolated {
            WatchController.shared.launchedForWorkout()
        }
    }

    /// Called after a crash during a workout session.
    func handleActiveWorkoutRecovery() {
        MainActor.assumeIsolated {
            WatchController.shared.recoverAfterCrash()
        }
    }

    func applicationDidBecomeActive() {
        MainActor.assumeIsolated {
            WatchController.shared.applicationDidBecomeActive()
        }
    }
}
