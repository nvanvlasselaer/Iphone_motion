//
//  SessionDetailView.swift
//  Iphone_motion
//

import RecorderCore
import SwiftUI

private struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct SessionDetailView: View {
    @Environment(SessionCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @State private var summary: SessionSummary
    @State private var share: ShareItem?
    @State private var exporting = false
    @State private var confirmDelete = false
    @State private var errorMessage: String?

    init(summary: SessionSummary) {
        _summary = State(initialValue: summary)
    }

    var body: some View {
        let manifest = summary.manifest
        List {
            Section("Session") {
                LabeledContent("Status") { StatusBadge(status: manifest.status) }
                LabeledContent("Mode", value: manifest.mode.title)
                LabeledContent("Subject", value: manifest.subject)
                LabeledContent("Trial", value: manifest.trial)
                LabeledContent("Started", value: Date(timeIntervalSince1970: manifest.created.unixS).formatted(date: .abbreviated, time: .standard))
                if let ended = manifest.ended {
                    LabeledContent("Duration", value: Format.duration(ended.unixS - manifest.created.unixS))
                }
                if !manifest.notes.isEmpty {
                    Text(manifest.notes)
                }
            }

            if let iphone = manifest.devices.iphone {
                DeviceSectionView(title: "iPhone", section: iphone)
            }
            if let watch = manifest.devices.watch {
                DeviceSectionView(title: "Apple Watch", section: watch)
            } else if manifest.status == .awaitingWatchData {
                Section("Apple Watch") {
                    Text("Waiting for the Watch files. They are sent automatically when the Watch is near the iPhone.")
                        .foregroundStyle(.secondary)
                    Button("Ask the Watch to send them again") {
                        coordinator.requestResend(sid: manifest.sessionId)
                    }
                }
            }

            if let sync = manifest.clockSync {
                Section {
                    LabeledContent("Offset (Watch − iPhone)", value: String(format: "%.3f s", sync.offsetS))
                    LabeledContent("Drift", value: sync.driftEstimated ? String(format: "%.1f ppm", sync.driftPpm) : "not estimated")
                    LabeledContent("Best round trip", value: String(format: "%.0f ms", sync.minRttS * 1000))
                    LabeledContent("Fit residual (RMS)", value: String(format: "%.1f ms", sync.residualRmsS * 1000))
                    LabeledContent("Pings used / lost", value: "\(sync.nUsed) / \(sync.nLost) of \(sync.nPings)")
                } header: {
                    Text("Clock synchronization")
                } footer: {
                    Text("Align precisely with the jumps; see DATA_FORMAT.md.")
                }
            }

            if let record = manifest.guidedProtocol {
                Section("Protocol") {
                    LabeledContent("Preset", value: record.definition.name)
                    LabeledContent("Outcome", value: record.outcome ?? "–")
                    LabeledContent("Windows recorded", value: "\(record.timeline.count)")
                }
            }

            if !manifest.warnings.isEmpty {
                Section("Warnings") {
                    ForEach(Array(manifest.warnings.enumerated()), id: \.offset) { _, warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                    }
                }
            }

            Section("Files") {
                ForEach(manifest.files, id: \.name) { file in
                    VStack(alignment: .leading) {
                        Text(file.name).font(.callout.monospaced())
                        Text([file.rows.map { "\($0) rows" }, Optional(Format.bytes(file.bytes))].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Button {
                    Task { await exportZip() }
                } label: {
                    HStack {
                        Label("Share as .zip", systemImage: "square.and.arrow.up")
                        if exporting {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(exporting)
                Button("Delete session", role: .destructive) {
                    confirmDelete = true
                }
            }
        }
        .navigationTitle(manifest.subject.isEmpty ? manifest.folder : "\(manifest.subject) · \(manifest.trial)")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $share) { item in
            ActivityViewController(activityItems: [item.url])
        }
        .confirmationDialog("Delete this session and all its files?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                coordinator.delete(summary)
                dismiss()
            }
        }
        .alert("Export failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .onChange(of: coordinator.sessionsVersion) {
            if let updated = coordinator.listSessions().first(where: { $0.url == summary.url }) {
                summary = updated
            }
        }
    }

    private func exportZip() async {
        exporting = true
        defer { exporting = false }
        do {
            share = ShareItem(url: try await ExportService.zip(folder: summary.url))
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct DeviceSectionView: View {
    let title: String
    let section: DeviceSection

    var body: some View {
        Section(title) {
            LabeledContent("Device", value: "\(section.info.modelIdentifier), \(section.info.systemName) \(section.info.systemVersion)")
            LabeledContent("Placement", value: section.placement.summary)
            if let wrist = section.info.wristLocation, let crown = section.info.crownOrientation {
                LabeledContent("Watch settings", value: "\(wrist) wrist, crown \(crown)")
            }
            ForEach(Array(section.streams.enumerated()), id: \.offset) { _, stream in
                VStack(alignment: .leading, spacing: 2) {
                    Text(stream.file).font(.callout.monospaced())
                    Text(streamLine(stream))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func streamLine(_ stream: StreamInfo) -> String {
        var parts = [stream.sourceApi]
        if let frame = stream.referenceFrame {
            parts.append(frame)
        }
        if let stats = stream.stats {
            parts.append("\(stats.count) samples")
            parts.append(Format.hertz(stats.achievedHz))
            parts.append("\(stats.gapCount) gaps (max \(Int((stats.maxIntervalS * 1000).rounded())) ms)")
        } else if let hz = stream.reportedHz ?? stream.requestedHz {
            parts.append("\(Int(hz)) Hz requested")
        }
        return parts.joined(separator: " · ")
    }
}
