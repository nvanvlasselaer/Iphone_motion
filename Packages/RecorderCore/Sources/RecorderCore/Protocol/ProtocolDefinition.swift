//
//  ProtocolDefinition.swift
//  RecorderCore
//
//  The guided calibration protocol: steps, spoken cues and durations.
//

import Foundation

public enum StepKind: String, Codable, Sendable {
    /// Standing still: gravity direction per segment.
    case staticPose = "static"
    /// Jumps: sharp impacts in every sensor, for time alignment.
    case sync
    /// Functional movement: joint axis estimation.
    case functional
    /// The measured activity.
    case trial
    /// Short pause between steps.
    case rest
    /// Final announcement; the protocol completes after it.
    case end
}

public enum HapticKind: String, Codable, Sendable {
    case start
    case stop
    case directionUp = "direction_up"
    case success
    case notification
    case click
}

public struct StepDefinition: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: StepKind
    /// Spoken text; `{instrumented}` and `{support}` are replaced by the leg sides.
    public var cue: String
    /// Window length after the cue; nil = open-ended (trial only, ended by the user).
    public var durationS: Double?
    /// Open-ended trial: earliest moment the user may end it.
    public var minDurationS: Double?
    /// Watch haptic played when the step begins (at the cue, before the window).
    public var haptic: HapticKind?
    /// True for windows that must be free of extra movement and vibration.
    public var quiet: Bool
    /// Optional reminder spoken `reminderLeadS` before the window ends.
    public var reminderCue: String?
    public var reminderLeadS: Double?

    public init(
        id: String,
        kind: StepKind,
        cue: String,
        durationS: Double?,
        minDurationS: Double? = nil,
        haptic: HapticKind? = nil,
        quiet: Bool = false,
        reminderCue: String? = nil,
        reminderLeadS: Double? = nil
    ) {
        self.id = id
        self.kind = kind
        self.cue = cue
        self.durationS = durationS
        self.minDurationS = minDurationS
        self.haptic = haptic
        self.quiet = quiet
        self.reminderCue = reminderCue
        self.reminderLeadS = reminderLeadS
    }
}

public struct ProtocolDefinition: Codable, Equatable, Sendable {
    public var presetId: String
    public var name: String
    public var steps: [StepDefinition]

    public init(presetId: String, name: String, steps: [StepDefinition]) {
        self.presetId = presetId
        self.name = name
        self.steps = steps
    }

    public static let presetIds = ["knee", "generic"]

    public static func preset(id: String, trialDurationS: Double?, includeSeatedStatic: Bool) -> ProtocolDefinition {
        id == "generic"
            ? generic(trialDurationS: trialDurationS)
            : knee(trialDurationS: trialDurationS, includeSeatedStatic: includeSeatedStatic)
    }

    /// Calibration for a two-segment joint (e.g. thigh + shank around the knee).
    public static func knee(trialDurationS: Double?, includeSeatedStatic: Bool = false) -> ProtocolDefinition {
        var steps = opening
        steps.append(StepDefinition(
            id: "functional", kind: .functional,
            cue: "Stand on your {support} leg. Slowly bend and straighten your {instrumented} knee, five times.",
            durationS: 15, haptic: .directionUp
        ))
        steps.append(StepDefinition(id: "rest_2", kind: .rest, cue: "Stand still on both legs.", durationS: 3, quiet: true))
        if includeSeatedStatic {
            steps.append(StepDefinition(
                id: "static_seated", kind: .staticPose,
                cue: "Sit down, feet flat on the floor, knees bent at a right angle, and hold still.",
                durationS: 5, quiet: true
            ))
            steps.append(StepDefinition(id: "stand_up", kind: .rest, cue: "Stand up.", durationS: 3))
        }
        steps.append(contentsOf: closing(trialDurationS: trialDurationS))
        return ProtocolDefinition(presetId: "knee", name: "Knee (static, jumps, functional, trial)", steps: steps)
    }

    /// Static poses and sync jumps around a trial, without the functional movement.
    public static func generic(trialDurationS: Double?) -> ProtocolDefinition {
        ProtocolDefinition(
            presetId: "generic",
            name: "Generic (static, jumps, trial)",
            steps: opening + closing(trialDurationS: trialDurationS)
        )
    }

    private static let opening: [StepDefinition] = [
        StepDefinition(
            id: "static_start", kind: .staticPose,
            cue: "Recording. Stand up straight, weight on both legs, and hold still.",
            durationS: 5, haptic: .start, quiet: true
        ),
        StepDefinition(id: "jumps_start", kind: .sync, cue: "Jump three times, with both feet.", durationS: 6, haptic: .directionUp),
        StepDefinition(id: "rest_1", kind: .rest, cue: "Hold still.", durationS: 3, quiet: true),
    ]

    private static func closing(trialDurationS: Double?) -> [StepDefinition] {
        let reminder = (trialDurationS ?? 0) >= 30
        let trialCue = trialDurationS == nil
            ? "Start the trial now. End it on the phone or the watch when you are finished."
            : "Start the trial now."
        return [
            StepDefinition(
                id: "trial", kind: .trial, cue: trialCue,
                durationS: trialDurationS,
                minDurationS: trialDurationS == nil ? 10 : nil,
                haptic: .start,
                reminderCue: reminder ? "Ten seconds left." : nil,
                reminderLeadS: reminder ? 10 : nil
            ),
            StepDefinition(id: "settle", kind: .rest, cue: "Trial complete. Slow down, stop, and stand still.", durationS: 10, haptic: .stop),
            StepDefinition(id: "jumps_end", kind: .sync, cue: "Jump three times, with both feet.", durationS: 6, haptic: .directionUp),
            StepDefinition(id: "static_end", kind: .staticPose, cue: "Hold still.", durationS: 5, quiet: true),
            StepDefinition(id: "done", kind: .end, cue: "Recording complete. Thank you.", durationS: 0, haptic: .success),
        ]
    }
}

public enum CueCatalog {
    /// Fills in `{instrumented}` (side of the instrumented leg) and `{support}` (the other leg).
    public static func resolve(_ template: String, instrumentedSide: BodySide) -> String {
        let instrumented: String
        let support: String
        switch instrumentedSide {
        case .left, .right:
            instrumented = instrumentedSide.rawValue
            support = instrumentedSide.opposite.rawValue
        case .center:
            instrumented = "instrumented"
            support = "other"
        }
        return template
            .replacingOccurrences(of: "{instrumented}", with: instrumented)
            .replacingOccurrences(of: "{support}", with: support)
    }

    /// Fallback time after which a cue counts as spoken if the synthesizer never reports it finished.
    public static func cueTimeout(_ text: String) -> Double {
        let words = text.split(whereSeparator: \.isWhitespace).count
        return Double(words) / 2.5 + 3.5
    }
}
