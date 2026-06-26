@preconcurrency import AVFoundation
import OSLog

/// Short, synthesized UI cues for the dictation lifecycle: a soft rising blip when
/// recording starts, a falling blip when it stops, and a brighter two-note chime
/// when a recording is locked into hands-free mode.
///
/// The tones are generated once at init — no bundled audio files — using a warm
/// timbre (fundamental + gentle harmonics) and a click-free pluck envelope, so
/// they read as smooth and modern. Kept deliberately quiet so they never compete
/// with the user's voice (or bleed loudly into the mic).
@MainActor
final class FeedbackSounds {
    enum Effect: CaseIterable { case start, stop, lock }

    /// Master level for every cue — subtle on purpose.
    private static let volume: Float = 0.45

    private var players: [Effect: AVAudioPlayer] = [:]
    private static let log = Logger(subsystem: "com.murmur.app", category: "sound")

    init() {
        for effect in Effect.allCases {
            guard let data = Self.wav(for: effect),
                  let player = try? AVAudioPlayer(data: data) else {
                Self.log.error("FeedbackSounds: failed to build player for \(String(describing: effect), privacy: .public)")
                continue
            }
            player.volume = Self.volume
            player.prepareToPlay()
            players[effect] = player
        }
    }

    /// Serial queue for starting playback off the main thread. The first
    /// `AVAudioPlayer.play()` to a Bluetooth output (AirPods) can block for a few hundred
    /// ms while CoreAudio wakes the idle route; doing it off-main keeps that from ever
    /// stalling the notch / waveform. The cue itself may land slightly late on cold
    /// AirPods — an accepted trade for a simple, non-blocking implementation.
    private static let playbackQueue = DispatchQueue(label: "com.murmur.app.feedback", qos: .userInitiated)

    /// Play a cue. Non-blocking; rewinds first so rapid re-triggers always restart.
    func play(_ effect: Effect) {
        guard let player = players[effect] else { return }
        Self.playbackQueue.async {
            player.currentTime = 0
            player.play()
        }
    }

    // MARK: - Synthesis

    /// One sine voice within a cue: its pitch, when it enters, how long it rings,
    /// and its relative loudness.
    private struct Partial { let freq: Double; let start: Double; let dur: Double; let gain: Double }

    /// Each cue is a two-note gesture built from pleasant perfect-fifth intervals:
    /// start rises, stop falls (its mirror), lock rises an octave higher + rings a
    /// touch longer to read as "locked in".
    private static func partials(for effect: Effect) -> [Partial] {
        switch effect {
        case .start: return [.init(freq: 587.33, start: 0,     dur: 0.11, gain: 1.0),   // D5
                             .init(freq: 880.00, start: 0.05,  dur: 0.13, gain: 0.9)]   // A5
        case .stop:  return [.init(freq: 880.00, start: 0,     dur: 0.10, gain: 0.9),   // A5
                             .init(freq: 587.33, start: 0.05,  dur: 0.13, gain: 1.0)]   // D5
        case .lock:  return [.init(freq: 783.99, start: 0,     dur: 0.10, gain: 0.9),   // G5
                             .init(freq: 1174.66, start: 0.045, dur: 0.18, gain: 1.0)]  // D6
        }
    }

    private static let sampleRate: Double = 44_100

    /// Render a cue to 16-bit PCM wrapped in a WAV container `AVAudioPlayer` reads.
    private static func wav(for effect: Effect) -> Data? {
        let parts = partials(for: effect)
        let total = parts.map { $0.start + $0.dur }.max() ?? 0
        let frameCount = Int((total + 0.02) * sampleRate)
        guard frameCount > 0 else { return nil }

        let attack = max(1, Int(0.006 * sampleRate)) // ~6 ms raised-cosine fade-in (no click)
        var buffer = [Float](repeating: 0, count: frameCount)

        for p in parts {
            let startFrame = Int(p.start * sampleRate)
            let durFrames = Int(p.dur * sampleRate)
            let tau = p.dur * 0.32                    // exponential pluck decay
            let fadeStart = durFrames - attack        // linear fade so the tail truly reaches 0
            for i in 0..<durFrames {
                let frame = startFrame + i
                guard frame < frameCount else { break }
                let t = Double(i) / sampleRate
                // Warm timbre: fundamental + soft 2nd/3rd harmonics.
                let phase = 2.0 * Double.pi * p.freq * t
                let sample = sin(phase) + 0.18 * sin(2 * phase) + 0.08 * sin(3 * phase)
                // Envelope: raised-cosine attack → exponential decay → linear tail fade.
                var env: Double
                if i < attack {
                    env = 0.5 * (1 - cos(Double.pi * Double(i) / Double(attack)))
                } else {
                    env = exp(-(t - Double(attack) / sampleRate) / tau)
                }
                if i > fadeStart { env *= Double(durFrames - i) / Double(attack) }
                buffer[frame] += Float(sample * env * p.gain)
            }
        }

        // Peak-normalize so every cue lands at a consistent, controlled level.
        let peak = buffer.map { abs($0) }.max() ?? 0
        if peak > 0 {
            let scale = Float(0.85) / peak
            for i in buffer.indices { buffer[i] *= scale }
        }

        return pcm16WAV(buffer)
    }

    /// Wrap mono Float samples ([-1, 1]) in a minimal 16-bit PCM WAV container.
    private static func pcm16WAV(_ samples: [Float]) -> Data {
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let sr = UInt32(sampleRate)
        let blockAlign = channels * (bitsPerSample / 8)
        let byteRate = sr * UInt32(blockAlign)
        let dataSize = UInt32(samples.count) * UInt32(blockAlign)

        var data = Data()
        func str(_ s: String) { data.append(contentsOf: s.utf8) }
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }

        str("RIFF"); u32(36 + dataSize); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(channels)
        u32(sr); u32(byteRate); u16(blockAlign); u16(bitsPerSample)
        str("data"); u32(dataSize)
        for s in samples {
            let clamped = max(-1, min(1, s))
            u16(UInt16(bitPattern: Int16(clamped * 32_767)))
        }
        return data
    }
}
