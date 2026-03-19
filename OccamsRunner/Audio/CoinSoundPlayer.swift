import AVFoundation

// MARK: - Coin Sound Player

/// Generates a pleasant two-note chime entirely in software — no audio file needed.
/// Two sine tones (E5 → G#5, a major third) with a fast attack and smooth exponential
/// decay so it sounds warm rather than harsh. Safe to call from any thread.
final class CoinSoundPlayer {
    static let shared = CoinSoundPlayer()

    private let engine = AVAudioEngine()
    private let mixer: AVAudioMixerNode

    private init() {
        mixer = engine.mainMixerNode
        mixer.outputVolume = 1.0
        do {
            try AVAudioSession.sharedInstance().setCategory(.ambient, options: .mixWithOthers)
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
        } catch {
            // Non-fatal — game continues without sound
        }
    }

    func playCollect() {
        // Two-note chime: E5 (659 Hz) → G#5 (830 Hz), major third interval
        scheduleNote(frequency: 659.26, startOffset: 0.0,   duration: 0.18)
        scheduleNote(frequency: 830.61, startOffset: 0.06,  duration: 0.22)
    }

    private func scheduleNote(frequency: Float, startOffset: TimeInterval, duration: TimeInterval) {
        let sampleRate: Double = 44100
        let totalFrames = AVAudioFrameCount(sampleRate * (duration + 0.1))

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!,
            frameCapacity: totalFrames
        ) else { return }

        buffer.frameLength = totalFrames

        let channelData = buffer.floatChannelData![0]
        let attackFrames = Int(sampleRate * 0.008)   // 8 ms attack
        let sustainEnd   = Int(sampleRate * duration)
        let totalInt     = Int(totalFrames)

        for i in 0..<totalInt {
            let t = Float(i) / Float(sampleRate)
            let sine = sin(2 * Float.pi * frequency * t)

            // Envelope: linear attack → exponential decay
            let envelope: Float
            if i < attackFrames {
                envelope = Float(i) / Float(attackFrames)
            } else {
                let decayT = Float(i - attackFrames) / Float(max(1, sustainEnd - attackFrames))
                envelope = exp(-4.5 * decayT)   // exponential decay → sounds natural
            }

            channelData[i] = sine * envelope * 0.35   // 0.35 keeps it gentle, not piercing
        }

        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: mixer, format: buffer.format)

        if !engine.isRunning {
            try? engine.start()
        }

        let startTime = AVAudioTime(
            hostTime: mach_absolute_time() + secondsToHostTime(startOffset)
        )
        player.scheduleBuffer(buffer, at: startTime, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            // engine.detach must run on the main thread. The completion callback fires on
            // AVAudioSession's background notification queue, so if we call detach there
            // while the main thread is inside engine.attach/connect for a subsequent
            // collection, both sides compete for AVAudioEngine's internal graph lock and
            // deadlock permanently — freezing all main-thread work (timers, UI, buttons).
            DispatchQueue.main.async { self?.engine.detach(player) }
        }
        player.play()
    }

    private func secondsToHostTime(_ seconds: TimeInterval) -> UInt64 {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let nanos = UInt64(seconds * 1_000_000_000)
        return nanos * UInt64(info.denom) / UInt64(info.numer)
    }
}
