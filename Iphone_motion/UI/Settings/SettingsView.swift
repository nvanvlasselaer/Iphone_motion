//
//  SettingsView.swift
//  Iphone_motion
//

import RecorderCore
import SwiftUI

struct SettingsView: View {
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(SessionCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var store = settingsStore
        let settings = store.value
        NavigationStack {
            Form {
                Section {
                    Picker("Sampling rate", selection: $store.value.iphoneRateHz) {
                        Text("50 Hz").tag(50.0)
                        Text("100 Hz").tag(100.0)
                    }
                    Picker("Reference frame", selection: $store.value.iphoneReferenceFrame) {
                        ForEach(ReferenceFrames.availableNames(), id: \.self) { name in
                            Text(ReferenceFrames.title(name)).tag(name)
                        }
                    }
                } header: {
                    Text("iPhone sensor")
                } footer: {
                    Text("100 Hz is the iPhone's maximum. The default reference frame uses no magnetometer, which avoids disturbances indoors and near treadmills.")
                }

                Section {
                    Picker("Sensor API", selection: $store.value.watchSensors.source) {
                        Text("High rate (200 Hz)").tag(WatchSensorSource.batched)
                        Text("Standard (≤ 100 Hz)").tag(WatchSensorSource.legacy)
                    }
                    if settings.watchSensors.source == .batched {
                        Toggle("800 Hz accelerometer", isOn: $store.value.watchSensors.accel800)
                    } else {
                        Picker("Sampling rate", selection: $store.value.watchSensors.legacyHz) {
                            Text("50 Hz").tag(50.0)
                            Text("100 Hz").tag(100.0)
                        }
                        Picker("Reference frame", selection: $store.value.watchSensors.legacyReferenceFrame) {
                            ForEach(watchFrames, id: \.self) { name in
                                Text(Self.frameTitle(name)).tag(name)
                            }
                        }
                    }
                    Toggle("Water Lock while recording", isOn: $store.value.waterLock)
                    Stepper("Safety limit: \(Int(settings.maxDurationMin)) min", value: $store.value.maxDurationMin, in: 10...240, step: 10)
                } header: {
                    Text("Apple Watch sensor")
                } footer: {
                    Text("High rate uses the Watch's 200 Hz device motion (Series 8, Ultra and later), with an arbitrary heading. Standard mode allows a magnetic reference frame. The 800 Hz accelerometer adds about 1 MB per minute. Water Lock stops accidental touches; turn the Digital Crown to release it.")
                }

                Section {
                    Picker("Preset", selection: $store.value.presetId) {
                        Text("Knee (with functional movement)").tag("knee")
                        Text("Generic (static + jumps)").tag("generic")
                    }
                    Toggle("Open-ended trial", isOn: $store.value.trialOpenEnded)
                    if !settings.trialOpenEnded {
                        Stepper("Trial: \(Format.duration(settings.trialDurationS))", value: $store.value.trialDurationS, in: 10...3600, step: 10)
                    }
                    if settings.presetId == "knee" {
                        Toggle("Seated static pose", isOn: $store.value.includeSeatedStatic)
                    }
                    Toggle("Voice cues", isOn: $store.value.voiceCues)
                    NavigationLink("Show the steps") {
                        ProtocolStepsView(definition: settings.protocolDefinition, side: settings.instrumentedSide)
                    }
                } header: {
                    Text("Guided protocol")
                } footer: {
                    Text("An open-ended trial is ended with the End trial button on the iPhone or the Watch.")
                }

                Section {
                    Toggle("Pocket mode", isOn: $store.value.pocketMode)
                    Toggle("Screen off when covered", isOn: $store.value.proximityBlanking)
                        .disabled(!settings.pocketMode)
                    Toggle("Dim the screen", isOn: $store.value.dimScreen)
                        .disabled(!settings.pocketMode)
                } header: {
                    Text("iPhone while strapped")
                } footer: {
                    Text("Pocket mode keeps the app recording in front: the screen never locks, is dimmed and ignores touches until you hold it for 2 s. A press of the side button would still lock the iPhone and pause recording; to prevent that, start Guided Access (Settings ▸ Accessibility) with the side and volume buttons disabled.")
                }

                Section {
                    Toggle("Next trial number after each session", isOn: $store.value.autoIncrementTrial)
                }

                Section {
                    NavigationLink("About and data format") {
                        AboutView()
                    }
                }
            }
            .navigationTitle("Settings")
            .disabled(coordinator.isBusy)
            .onChange(of: store.value) { coordinator.settingsChanged() }
        }
    }

    private var watchFrames: [String] {
        let reported = coordinator.watch.hello?.capabilities.legacyReferenceFrames ?? []
        return reported.isEmpty
            ? ["xArbitraryZVertical", "xArbitraryCorrectedZVertical", "xMagneticNorthZVertical", "xTrueNorthZVertical"]
            : reported
    }

    static func frameTitle(_ name: String) -> String {
        ReferenceFrames.title(name)
    }
}

struct ProtocolStepsView: View {
    let definition: ProtocolDefinition
    let side: BodySide

    var body: some View {
        List(definition.steps) { step in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(step.id.replacingOccurrences(of: "_", with: " "))
                        .font(.headline)
                    Spacer()
                    Text(step.durationS.map { step.kind == .end ? "" : Format.duration($0) } ?? "open")
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                }
                Text(CueCatalog.resolve(step.cue, instrumentedSide: side))
                    .font(.callout)
                if step.quiet {
                    Text("Quiet window: hold still, no Watch vibration")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(definition.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
