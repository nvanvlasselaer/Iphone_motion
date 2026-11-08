//
//  LifecycleMonitor.swift
//  Iphone_motion
//
//  Turns app and system state changes into session events and lets the coordinator flush data
//  before the app can be suspended.
//

import AVFoundation
import UIKit

@MainActor
final class LifecycleMonitor {
    /// (event, detail) to log in the session's event file.
    var onEvent: ((String, String?) -> Void)?
    var onActive: (() -> Void)?
    var onResignActive: (() -> Void)?
    var onBackground: (() -> Void)?
    var onForeground: (() -> Void)?

    private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }
        observe(UIApplication.didBecomeActiveNotification) { monitor, _ in
            monitor.onEvent?("app_active", nil)
            monitor.onActive?()
        }
        observe(UIApplication.willResignActiveNotification) { monitor, _ in
            monitor.onEvent?("app_inactive", nil)
            monitor.onResignActive?()
        }
        observe(UIApplication.didEnterBackgroundNotification) { monitor, _ in
            monitor.onEvent?("app_background", nil)
            monitor.runInBackgroundTask { monitor.onBackground?() }
        }
        observe(UIApplication.willEnterForegroundNotification) { monitor, _ in
            monitor.onEvent?("app_foreground", nil)
            monitor.onForeground?()
        }
        observe(UIApplication.protectedDataWillBecomeUnavailableNotification) { monitor, _ in
            monitor.onEvent?("protected_data_unavailable", nil)
            monitor.runInBackgroundTask { monitor.onBackground?() }
        }
        observe(UIAccessibility.guidedAccessStatusDidChangeNotification) { monitor, _ in
            monitor.onEvent?("guided_access", UIAccessibility.isGuidedAccessEnabled ? "on" : "off")
        }
        observe(ProcessInfo.thermalStateDidChangeNotification) { monitor, _ in
            monitor.onEvent?("thermal_state", Self.describe(ProcessInfo.processInfo.thermalState))
        }
        observe(.NSProcessInfoPowerStateDidChange) { monitor, _ in
            monitor.onEvent?("low_power", ProcessInfo.processInfo.isLowPowerModeEnabled ? "on" : "off")
        }
        observe(AVAudioSession.interruptionNotification) { monitor, note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let type = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            monitor.onEvent?("audio_interruption", type == .began ? "began" : "ended")
        }
    }

    private func observe(_ name: Notification.Name, _ handler: @escaping (LifecycleMonitor, Notification) -> Void) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self, note)
            }
        })
    }

    private func runInBackgroundTask(_ work: () -> Void) {
        let task = UIApplication.shared.beginBackgroundTask(withName: "FlushRecording")
        work()
        if task != .invalid {
            UIApplication.shared.endBackgroundTask(task)
        }
    }

    static func describe(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
