//
//  StateMachineTests.swift
//  RecorderCoreTests
//

import XCTest
@testable import RecorderCore

final class ProtocolEngineTests: XCTestCase {
    private func engine(trial: Double? = 60, side: BodySide = .right, watch: Bool = true, voice: Bool = true) -> ProtocolEngine {
        ProtocolEngine(definition: .knee(trialDurationS: trial), instrumentedSide: side, watchPresent: watch, voice: voice)
    }

    /// Drives the engine to the end: cues finish 2 s after they start, windows end on their timer.
    private func runToCompletion(_ e: inout ProtocolEngine, from start: Double = 0) -> (effects: [ProtocolEngine.Effect], now: Double) {
        var now = start
        var all = e.handle(.start, now: now)
        for _ in 0..<200 {
            switch e.state {
            case .cueing(_, let token, _):
                now += 2
                all += e.handle(.cueStarted(token: token), now: now - 2)
                all += e.handle(.cueFinished(token: token), now: now)
            case .window(_, _, let end?, _):
                if let deadline = e.nextDeadline, deadline < end {
                    now = deadline
                    all += e.handle(.tick, now: now)
                } else {
                    now = end
                    all += e.handle(.tick, now: now)
                }
            case .window(_, _, nil, _):
                now += 15
                all += e.handle(.advance(source: "phone"), now: now)
            default:
                return (all, now)
            }
        }
        XCTFail("protocol did not finish")
        return (all, now)
    }

    func testFirstStepSequence() {
        var e = engine()
        let effects = e.handle(.start, now: 0)
        let cue = "Recording. Stand up straight, weight on both legs, and hold still."
        XCTAssertEqual(effects, [
            .log(event: "protocol_start", step: nil, detail: "knee"),
            .log(event: "step_begin", step: "static_start", detail: "static"),
            .watchStep(StepNotice(stepId: "static_start", kind: .staticPose, haptic: .start)),
            .speak(text: cue, token: 1),
        ])
        XCTAssertEqual(e.state, .cueing(index: 0, token: 1, deadline: CueCatalog.cueTimeout(cue)))
        XCTAssertEqual(e.handle(.cueStarted(token: 1), now: 0.1), [.log(event: "cue_start", step: "static_start", detail: nil)])
        XCTAssertEqual(e.handle(.cueFinished(token: 1), now: 3), [
            .log(event: "cue_end", step: "static_start", detail: nil),
            .log(event: "window_start", step: "static_start", detail: "5.0"),
        ])
        XCTAssertEqual(e.state, .window(index: 0, start: 3, end: 8, earliestEnd: nil))
        XCTAssertEqual(e.remaining(now: 5), 3)
        XCTAssertEqual(e.handle(.tick, now: 7.9), [])
        let next = e.handle(.tick, now: 8)
        XCTAssertEqual(next.first, .log(event: "window_end", step: "static_start", detail: nil))
        XCTAssertTrue(next.contains(.speak(text: "Jump three times, with both feet.", token: 2)))
        XCTAssertTrue(next.contains(.watchStep(StepNotice(stepId: "jumps_start", kind: .sync, haptic: .directionUp))))
    }

    func testRunsWholeProtocolOnce() {
        var e = engine()
        let (effects, _) = runToCompletion(&e)
        XCTAssertEqual(e.state, .finished)
        XCTAssertEqual(effects.filter { $0 == .completed }.count, 1)
        XCTAssertEqual(effects.filter { $0 == .trialEnded(source: "timer") }.count, 1)
        let stepsWithWindows = e.definition.steps.filter { $0.kind != .end }.map(\.id)
        XCTAssertEqual(e.timeline.map(\.step), stepsWithWindows)
        XCTAssertTrue(e.timeline.allSatisfy { $0.windowEndUptimeS != nil })
        let trial = e.timeline.first { $0.step == "trial" }!
        XCTAssertEqual(trial.windowEndUptimeS! - trial.windowStartUptimeS, 60, accuracy: 1e-9)
        let reminders = effects.filter { if case .speak(let text, _) = $0 { return text == "Ten seconds left." }; return false }
        XCTAssertEqual(reminders.count, 1)
        XCTAssertEqual(e.handle(.tick, now: 10_000), [], "terminal state ignores input")
    }

    func testCueTimeoutOpensWindow() {
        var e = engine()
        _ = e.handle(.start, now: 0)
        guard case .cueing(_, _, let deadline) = e.state else { return XCTFail("expected cueing") }
        XCTAssertEqual(e.handle(.tick, now: deadline - 0.01), [])
        let effects = e.handle(.tick, now: deadline)
        XCTAssertEqual(effects.first, .log(event: "cue_timeout", step: "static_start", detail: nil))
        XCTAssertTrue(e.isInWindow)
    }

    func testStaleCueTokensAreIgnored() {
        var e = engine()
        _ = e.handle(.start, now: 0)
        XCTAssertEqual(e.handle(.cueStarted(token: 0), now: 0), [])
        _ = e.handle(.cueFinished(token: 1), now: 2)
        XCTAssertEqual(e.handle(.cueFinished(token: 1), now: 2.5), [])
    }

    func testOpenEndedTrialNeedsAdvanceAfterMinimum() {
        var e = engine(trial: nil)
        var now = 0.0
        _ = e.handle(.start, now: now)
        while e.currentStep?.kind != .trial || !e.isInWindow {
            switch e.state {
            case .cueing(_, let token, _):
                now += 1
                _ = e.handle(.cueFinished(token: token), now: now)
            case .window(_, _, let end?, _):
                now = end
                _ = e.handle(.tick, now: now)
            default:
                return XCTFail("unexpected state \(e.state)")
            }
        }
        XCTAssertNil(e.remaining(now: now))
        XCTAssertNil(e.nextDeadline)
        XCTAssertEqual(e.handle(.tick, now: now + 1000), [])
        XCTAssertEqual(e.handle(.advance(source: "watch"), now: now + 5), [.log(event: "advance_ignored", step: "trial", detail: "minimum trial duration")])
        let effects = e.handle(.advance(source: "watch"), now: now + 11)
        XCTAssertTrue(effects.contains(.trialEnded(source: "watch")))
        XCTAssertTrue(effects.contains(.log(event: "trial_end_requested", step: "trial", detail: "watch")))
        XCTAssertEqual(e.currentStep?.id, "settle")
    }

    func testAdvanceOutsideTrialIsIgnored() {
        var e = engine()
        _ = e.handle(.start, now: 0)
        _ = e.handle(.cueFinished(token: 1), now: 2)
        XCTAssertEqual(e.handle(.advance(source: "phone"), now: 3), [.log(event: "advance_ignored", step: "static_start", detail: "not in trial")])
        XCTAssertEqual(e.currentStep?.id, "static_start")
    }

    func testAbortAndInterruptFromAnyActiveState() {
        var cueing = engine()
        _ = cueing.handle(.start, now: 0)
        XCTAssertEqual(cueing.handle(.abort(reason: "stop pressed"), now: 1), [.stopSpeaking, .log(event: "protocol_aborted", step: "static_start", detail: "stop pressed")])
        XCTAssertEqual(cueing.state, .aborted)
        XCTAssertEqual(cueing.handle(.cueFinished(token: 1), now: 2), [])

        var window = engine()
        _ = window.handle(.start, now: 0)
        _ = window.handle(.cueFinished(token: 1), now: 2)
        XCTAssertEqual(window.handle(.appInterrupted, now: 3), [.stopSpeaking, .log(event: "protocol_interrupted", step: "static_start", detail: nil)])
        XCTAssertEqual(window.state, .interrupted)

        var idle = engine()
        XCTAssertEqual(idle.handle(.abort(reason: "x"), now: 0), [])
        XCTAssertEqual(idle.state, .idle)
    }

    func testNoWatchEffectsWithoutWatch() {
        var e = engine(watch: false)
        let (effects, _) = runToCompletion(&e)
        XCTAssertFalse(effects.contains { if case .watchStep = $0 { return true }; return false })
    }

    func testNoHapticsInQuietWindowsWithoutVoice() {
        var e = engine(voice: false)
        let (effects, _) = runToCompletion(&e)
        let notices = effects.compactMap { effect -> StepNotice? in
            if case .watchStep(let notice) = effect { return notice }
            return nil
        }
        let quiet = Set(e.definition.steps.filter(\.quiet).map(\.id))
        XCTAssertFalse(notices.isEmpty)
        for notice in notices where quiet.contains(notice.stepId) {
            XCTAssertNil(notice.haptic, "\(notice.stepId) is quiet")
        }
        XCTAssertEqual(notices.first { $0.stepId == "jumps_start" }?.haptic, .directionUp)
        XCTAssertFalse(effects.contains { if case .speak = $0 { return true }; return false })
    }

    func testReminderOnlyForLongTrials() {
        XCTAssertEqual(ProtocolDefinition.knee(trialDurationS: 60).steps.first { $0.kind == .trial }?.reminderCue, "Ten seconds left.")
        XCTAssertNil(ProtocolDefinition.knee(trialDurationS: 20).steps.first { $0.kind == .trial }?.reminderCue)
        XCTAssertNil(ProtocolDefinition.knee(trialDurationS: nil).steps.first { $0.kind == .trial }?.reminderCue)
    }

    func testSideSpecificCuesHaveNoPlaceholdersLeft() {
        let left = engine(side: .left)
        let functional = left.definition.steps.first { $0.id == "functional" }!
        XCTAssertEqual(left.resolvedCue(for: functional), "Stand on your right leg. Slowly bend and straighten your left knee, five times.")
        for presetId in ProtocolDefinition.presetIds {
            for side in BodySide.allCases {
                for step in ProtocolDefinition.preset(id: presetId, trialDurationS: nil, includeSeatedStatic: true).steps {
                    let text = CueCatalog.resolve(step.cue, instrumentedSide: side)
                    XCTAssertFalse(text.contains("{"), "\(presetId)/\(step.id): \(text)")
                }
            }
        }
        XCTAssertNil(ProtocolDefinition.generic(trialDurationS: 60).steps.first { $0.kind == .functional })
    }
}

final class WatchStateMachineTests: XCTestCase {
    private let sid = UUID()

    func testLaunchArmRecordStop() {
        var m = WatchStateMachine(armTimeoutS: 600)
        XCTAssertEqual(m.handle(.launched, now: 0), [.startWorkout, .schedule(.arm, at: 600), .log(event: "arming", detail: "launch")])
        XCTAssertEqual(m.phase, .arming)
        _ = m.handle(.workoutRunning, now: 1)
        XCTAssertEqual(m.phase, .armed)

        let start = m.handle(.startCommand(sid: sid, maxDurationS: 5400), now: 10)
        XCTAssertEqual(start, [
            .cancel(.arm), .schedule(.maxDuration, at: 5410), .log(event: "start_command", detail: sid.uuidString),
            .startSensors(sid: sid), .reply(accepted: true, error: nil),
        ])
        XCTAssertEqual(m.phase, .starting)
        _ = m.handle(.firstSamples, now: 11)
        XCTAssertEqual(m.phase, .recording)

        let stop = m.handle(.stopCommand(sid: sid, reason: "phone"), now: 100)
        XCTAssertEqual(stop, [.cancel(.maxDuration), .stopSensors(drainUntil: 100), .log(event: "recording_stop", detail: "phone"), .reply(accepted: true, error: nil)])
        XCTAssertEqual(m.phase, .finalizing)

        let drained = m.handle(.drained, now: 101)
        XCTAssertEqual(drained, [
            .finalize(sid: sid, reason: "phone", interrupted: false),
            .enqueueTransfers(sid: sid),
            .endWorkout,
            .log(event: "finalized", detail: "phone"),
        ], "files must be finalized and queued before the workout ends")
        XCTAssertEqual(m.phase, .idle)
        XCTAssertNil(m.sid)
    }

    func testStartWithoutArmWaitsForWorkout() {
        var m = WatchStateMachine()
        XCTAssertEqual(m.handle(.startCommand(sid: sid, maxDurationS: 60), now: 0), [
            .startWorkout, .schedule(.maxDuration, at: 60), .log(event: "start_command", detail: sid.uuidString), .reply(accepted: true, error: nil),
        ])
        XCTAssertEqual(m.handle(.workoutRunning, now: 1), [.startSensors(sid: sid)])
        XCTAssertEqual(m.handle(.workoutRunning, now: 2), [], "sensors start once")
    }

    func testStartIsIdempotentPerSession() {
        var m = WatchStateMachine()
        _ = m.handle(.startCommand(sid: sid, maxDurationS: 60), now: 0)
        XCTAssertEqual(m.handle(.startCommand(sid: sid, maxDurationS: 60), now: 1), [.reply(accepted: true, error: nil)])
        let other = UUID()
        XCTAssertEqual(m.handle(.startCommand(sid: other, maxDurationS: 60), now: 1), [
            .reply(accepted: false, error: "busy with another session"), .log(event: "start_rejected", detail: other.uuidString),
        ])
        XCTAssertEqual(m.sid, sid)
    }

    func testArmTimeoutEndsWorkout() {
        var m = WatchStateMachine()
        _ = m.handle(.launched, now: 0)
        _ = m.handle(.workoutRunning, now: 1)
        XCTAssertEqual(m.handle(.timerFired(.arm), now: 600), [.cancel(.arm), .endWorkout, .log(event: "disarmed", detail: "arm_timeout")])
        XCTAssertEqual(m.phase, .idle)
    }

    func testSafetyStopsAndFailures() {
        var m = WatchStateMachine()
        _ = m.handle(.startCommand(sid: sid, maxDurationS: 60), now: 0)
        _ = m.handle(.workoutRunning, now: 0)
        _ = m.handle(.firstSamples, now: 1)
        XCTAssertEqual(m.handle(.launched, now: 2), [.log(event: "duplicate_launch", detail: "recording")])
        XCTAssertEqual(m.handle(.stopCommand(sid: UUID(), reason: "phone"), now: 3), [.reply(accepted: true, error: nil), .log(event: "stop_ignored", detail: "other session")])
        XCTAssertEqual(m.phase, .recording)

        _ = m.handle(.workoutFailed("boom"), now: 4)
        XCTAssertEqual(m.phase, .finalizing)
        XCTAssertEqual(m.handle(.startCommand(sid: UUID(), maxDurationS: 60), now: 4.5), [.reply(accepted: false, error: "still saving the previous session")])
        XCTAssertEqual(m.handle(.drained, now: 5).first, .finalize(sid: sid, reason: "workout_failed", interrupted: true))

        var timed = WatchStateMachine()
        _ = timed.handle(.startCommand(sid: sid, maxDurationS: 60), now: 0)
        _ = timed.handle(.workoutRunning, now: 0)
        _ = timed.handle(.timerFired(.maxDuration), now: 60)
        XCTAssertEqual(timed.handle(.drained, now: 61).first, .finalize(sid: sid, reason: "max_duration", interrupted: false))
    }

    func testStopWhileIdleIsAcknowledged() {
        var m = WatchStateMachine()
        XCTAssertEqual(m.handle(.stopCommand(sid: sid, reason: "phone"), now: 0), [.reply(accepted: true, error: nil), .log(event: "stop_ignored", detail: "idle")])
        XCTAssertEqual(m.handle(.workoutRunning, now: 0), [.endWorkout, .log(event: "unexpected_workout", detail: nil)])
    }
}
