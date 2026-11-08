//
//  PocketModeController.swift
//  Iphone_motion
//
//  For an iPhone strapped to the body: the screen is dimmed, ignores touches behind a lock overlay
//  and turns off when the proximity sensor is covered (the app stays in the foreground, as during
//  a phone call). The session coordinator keeps the idle timer off for every recording.
//

import Observation
import UIKit

@MainActor
@Observable
final class PocketModeController {
    private(set) var isEngaged = false
    private(set) var isLocked = false

    /// (event, detail) to log in the session's event file.
    @ObservationIgnored var onEvent: ((String, String?) -> Void)?

    @ObservationIgnored private var savedBrightness: CGFloat?
    @ObservationIgnored private var dimScreen = true
    @ObservationIgnored private var proximityObserver: NSObjectProtocol?

    func engage(proximity: Bool, dim: Bool) {
        guard !isEngaged else { return }
        isEngaged = true
        dimScreen = dim
        if proximity {
            UIDevice.current.isProximityMonitoringEnabled = true
            proximityObserver = NotificationCenter.default.addObserver(
                forName: UIDevice.proximityStateDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.onEvent?(UIDevice.current.proximityState ? "proximity_covered" : "proximity_uncovered", nil)
                }
            }
        }
        lock()
    }

    func lock() {
        guard isEngaged else { return }
        isLocked = true
        applyDim()
        onEvent?("pocket_lock", nil)
    }

    func unlock() {
        guard isLocked else { return }
        isLocked = false
        restoreBrightness()
        onEvent?("pocket_unlock", nil)
    }

    func disengage() {
        guard isEngaged else { return }
        isEngaged = false
        isLocked = false
        UIDevice.current.isProximityMonitoringEnabled = false
        if let proximityObserver {
            NotificationCenter.default.removeObserver(proximityObserver)
        }
        proximityObserver = nil
        restoreBrightness()
    }

    /// Brightness is a system-wide setting: give it back whenever the app is not in front.
    func appDidResignActive() {
        restoreBrightness()
    }

    func appDidBecomeActive() {
        if isEngaged && isLocked {
            applyDim()
        }
    }

    private var screen: UIScreen? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.screen
    }

    private func applyDim() {
        guard dimScreen, let screen else { return }
        if savedBrightness == nil {
            savedBrightness = screen.brightness
        }
        screen.brightness = 0.05
    }

    private func restoreBrightness() {
        if let savedBrightness, let screen {
            screen.brightness = savedBrightness
        }
        savedBrightness = nil
    }
}
