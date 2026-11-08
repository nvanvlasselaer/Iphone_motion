//
//  PocketOverlay.swift
//  Iphone_motion
//
//  Black, touch-absorbing screen shown while the iPhone is strapped to the body. Hold for 2 s to
//  unlock.
//

import SwiftUI

struct PocketOverlay: View {
    @Environment(SessionCoordinator.self) private var coordinator
    @Environment(ProtocolRunner.self) private var runner
    @Environment(PocketModeController.self) private var pocket
    @State private var isPressing = false

    private let dim = Color(white: 0.35)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 18) {
                Spacer()
                Text("Recording")
                    .font(.title3)
                    .foregroundStyle(dim)
                if let recording = coordinator.recording {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Format.duration(context.date.timeIntervalSince(recording.startDate)))
                            .font(.system(size: 52, weight: .light, design: .monospaced))
                            .foregroundStyle(dim)
                    }
                }
                if let stepId = runner.stepId {
                    Text(stepId.replacingOccurrences(of: "_", with: " "))
                        .font(.headline)
                        .foregroundStyle(dim)
                }
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: isPressing ? "lock.open" : "lock")
                        .font(.system(size: 34))
                    Text("Hold 2 s to unlock")
                        .font(.footnote)
                }
                .foregroundStyle(isPressing ? Color.white : dim)
                .padding(28)
                .background(Circle().stroke(dim, lineWidth: 1))
                .onLongPressGesture(minimumDuration: 2) {
                    withAnimation { pocket.unlock() }
                } onPressingChanged: { pressing in
                    isPressing = pressing
                }
                .padding(.bottom, 48)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {}
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Screen locked while recording. Hold the lock button for 2 seconds to unlock.")
    }
}
