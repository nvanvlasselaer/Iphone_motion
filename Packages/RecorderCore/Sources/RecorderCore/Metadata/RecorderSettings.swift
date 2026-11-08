//
//  RecorderSettings.swift
//  RecorderCore
//

import Foundation

/// User settings of the iPhone app (persisted as JSON). Missing keys decode to their defaults, so
/// settings survive app updates that add new options.
public struct RecorderSettings: Codable, Equatable, Sendable {
    public var mode: RecordingMode = .iphone
    public var subject = "S01"
    public var trial = "T01"
    public var notes = ""
    public var autoIncrementTrial = true

    public var iphonePlacement = Placement.defaultIphone
    public var watchPlacement = Placement.defaultWatch

    public var iphoneRateHz: Double = 100
    public var iphoneReferenceFrame = "xArbitraryZVertical"
    public var watchSensors = WatchSensorConfig.default
    public var maxDurationMin: Double = 90

    public var guidedProtocol = true
    public var presetId = "knee"
    public var trialOpenEnded = false
    public var trialDurationS: Double = 60
    public var includeSeatedStatic = false
    public var voiceCues = true

    public var pocketMode = true
    public var proximityBlanking = true
    public var dimScreen = true
    public var waterLock = true

    public init() {}

    /// Side used in the cues: the leg carrying the distal (Watch) sensor, else the iPhone's.
    public var instrumentedSide: BodySide {
        mode.usesWatch ? watchPlacement.side : iphonePlacement.side
    }

    public var protocolDefinition: ProtocolDefinition {
        ProtocolDefinition.preset(
            id: presetId,
            trialDurationS: trialOpenEnded ? nil : trialDurationS,
            includeSeatedStatic: includeSeatedStatic
        )
    }

    private enum CodingKeys: String, CodingKey {
        case mode, subject, trial, notes, autoIncrementTrial
        case iphonePlacement, watchPlacement
        case iphoneRateHz, iphoneReferenceFrame, watchSensors, maxDurationMin
        case guidedProtocol, presetId, trialOpenEnded, trialDurationS, includeSeatedStatic, voiceCues
        case pocketMode, proximityBlanking, dimScreen, waterLock
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var s = RecorderSettings()
        func load<T: Decodable>(_ key: CodingKeys, _ target: inout T) {
            if let value = try? c.decodeIfPresent(T.self, forKey: key) {
                target = value
            }
        }
        load(.mode, &s.mode)
        load(.subject, &s.subject)
        load(.trial, &s.trial)
        load(.notes, &s.notes)
        load(.autoIncrementTrial, &s.autoIncrementTrial)
        load(.iphonePlacement, &s.iphonePlacement)
        load(.watchPlacement, &s.watchPlacement)
        load(.iphoneRateHz, &s.iphoneRateHz)
        load(.iphoneReferenceFrame, &s.iphoneReferenceFrame)
        load(.watchSensors, &s.watchSensors)
        load(.maxDurationMin, &s.maxDurationMin)
        load(.guidedProtocol, &s.guidedProtocol)
        load(.presetId, &s.presetId)
        load(.trialOpenEnded, &s.trialOpenEnded)
        load(.trialDurationS, &s.trialDurationS)
        load(.includeSeatedStatic, &s.includeSeatedStatic)
        load(.voiceCues, &s.voiceCues)
        load(.pocketMode, &s.pocketMode)
        load(.proximityBlanking, &s.proximityBlanking)
        load(.dimScreen, &s.dimScreen)
        load(.waterLock, &s.waterLock)
        self = s
    }
}
