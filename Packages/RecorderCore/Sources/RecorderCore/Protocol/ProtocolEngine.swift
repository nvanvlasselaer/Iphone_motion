//
//  ProtocolEngine.swift
//  RecorderCore
//
//  Pure state machine of the guided protocol. The caller feeds inputs with the current uptime and
//  executes the returned effects (speech, Watch haptics, event logging). Each step: the cue is
//  spoken, and when it has finished (or its timeout elapsed) the measurement window opens.
//

import Foundation

public struct ProtocolEngine: Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case cueing(index: Int, token: Int, deadline: Double)
        case window(index: Int, start: Double, end: Double?, earliestEnd: Double?)
        case finished
        case aborted
        case interrupted
    }

    public enum Input: Equatable, Sendable {
        case start
        case cueStarted(token: Int)
        case cueFinished(token: Int)
        case tick
        /// Ends the trial step early (or an open-ended trial). Ignored outside the trial step.
        case advance(source: String)
        case abort(reason: String)
        /// The iPhone app left the foreground: stop guiding, recording continues.
        case appInterrupted
    }

    public enum Effect: Equatable, Sendable {
        case speak(text: String, token: Int)
        case stopSpeaking
        case watchStep(StepNotice)
        case log(event: String, step: String?, detail: String?)
        case trialEnded(source: String)
        case completed
    }

    public let definition: ProtocolDefinition
    public let instrumentedSide: BodySide
    public let watchPresent: Bool
    public let voice: Bool

    public private(set) var state: State = .idle
    public private(set) var timeline: [ProtocolTimelineEntry] = []
    private var token = 0
    private var reminderFired = false

    public init(definition: ProtocolDefinition, instrumentedSide: BodySide, watchPresent: Bool, voice: Bool) {
        self.definition = definition
        self.instrumentedSide = instrumentedSide
        self.watchPresent = watchPresent
        self.voice = voice
    }

    // MARK: Queries

    public var isTerminal: Bool {
        switch state {
        case .finished, .aborted, .interrupted: return true
        default: return false
        }
    }

    public var currentIndex: Int? {
        switch state {
        case .cueing(let index, _, _), .window(let index, _, _, _): return index
        default: return nil
        }
    }

    public var currentStep: StepDefinition? {
        currentIndex.map { definition.steps[$0] }
    }

    public var isInWindow: Bool {
        if case .window = state { return true }
        return false
    }

    /// Seconds left in the current window (nil for cues and open-ended windows).
    public func remaining(now: Double) -> Double? {
        if case .window(_, _, let end?, _) = state {
            return max(0, end - now)
        }
        return nil
    }

    /// The next moment at which `tick` changes something.
    public var nextDeadline: Double? {
        switch state {
        case .cueing(_, _, let deadline):
            return deadline
        case .window(let index, _, let end?, _):
            if let reminderAt = reminderTime(index: index, end: end), !reminderFired {
                return min(reminderAt, end)
            }
            return end
        default:
            return nil
        }
    }

    public func resolvedCue(for step: StepDefinition) -> String {
        CueCatalog.resolve(step.cue, instrumentedSide: instrumentedSide)
    }

    // MARK: Transitions

    public mutating func handle(_ input: Input, now: Double) -> [Effect] {
        switch (state, input) {
        case (.idle, .start):
            return [.log(event: "protocol_start", step: nil, detail: definition.presetId)] + beginStep(0, now: now)

        case (.cueing(let index, let current, _), .cueStarted(let received)) where received == current:
            return [.log(event: "cue_start", step: definition.steps[index].id, detail: nil)]

        case (.cueing(let index, let current, _), .cueFinished(let received)) where received == current:
            return [.log(event: "cue_end", step: definition.steps[index].id, detail: nil)] + openWindow(index, now: now)

        case (.cueing(let index, _, let deadline), .tick) where now >= deadline:
            return [.log(event: "cue_timeout", step: definition.steps[index].id, detail: nil)] + openWindow(index, now: now)

        case (.window(let index, _, let end?, _), .tick):
            if now >= end {
                return closeWindow(index, now: now, source: "timer")
            }
            if let reminderAt = reminderTime(index: index, end: end), !reminderFired, now >= reminderAt {
                reminderFired = true
                let step = definition.steps[index]
                var effects: [Effect] = [.log(event: "reminder", step: step.id, detail: step.reminderCue)]
                if voice, let cue = step.reminderCue {
                    token += 1
                    effects.append(.speak(text: cue, token: token))
                }
                return effects
            }
            return []

        case (.window(let index, _, _, let earliestEnd), .advance(let source)):
            let step = definition.steps[index]
            guard step.kind == .trial else {
                return [.log(event: "advance_ignored", step: step.id, detail: "not in trial")]
            }
            if let earliestEnd, now < earliestEnd {
                return [.log(event: "advance_ignored", step: step.id, detail: "minimum trial duration")]
            }
            return closeWindow(index, now: now, source: source)

        case (_, .advance):
            return [.log(event: "advance_ignored", step: currentStep?.id, detail: "not in trial")]

        case (_, .abort(let reason)) where !isTerminal && state != .idle:
            let step = currentStep?.id
            state = .aborted
            return [.stopSpeaking, .log(event: "protocol_aborted", step: step, detail: reason)]

        case (_, .appInterrupted) where !isTerminal && state != .idle:
            let step = currentStep?.id
            state = .interrupted
            return [.stopSpeaking, .log(event: "protocol_interrupted", step: step, detail: nil)]

        default:
            return []
        }
    }

    private func reminderTime(index: Int, end: Double) -> Double? {
        let step = definition.steps[index]
        guard step.reminderCue != nil, let lead = step.reminderLeadS else { return nil }
        return end - lead
    }

    private mutating func beginStep(_ index: Int, now: Double) -> [Effect] {
        guard index < definition.steps.count else {
            state = .finished
            return [.log(event: "protocol_complete", step: nil, detail: nil), .completed]
        }
        let step = definition.steps[index]
        var effects: [Effect] = [.log(event: "step_begin", step: step.id, detail: step.kind.rawValue)]
        if watchPresent {
            // Without a spoken cue the quiet window opens immediately, so no vibration then.
            let haptic = (!voice && step.quiet) ? nil : step.haptic
            effects.append(.watchStep(StepNotice(stepId: step.id, kind: step.kind, haptic: haptic)))
        }
        if voice {
            token += 1
            let text = resolvedCue(for: step)
            state = .cueing(index: index, token: token, deadline: now + CueCatalog.cueTimeout(text))
            effects.append(.speak(text: text, token: token))
            return effects
        }
        return effects + openWindow(index, now: now)
    }

    private mutating func openWindow(_ index: Int, now: Double) -> [Effect] {
        let step = definition.steps[index]
        if step.kind == .end {
            state = .finished
            return [.log(event: "protocol_complete", step: step.id, detail: nil), .completed]
        }
        reminderFired = false
        timeline.append(ProtocolTimelineEntry(step: step.id, windowStartUptimeS: now))
        if let duration = step.durationS {
            state = .window(index: index, start: now, end: now + duration, earliestEnd: nil)
            return [.log(event: "window_start", step: step.id, detail: FixedPoint.string(duration, decimals: 1))]
        }
        state = .window(index: index, start: now, end: nil, earliestEnd: now + (step.minDurationS ?? 0))
        return [.log(event: "window_start", step: step.id, detail: "open-ended")]
    }

    private mutating func closeWindow(_ index: Int, now: Double, source: String) -> [Effect] {
        let step = definition.steps[index]
        if !timeline.isEmpty {
            timeline[timeline.count - 1].windowEndUptimeS = now
        }
        var effects: [Effect] = [.log(event: "window_end", step: step.id, detail: nil)]
        if step.kind == .trial {
            effects.append(.log(event: "trial_end_requested", step: step.id, detail: source))
            effects.append(.trialEnded(source: source))
        }
        return effects + beginStep(index + 1, now: now)
    }
}
