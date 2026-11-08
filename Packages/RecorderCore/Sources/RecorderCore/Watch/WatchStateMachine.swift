//
//  WatchStateMachine.swift
//  RecorderCore
//
//  Recording life cycle of the Watch app as a pure reducer. The Watch app executes the effects in
//  the order returned. Stopping always runs: stop sensors (drain) → finalize files → enqueue
//  transfers → end workout, because the app may be suspended as soon as the workout ends.
//

import Foundation

public struct WatchStateMachine: Sendable {
    public enum Timer: String, Sendable {
        /// Ends an armed workout nobody started recording in.
        case arm
        /// Safety limit on the recording length.
        case maxDuration
    }

    public enum Event: Equatable, Sendable {
        /// The iPhone launched the app with a workout configuration (`startWatchApp`).
        case launched
        case armCommand
        case disarmCommand
        case startCommand(sid: UUID, maxDurationS: Double)
        case stopCommand(sid: UUID?, reason: String)
        /// Stop pressed on the Watch.
        case localStop
        case workoutRunning
        case workoutFailed(String)
        case firstSamples
        case timerFired(Timer)
        case lowBattery
        /// The sensors delivered their last batch and the journals are closed.
        case drained
    }

    public enum Effect: Equatable, Sendable {
        case startWorkout
        case endWorkout
        case startSensors(sid: UUID)
        case stopSensors(drainUntil: Double)
        case finalize(sid: UUID, reason: String, interrupted: Bool)
        case enqueueTransfers(sid: UUID)
        case schedule(Timer, at: Double)
        case cancel(Timer)
        case reply(accepted: Bool, error: String?)
        case log(event: String, detail: String?)
    }

    public private(set) var phase: WatchPhase = .idle
    public private(set) var sid: UUID?
    public private(set) var workoutRunning = false
    public private(set) var stopReason: String?
    public var armTimeoutS: Double

    private var stopInterrupted = false

    public init(armTimeoutS: Double = 600) {
        self.armTimeoutS = armTimeoutS
    }

    public mutating func handle(_ event: Event, now: Double) -> [Effect] {
        switch phase {
        case .idle: return idle(event, now: now)
        case .arming, .armed: return armedOrArming(event, now: now)
        case .starting, .recording: return active(event, now: now)
        case .finalizing: return finalizing(event, now: now)
        }
    }

    private mutating func idle(_ event: Event, now: Double) -> [Effect] {
        switch event {
        case .launched, .armCommand:
            phase = .arming
            var effects: [Effect] = [
                .startWorkout,
                .schedule(.arm, at: now + armTimeoutS),
                .log(event: "arming", detail: event == .launched ? "launch" : "command"),
            ]
            if event == .armCommand { effects.append(.reply(accepted: true, error: nil)) }
            return effects
        case .startCommand(let newSid, let maxDuration):
            phase = .starting
            sid = newSid
            return [
                .startWorkout,
                .schedule(.maxDuration, at: now + maxDuration),
                .log(event: "start_command", detail: newSid.uuidString),
                .reply(accepted: true, error: nil),
            ]
        case .stopCommand:
            return [.reply(accepted: true, error: nil), .log(event: "stop_ignored", detail: "idle")]
        case .disarmCommand:
            return [.log(event: "disarm_ignored", detail: "idle")]
        case .workoutRunning:
            // A workout we did not ask for (e.g. recovered after a crash): end it.
            return [.endWorkout, .log(event: "unexpected_workout", detail: nil)]
        default:
            return []
        }
    }

    private mutating func armedOrArming(_ event: Event, now: Double) -> [Effect] {
        switch event {
        case .workoutRunning:
            workoutRunning = true
            phase = .armed
            return [.log(event: "armed", detail: nil)]
        case .workoutFailed(let message):
            reset()
            return [.cancel(.arm), .log(event: "workout_failed", detail: message)]
        case .startCommand(let newSid, let maxDuration):
            phase = .starting
            sid = newSid
            var effects: [Effect] = [
                .cancel(.arm),
                .schedule(.maxDuration, at: now + maxDuration),
                .log(event: "start_command", detail: newSid.uuidString),
            ]
            if workoutRunning { effects.append(.startSensors(sid: newSid)) }
            effects.append(.reply(accepted: true, error: nil))
            return effects
        case .launched:
            return [.schedule(.arm, at: now + armTimeoutS), .log(event: "duplicate_launch", detail: phase.rawValue)]
        case .armCommand:
            return [.schedule(.arm, at: now + armTimeoutS), .reply(accepted: true, error: nil)]
        case .disarmCommand, .timerFired(.arm):
            let detail = event == .disarmCommand ? "disarm" : "arm_timeout"
            reset()
            return [.cancel(.arm), .endWorkout, .log(event: "disarmed", detail: detail)]
        case .stopCommand:
            return [.reply(accepted: true, error: nil), .log(event: "stop_ignored", detail: phase.rawValue)]
        default:
            return []
        }
    }

    private mutating func active(_ event: Event, now: Double) -> [Effect] {
        switch event {
        case .workoutRunning:
            guard !workoutRunning, let sid else { return [] }
            workoutRunning = true
            return [.startSensors(sid: sid)]
        case .firstSamples where phase == .starting:
            phase = .recording
            return [.log(event: "recording_start", detail: sid?.uuidString)]
        case .startCommand(let newSid, _):
            return newSid == sid
                ? [.reply(accepted: true, error: nil)]
                : [.reply(accepted: false, error: "busy with another session"), .log(event: "start_rejected", detail: newSid.uuidString)]
        case .stopCommand(let stopSid, let reason):
            guard stopSid == nil || stopSid == sid else {
                return [.reply(accepted: true, error: nil), .log(event: "stop_ignored", detail: "other session")]
            }
            return beginStop(reason: reason, interrupted: false, now: now) + [.reply(accepted: true, error: nil)]
        case .localStop:
            return beginStop(reason: "watch_button", interrupted: false, now: now)
        case .timerFired(.maxDuration):
            return beginStop(reason: "max_duration", interrupted: false, now: now)
        case .lowBattery:
            return beginStop(reason: "low_battery", interrupted: false, now: now)
        case .workoutFailed(let message):
            return [.log(event: "workout_failed", detail: message)]
                + beginStop(reason: "workout_failed", interrupted: true, now: now)
        case .launched:
            return [.log(event: "duplicate_launch", detail: phase.rawValue)]
        case .armCommand:
            return [.reply(accepted: true, error: nil)]
        default:
            return []
        }
    }

    private mutating func finalizing(_ event: Event, now: Double) -> [Effect] {
        switch event {
        case .drained:
            guard let sid else {
                reset()
                return [.endWorkout]
            }
            let reason = stopReason ?? "unknown"
            let interrupted = stopInterrupted
            reset()
            return [
                .finalize(sid: sid, reason: reason, interrupted: interrupted),
                .enqueueTransfers(sid: sid),
                .endWorkout,
                .log(event: "finalized", detail: reason),
            ]
        case .stopCommand:
            return [.reply(accepted: true, error: nil)]
        case .startCommand:
            return [.reply(accepted: false, error: "still saving the previous session")]
        case .armCommand:
            return [.reply(accepted: false, error: "still saving the previous session")]
        default:
            return []
        }
    }

    private mutating func beginStop(reason: String, interrupted: Bool, now: Double) -> [Effect] {
        phase = .finalizing
        stopReason = reason
        stopInterrupted = interrupted
        return [
            .cancel(.maxDuration),
            .stopSensors(drainUntil: now),
            .log(event: "recording_stop", detail: reason),
        ]
    }

    private mutating func reset() {
        phase = .idle
        sid = nil
        workoutRunning = false
        stopInterrupted = false
    }
}
