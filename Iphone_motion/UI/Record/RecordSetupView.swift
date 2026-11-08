//
//  RecordSetupView.swift
//  Iphone_motion
//

import RecorderCore
import SwiftUI

struct RecordSetupView: View {
    @Environment(SessionCoordinator.self) private var coordinator
    @Environment(SettingsStore.self) private var settingsStore

    var body: some View {
        @Bindable var store = settingsStore
        let settings = store.value
        NavigationStack {
            Form {
                Section {
                    Picker("Record with", selection: $store.value.mode) {
                        ForEach(RecordingMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Sensors")
                } footer: {
                    Text(modeDescription(settings.mode))
                }

                Section {
                    LabeledContent("Subject") {
                        TextField("S01", text: $store.value.subject)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                    }
                    LabeledContent("Trial") {
                        TextField("T01", text: $store.value.trial)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                    }
                    TextField("Notes", text: $store.value.notes, axis: .vertical)
                } header: {
                    Text("Session")
                } footer: {
                    Text("Use a pseudonymised code for the subject, never a name.")
                }

                Section("Placement") {
                    if settings.mode.usesIphone {
                        NavigationLink {
                            PlacementEditor(title: "iPhone placement", placement: $store.value.iphonePlacement)
                        } label: {
                            LabeledContent("iPhone", value: settings.iphonePlacement.summary)
                        }
                    }
                    if settings.mode.usesWatch {
                        NavigationLink {
                            PlacementEditor(title: "Watch placement", placement: $store.value.watchPlacement)
                        } label: {
                            LabeledContent("Watch", value: settings.watchPlacement.summary)
                        }
                    }
                }

                if settings.mode.usesWatch {
                    Section("Apple Watch") {
                        WatchStatusCard()
                    }
                }

                Section("Protocol") {
                    Toggle("Guided calibration", isOn: $store.value.guidedProtocol)
                    if settings.guidedProtocol {
                        LabeledContent("Preset", value: settings.protocolDefinition.name)
                        LabeledContent("Trial", value: settings.trialOpenEnded ? "open-ended" : Format.duration(settings.trialDurationS))
                        Toggle("Voice cues", isOn: $store.value.voiceCues)
                    }
                }

                if settings.mode.usesIphone {
                    Section("iPhone live preview") {
                        LivePreviewChart(samples: coordinator.preview.elements)
                            .frame(height: 170)
                    }
                }

                if !coordinator.preflight.isEmpty {
                    Section("Checks") {
                        ForEach(coordinator.preflight) { item in
                            PreflightRow(item: item)
                        }
                    }
                }

                Section {
                    Button {
                        Task { await coordinator.start() }
                    } label: {
                        HStack {
                            Spacer()
                            if coordinator.phase == .starting {
                                ProgressView()
                                Text("Starting…")
                            } else {
                                Label("Start recording", systemImage: "record.circle")
                                    .bold()
                            }
                            Spacer()
                        }
                    }
                    .disabled(coordinator.phase != .idle || !Preflight.canStart(coordinator.preflight))
                }

                Section {
                    Image("experimental anatomy")
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 56)
                        .accessibilityLabel("Experimental Anatomy Research Group")
                }
                .listRowBackground(Color.clear)
            }
            .navigationTitle("Record")
            .onAppear { coordinator.recordTabAppeared() }
            .onDisappear { coordinator.recordTabDisappeared() }
            .onChange(of: store.value) { coordinator.settingsChanged() }
        }
    }

    private func modeDescription(_ mode: RecordingMode) -> String {
        switch mode {
        case .iphone: return "Records the iPhone's motion sensors (up to 100 Hz)."
        case .watch: return "Records the Apple Watch; the iPhone controls the session and speaks the cues."
        case .both: return "Records iPhone and Apple Watch together, with clock synchronization (e.g. thigh + shank)."
        }
    }
}

struct PreflightRow: View {
    let item: PreflightItem

    var body: some View {
        Label {
            Text(item.message)
        } icon: {
            switch item.severity {
            case .error: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .tip: Image(systemName: "lightbulb").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }
}

struct PlacementEditor: View {
    let title: String
    @Binding var placement: Placement

    var body: some View {
        Form {
            Picker("Segment", selection: $placement.segment) {
                ForEach(Segment.allCases, id: \.self) { segment in
                    Text(segment.title).tag(segment)
                }
            }
            Picker("Side", selection: $placement.side) {
                ForEach(BodySide.allCases, id: \.self) { side in
                    Text(side.title).tag(side)
                }
            }
            .pickerStyle(.segmented)
            Section("Site") {
                TextField("e.g. lateral, distal third", text: $placement.site)
            }
            Section {
                TextField("e.g. screen facing out, top up", text: $placement.orientation)
            } header: {
                Text("Orientation")
            } footer: {
                Text("Describe how the device is mounted. The calibration movements of the guided protocol make the analysis independent of the exact mounting.")
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

enum Format {
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    static func hertz(_ value: Double?) -> String {
        guard let value else { return "–" }
        return String(format: "%.1f Hz", value)
    }

    static func bytes(_ value: Int64?) -> String {
        guard let value else { return "–" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func percent(_ value: Float?) -> String {
        guard let value else { return "–" }
        return "\(Int((value * 100).rounded())) %"
    }
}
