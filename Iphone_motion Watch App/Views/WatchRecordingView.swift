//
//  WatchRecordingView.swift
//  Iphone_motion Watch App
//
//  Kept light: the elapsed time is drawn by the system, the sample count refreshes once per
//  second and not at all in always-on (reduced luminance) mode.
//

import SwiftUI

struct WatchRecordingView: View {
    @Environment(WatchController.self) private var controller
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @State private var confirmStop = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "record.circle")
                        .foregroundStyle(.red)
                    if let start = controller.recordingStartDate {
                        Text(timerInterval: start...Date.distantFuture, countsDown: false)
                            .font(.title3.monospacedDigit())
                    } else {
                        Text(controller.phase == .finalizing ? "Saving…" : "Starting…")
                    }
                }
                if let step = controller.stepId {
                    Text(step.replacingOccurrences(of: "_", with: " "))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if !isLuminanceReduced {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        let snapshot = controller.recorder.snapshot()
                        Text("\(snapshot.motion?.count ?? 0) samples")
                            .font(.footnote.monospacedDigit())
                    }
                }
                if controller.phase == .recording {
                    Button {
                        controller.endTrial()
                    } label: {
                        Label("End trial", systemImage: "flag.checkered")
                    }
                    Button {
                        controller.addMarker()
                    } label: {
                        Label("Marker (\(controller.markerCount))", systemImage: "mappin")
                    }
                    if controller.waterLockSupported {
                        Button {
                            controller.lockScreen()
                        } label: {
                            Label("Lock", systemImage: "drop.fill")
                        }
                    }
                    Button(role: .destructive) {
                        confirmStop = true
                    } label: {
                        Label("Stop", systemImage: "stop.circle")
                    }
                }
                if let error = controller.lastError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .confirmationDialog("Stop recording on the Watch?", isPresented: $confirmStop) {
            Button("Stop", role: .destructive) {
                controller.stopLocally()
            }
        }
    }
}
