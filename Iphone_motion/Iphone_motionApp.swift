//
//  Iphone_motionApp.swift
//  Iphone_motion
//
//  Created by Nicolas Van Vlasselaer on 18/06/2024.
//

import SwiftUI

@main
struct MyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(AppEnvironment.shared.coordinator)
                .environment(AppEnvironment.shared.settings)
                .environment(AppEnvironment.shared.pocket)
                .environment(AppEnvironment.shared.runner)
        }
    }
}
