//
//  WatchRootView.swift
//  Iphone_motion Watch App
//

import SwiftUI

struct WatchRootView: View {
    @Environment(WatchController.self) private var controller

    var body: some View {
        NavigationStack {
            if controller.isRecording {
                WatchRecordingView()
            } else if !controller.permissionsGranted {
                PermissionsView()
            } else {
                IdleView()
            }
        }
    }
}

struct PermissionsView: View {
    @Environment(WatchController.self) private var controller
    @State private var requesting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Permissions")
                    .font(.headline)
                Text("To record when the iPhone starts a session, allow:")
                    .font(.footnote)
                Label("Health: workout sessions (\(controller.healthStatus))", systemImage: "heart")
                    .font(.footnote)
                Label("Motion & Fitness (\(controller.motionStatus))", systemImage: "figure.run")
                    .font(.footnote)
                Button {
                    requesting = true
                    Task {
                        await controller.requestPermissions()
                        requesting = false
                    }
                } label: {
                    if requesting {
                        ProgressView()
                    } else {
                        Text("Allow")
                    }
                }
                .disabled(requesting)
                Text("Nothing is saved to Health; the workout only keeps the sensors running.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct IdleView: View {
    @Environment(WatchController.self) private var controller

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Label(controller.phase == .armed ? "Ready" : "Idle", systemImage: controller.phase == .armed ? "checkmark.circle.fill" : "applewatch")
                    .font(.headline)
                    .foregroundStyle(controller.phase == .armed ? .green : .primary)
                Text("Start sessions from the iPhone app.")
                    .font(.footnote)
                Label(controller.phoneReachable ? "iPhone connected" : "iPhone not reachable", systemImage: "iphone")
                    .font(.footnote)
                    .foregroundStyle(controller.phoneReachable ? Color.secondary : Color.orange)
                if controller.pendingSessions > 0 {
                    Text("\(controller.pendingSessions) session(s) waiting to be sent to the iPhone.")
                        .font(.footnote)
                    Button("Send again") {
                        controller.resendPending()
                    }
                }
                if let error = controller.lastError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Text("Strapped to a leg? Turn off Wrist Detection (Settings ▸ Passcode) so the Watch does not lock.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("IMU")
    }
}
