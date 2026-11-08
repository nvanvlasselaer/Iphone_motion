//
//  SessionListView.swift
//  Iphone_motion
//

import RecorderCore
import SwiftUI

struct SessionListView: View {
    @Environment(SessionCoordinator.self) private var coordinator
    @State private var sessions: [SessionSummary] = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(sessions) { session in
                    NavigationLink(value: session) {
                        SessionRow(summary: session)
                    }
                }
                .onDelete { offsets in
                    for index in offsets {
                        coordinator.delete(sessions[index])
                    }
                    reload()
                }
            }
            .overlay {
                if sessions.isEmpty {
                    ContentUnavailableView(
                        "No sessions yet",
                        systemImage: "waveform.path.ecg",
                        description: Text("Recorded sessions appear here and in the Files app: On My iPhone ▸ Iphone_motion ▸ Sessions.")
                    )
                }
            }
            .navigationTitle("Sessions")
            .navigationDestination(for: SessionSummary.self) { session in
                SessionDetailView(summary: session)
            }
            .refreshable {
                coordinator.processInbox()
                reload()
            }
            .onAppear(perform: reload)
            .onChange(of: coordinator.sessionsVersion) { reload() }
        }
    }

    private func reload() {
        sessions = coordinator.listSessions()
    }
}

struct SessionRow: View {
    let summary: SessionSummary

    var body: some View {
        let manifest = summary.manifest
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text([manifest.subject, manifest.trial].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.headline)
                Spacer()
                StatusBadge(status: manifest.status)
            }
            HStack(spacing: 8) {
                Image(systemName: icon(manifest.mode))
                Text(Date(timeIntervalSince1970: manifest.created.unixS), format: .dateTime.day().month().hour().minute())
                if let ended = manifest.ended {
                    Text(Format.duration(ended.unixS - manifest.created.unixS))
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private func icon(_ mode: RecordingMode) -> String {
        switch mode {
        case .iphone: return "iphone"
        case .watch: return "applewatch"
        case .both: return "iphone.and.arrow.forward"
        }
    }
}

struct StatusBadge: View {
    let status: SessionStatus

    var body: some View {
        Text(title)
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var title: String {
        switch status {
        case .recording: return "recording"
        case .awaitingWatchData: return "waiting for Watch"
        case .complete: return "complete"
        case .interrupted: return "interrupted"
        }
    }

    private var color: Color {
        switch status {
        case .recording: return .red
        case .awaitingWatchData: return .orange
        case .complete: return .green
        case .interrupted: return .yellow
        }
    }
}
