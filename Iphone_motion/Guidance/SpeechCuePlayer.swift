//
//  SpeechCuePlayer.swift
//  Iphone_motion
//
//  Speaks protocol cues. The audio session uses the playback category so cues are heard with the
//  silent switch on, and ducks music the participant may be listening to.
//

import AVFoundation

@MainActor
final class SpeechCuePlayer: NSObject {
    private let synthesizer = AVSpeechSynthesizer()
    private var tokens: [ObjectIdentifier: Int] = [:]
    private let voice = AVSpeechSynthesisVoice(language: "en-GB") ?? AVSpeechSynthesisVoice(language: "en-US")

    var onStart: ((Int) -> Void)?
    var onFinish: ((Int) -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func activateAudio() {
        let audio = AVAudioSession.sharedInstance()
        try? audio.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers])
        try? audio.setActive(true)
    }

    func deactivateAudio() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Loads the voice ahead of the first cue so it starts without delay.
    func warmUp() {
        _ = voice?.name
    }

    func speak(_ text: String, token: Int) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        tokens[ObjectIdentifier(utterance)] = token
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        tokens.removeAll()
    }
}

extension SpeechCuePlayer: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            if let token = self.tokens[id] {
                self.onStart?(token)
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            if let token = self.tokens.removeValue(forKey: id) {
                self.onFinish?(token)
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            self.tokens.removeValue(forKey: id)
        }
    }
}
