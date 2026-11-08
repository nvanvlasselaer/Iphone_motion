//
//  IphoneMotionWatchApp.swift
//  Iphone_motion Watch App
//

import SwiftUI

@main
struct IphoneMotionWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(WatchController.shared)
        }
    }
}
