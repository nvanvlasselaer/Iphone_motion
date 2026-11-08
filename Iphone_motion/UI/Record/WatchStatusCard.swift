//
//  WatchStatusCard.swift
//  Iphone_motion
//

import RecorderCore
import SwiftUI

struct WatchStatusCard: View {
    @Environment(SessionCoordinator.self) private var coordinator

    var body: some View {
        let watch = coordinator.watch
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(color(watch))
                    .frame(width: 10, height: 10)
                Text(title(watch))
                    .font(.headline)
                Spacer()
                if watch.connecting {
                    ProgressView()
                } else if coordinator.phase == .idle {
                    Button(watch.reachable ? "Refresh" : "Connect") {
                        Task {
                            if watch.reachable {
                                await coordinator.hello()
                            } else {
                                await coordinator.connectWatch()
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!watch.installed)
                }
            }
            if let hello = watch.hello {
                Text(details(hello))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let status = watch.status {
                Text(statusLine(status))
                    .font(.footnote)
            }
            if let message = watch.message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if coordinator.watchHasOrphanRecording && coordinator.phase == .idle {
                Text("The Watch is still recording a session the iPhone no longer controls.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                Button("Stop that Watch recording", role: .destructive) {
                    Task { await coordinator.stopOrphanWatchRecording() }
                }
            }
            if let pending = watch.hello?.pendingSessions, !pending.isEmpty {
                Text("\(pending.count) session(s) on the Watch still to be sent.")
                    .font(.footnote)
                Button("Ask the Watch to send them again") {
                    pending.forEach(coordinator.requestResend)
                }
                .font(.footnote)
            }
        }
        .padding(.vertical, 4)
    }

    private func title(_ watch: SessionCoordinator.WatchState) -> String {
        if !watch.supported { return "Not available on this device" }
        if !watch.paired { return "No Apple Watch paired" }
        if !watch.installed { return "App not installed on the Watch" }
        if !watch.reachable { return "Not connected" }
        switch watch.status?.phase {
        case .armed?: return "Ready"
        case .arming?: return "Starting workout…"
        case .recording?: return "Recording"
        case .starting?: return "Starting…"
        case .finalizing?: return "Saving…"
        default: return "Connected"
        }
    }

    private func color(_ watch: SessionCoordinator.WatchState) -> Color {
        guard watch.reachable else { return watch.installed ? .orange : .gray }
        if let authorization = watch.hello?.authorization, !authorization.isReady { return .orange }
        return .green
    }

    private func details(_ hello: HelloReplyPayload) -> String {
        var parts = ["\(hello.device.modelIdentifier), \(hello.device.systemName) \(hello.device.systemVersion)"]
        if let wrist = hello.device.wristLocation, let crown = hello.device.crownOrientation {
            parts.append("\(wrist) wrist, crown \(crown)")
        }
        parts.append(hello.capabilities.batchedDeviceMotion ? "200 Hz device motion available" : "100 Hz device motion")
        if let free = hello.freeBytes {
            parts.append("\(Format.bytes(free)) free")
        }
        return parts.joined(separator: " · ")
    }

    private func statusLine(_ status: WatchStatus) -> String {
        var parts: [String] = []
        if let battery = status.battery {
            parts.append("Battery \(Format.percent(battery))")
        }
        if let motion = status.motion {
            parts.append("\(motion.count) samples, \(Format.hertz(motion.hz))")
        }
        if status.waterLock {
            parts.append("Water Lock on")
        }
        if let error = status.lastError {
            parts.append(error)
        }
        return parts.joined(separator: " · ")
    }
}
