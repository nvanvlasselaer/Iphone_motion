//
//  ProtocolRunner.swift
//  Iphone_motion
//
//  Drives the pure `ProtocolEngine` with the device uptime: wakes up at the engine's deadlines
//  (and at least every 0.25 s for the countdown) and hands its effects to the coordinator.
//

import Foundation
import Observation
import RecorderCore

@MainActor
@Observable
final class ProtocolRunner {
    private(set) var engine: ProtocolEngine?
    private(set) var stepId: String?
    private(set) var stepKind: StepKind?
    private(set) var stepText: String?
    private(set) var stepNumber = 0
    private(set) var stepCount = 0
    private(set) var remaining: Double?
    private(set) var inWindow = false

    @ObservationIgnored private var onEffect: ((ProtocolEngine.Effect) -> Void)?
    @ObservationIgnored private var loop: Task<Void, Never>?

    var isActive: Bool {
        guard let engine else { return false }
        return engine.state != .idle && !engine.isTerminal
    }

    var canEndTrial: Bool {
        isActive && stepKind == .trial && inWindow
    }

    var timeline: [ProtocolTimelineEntry] {
        engine?.timeline ?? []
    }

    var outcome: String? {
        switch engine?.state {
        case .finished?: return "complete"
        case .aborted?: return "aborted"
        case .interrupted?: return "interrupted"
        default: return nil
        }
    }

    func start(
        definition: ProtocolDefinition,
        instrumentedSide: BodySide,
        watchPresent: Bool,
        voice: Bool,
        onEffect: @escaping (ProtocolEngine.Effect) -> Void
    ) {
        loop?.cancel()
        engine = ProtocolEngine(definition: definition, instrumentedSide: instrumentedSide, watchPresent: watchPresent, voice: voice)
        stepCount = definition.steps.count
        self.onEffect = onEffect
        send(.start)
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let engine = self.engine, !engine.isTerminal else { return }
                let now = MonotonicClock.uptime()
                let wait = min(max((engine.nextDeadline ?? now + 0.25) - now, 0.01), 0.25)
                try? await Task.sleep(nanoseconds: UInt64(wait * 1e9))
                if Task.isCancelled { return }
                self.send(.tick)
            }
        }
    }

    func send(_ input: ProtocolEngine.Input) {
        guard var engine else { return }
        let effects = engine.handle(input, now: MonotonicClock.uptime())
        self.engine = engine
        refresh()
        for effect in effects {
            onEffect?(effect)
        }
    }

    /// Stops the timer; the engine is kept so its timeline can be saved.
    func finish() {
        loop?.cancel()
        loop = nil
        onEffect = nil
        refresh()
    }

    func reset() {
        finish()
        engine = nil
        refresh()
    }

    private func refresh() {
        let step = engine?.currentStep
        stepId = step?.id
        stepKind = step?.kind
        stepText = step.flatMap { step in engine?.resolvedCue(for: step) }
        stepNumber = (engine?.currentIndex).map { $0 + 1 } ?? 0
        remaining = engine?.remaining(now: MonotonicClock.uptime())
        inWindow = engine?.isInWindow ?? false
    }
}
