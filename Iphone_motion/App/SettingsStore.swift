//
//  SettingsStore.swift
//  Iphone_motion
//

import Foundation
import Observation
import RecorderCore

/// Persists `RecorderSettings` in UserDefaults.
@MainActor
@Observable
final class SettingsStore {
    var value: RecorderSettings {
        didSet { save() }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key = "RecorderSettings.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let stored = try? JSONDecoder().decode(RecorderSettings.self, from: data) {
            value = stored
        } else {
            value = RecorderSettings()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }
}
