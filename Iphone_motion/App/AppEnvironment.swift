//
//  AppEnvironment.swift
//  Iphone_motion
//

import Foundation
import RecorderCore

/// Owns the app's long-lived services. Created once, at launch, by the app delegate so that
/// WatchConnectivity is active before any Watch file can arrive.
@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let settings = SettingsStore()
    let store = SessionStore()
    let recorder = PhoneMotionRecorder()
    let link = PhoneLink()
    let pocket = PocketModeController()
    let speech = SpeechCuePlayer()
    let runner = ProtocolRunner()
    let lifecycle = LifecycleMonitor()
    let launcher = WatchLauncher()
    private(set) lazy var ingestor = WatchIngestor(store: store, link: link)
    private(set) lazy var coordinator = SessionCoordinator(environment: self)

    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        store.prepareDirectories()
        link.inboxRoot = store.inboxRoot
        coordinator.bootstrap()
        link.activate()
    }
}
