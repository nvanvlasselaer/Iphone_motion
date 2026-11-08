//
//  RootView.swift
//  Iphone_motion
//

import SwiftUI

struct RootView: View {
    @Environment(SessionCoordinator.self) private var coordinator

    private var isRecording: Bool {
        coordinator.phase == .recording || coordinator.phase == .stopping
    }

    var body: some View {
        TabView {
            RecordSetupView()
                .tabItem { Label("Record", systemImage: "record.circle") }
            SessionListView()
                .tabItem { Label("Sessions", systemImage: "folder") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .fullScreenCover(isPresented: Binding(get: { isRecording }, set: { _ in })) {
            RecordingView()
        }
        .alert(
            "Notice",
            isPresented: Binding(
                get: { coordinator.alertMessage != nil && !isRecording },
                set: { if !$0 { coordinator.alertMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(coordinator.alertMessage ?? "")
        }
    }
}
