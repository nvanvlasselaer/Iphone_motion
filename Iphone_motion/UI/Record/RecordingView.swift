//
//  RecordingView.swift
//  Iphone_motion
//

import RecorderCore
import SwiftUI

struct RecordingView: View {
    @Environment(SessionCoordinator.self) private var coordinator
    @Environment(ProtocolRunner.self) private var runner
    @Environment(PocketModeController.self) private var pocket
    @State private var confirmStop = false

    var body: some View {
        ZStack {
            content
            if pocket.isLocked {
                PocketOverlay()
                    .transition(.opacity)
            }
        }
        .statusBarHidden(pocket.isLocked)
        .persistentSystemOverlays(pocket.isLocked ? .hidden : .automatic)
        .defersSystemGestures(on: pocket.isLocked ? .all : [])
        .alert(
            "Notice",
            isPresented: Binding(
                get: { coordinator.alertMessage != nil && !pocket.isLocked },
                set: { if !$0 { coordinator.alertMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(coordinator.alertMessage ?? "")
        }
    }

    private var content: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        if let recording = coordinator.recording {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text(Format.duration(context.date.timeIntervalSince(recording.startDate)))
                                    .font(.system(size: 44, weight: .semibold, design: .monospaced))
                            }
                            Text(recording.folderName)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if runner.engine != nil {
                    Section("Protocol") {
                        ProtocolStatusView()
                        if runner.canEndTrial {
                            Button {
                                coordinator.endTrial()
                            } label: {
                                Label("End trial", systemImage: "flag.checkered")
                            }
                        }
                    }
                }

                if coordinator.recording?.mode.usesIphone == true {
                    Section("iPhone") {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            let snapshot = coordinator.phoneSnapshot
                            LabeledContent("Samples", value: "\(snapshot.stats?.count ?? 0)")
                            LabeledContent("Rate", value: Format.hertz(snapshot.stats?.achievedHz))
                            LabeledContent("Gaps", value: "\(snapshot.stats?.gapCount ?? 0)")
                            if let error = snapshot.writeError {
                                Text(error).foregroundStyle(.red)
                            }
                        }
                    }
                }

                if coordinator.recording?.mode.usesWatch == true {
                    Section("Apple Watch") {
                        WatchRecordingStatus()
                    }
                }

                Section {
                    Button {
                        coordinator.addMarker()
                    } label: {
                        Label("Add marker (\(coordinator.recording?.markerCount ?? 0))", systemImage: "mappin")
                    }
                    if pocket.isEngaged {
                        Button {
                            withAnimation { pocket.lock() }
                        } label: {
                            Label("Lock screen", systemImage: "lock")
                        }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        confirmStop = true
                    } label: {
                        Label("Stop recording", systemImage: "stop.circle")
                    }
                }
            }
            .navigationTitle(coordinator.phase == .stopping ? "Saving…" : "Recording")
            .disabled(coordinator.phase == .stopping)
            .overlay {
                if coordinator.phase == .stopping {
                    ProgressView("Saving the session…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .confirmationDialog("Stop the recording?", isPresented: $confirmStop, titleVisibility: .visible) {
                Button("Stop recording", role: .destructive) {
                    Task { await coordinator.stop(reason: "user") }
                }
            }
        }
    }
}

struct ProtocolStatusView: View {
    @Environment(ProtocolRunner.self) private var runner

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let stepId = runner.stepId {
                HStack {
                    Text("Step \(runner.stepNumber) of \(runner.stepCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(stepId.replacingOccurrences(of: "_", with: " "))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                if let text = runner.stepText {
                    Text(text)
                        .font(.headline)
                }
                if !runner.inWindow {
                    Text("Listening to the cue…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if let remaining = runner.remaining {
                    Text("\(Int(remaining.rounded(.up))) s")
                        .font(.system(size: 32, weight: .medium, design: .monospaced))
                } else {
                    Text("Until you end the trial")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if let outcome = runner.outcome {
                Text("Protocol \(outcome).")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct WatchRecordingStatus: View {
    @Environment(SessionCoordinator.self) private var coordinator

    var body: some View {
        let watch = coordinator.watch
        if let status = watch.status {
            LabeledContent("State", value: status.phase.rawValue)
            if let motion = status.motion {
                LabeledContent("Samples", value: "\(motion.count)")
                LabeledContent("Rate", value: Format.hertz(motion.hz))
                LabeledContent("Gaps", value: "\(motion.gaps)")
            }
            if let accel = status.accel {
                LabeledContent("800 Hz accel", value: "\(accel.count) · \(Format.hertz(accel.hz))")
            }
            LabeledContent("Battery", value: Format.percent(status.battery))
            if let error = status.lastError {
                Text(error).foregroundStyle(.orange)
            }
        } else {
            Text("Waiting for the Watch…")
                .foregroundStyle(.secondary)
        }
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            if let contact = watch.lastContactUptime {
                let age = MonotonicClock.uptime() - contact
                Text(age < 15 ? "Linked" : "No reply for \(Int(age)) s; the Watch keeps recording")
                    .font(.footnote)
                    .foregroundStyle(age < 15 ? Color.secondary : Color.orange)
            }
        }
    }
}
