import AVFoundation
import Foundation

/// Speaks driving warnings *over* whatever the driver is already listening to.
///
/// Previously the synthesizer used whatever audio session happened to be
/// active, so a spoken warning came out at the same level as Spotify or Apple
/// Maps and got buried — exactly the failure mode a safety alert can't have.
///
/// The session is configured the way navigation apps are meant to configure
/// it: `.playback` (so warnings are still audible with the ring switch
/// silenced — this is a collision warning, not a notification chime),
/// `.voicePrompt` mode (the mode Apple ships specifically for turn-by-turn
/// style prompts), and `.duckOthers` so other apps' audio drops in volume
/// rather than stopping. `.interruptSpokenAudioAndMixWithOthers` pauses
/// podcasts/audiobooks — where ducking would leave two voices overlapping —
/// while still merely ducking music.
///
/// The session is activated immediately before an utterance and deactivated
/// once the synthesizer goes idle, always with `.notifyOthersOnDeactivation`,
/// so the driver's music comes straight back to full volume instead of being
/// left permanently ducked or stopped.
/// `@unchecked Sendable`: `AVSpeechSynthesizerDelegate` requires Sendable, but
/// `AVSpeechSynthesizer` isn't. Safe here because every entry point is called
/// from the location-update path, which is serialised, and the only mutable
/// state (`didActivateSession`) is touched from that same path.
final class VoiceAlertPlayer: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()

    /// Deactivating an audio session can block briefly, so it's kept off the
    /// main thread — this runs on a driver's phone mid-drive.
    private let sessionQueue = DispatchQueue(label: "com.krishay.WildlifeAlert.audioSession")
    private var didActivateSession = false

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) {
        guard !text.isEmpty else { return }
        activateSession()
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        // Slightly above default so the warning cuts through road noise and
        // ducked-but-still-present music.
        utterance.volume = 1.0
        synthesizer.speak(utterance)
    }

    /// Stops any in-flight warning and hands audio focus straight back.
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        deactivateSessionIfIdle()
    }

    // MARK: - AVSpeechSynthesizerDelegate

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        deactivateSessionIfIdle()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        deactivateSessionIfIdle()
    }

    // MARK: - Audio session

    private func activateSession() {
        #if os(iOS)
        guard !didActivateSession else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playback,
                mode: .voicePrompt,
                options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers]
            )
            try session.setActive(true)
            didActivateSession = true
        } catch {
            // Ducking is an enhancement, never a precondition: if the session
            // can't be reconfigured (another app holds an exclusive session,
            // a call is in progress, etc.) we still speak on whatever session
            // exists rather than swallowing a safety warning.
            didActivateSession = false
            print("Audio session activation failed, speaking undicked: \(error.localizedDescription)")
        }
        #endif
    }

    private func deactivateSessionIfIdle() {
        #if os(iOS)
        // Multiple utterances can be queued back to back; only hand audio
        // focus back once the synthesizer has genuinely gone quiet, otherwise
        // the driver's music would pump up and down between sentences.
        guard didActivateSession, !synthesizer.isSpeaking else { return }
        didActivateSession = false
        sessionQueue.async {
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                print("Audio session deactivation failed: \(error.localizedDescription)")
            }
        }
        #endif
    }
}
