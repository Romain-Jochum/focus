import AppKit
import FocusCore

/// Sounds synthesized on first use, so no sound file ships: 16-bit mono PCM WAV data that `NSSound` plays at the system volume.
enum Synth {
    static let rate = 44_100

    /// `seconds` of audio from a sample function of time, clipped to ±1 and faded out over the last 80 ms so a ringing tail never clicks.
    static func wav(seconds: Double, _ sample: (Double) -> Double) -> Data {
        let pcm = (0..<Int(seconds * Double(rate))).map { i in
            let t = Double(i) / Double(rate)
            return Int16(max(-1, min(1, sample(t) * min((seconds - t) / 0.08, 1))) * 32_767)
        }
        let body = pcm.withUnsafeBufferPointer { Data(buffer: $0) }
        var wav = Data()
        func put(_ text: String) { wav.append(contentsOf: Array(text.utf8)) }
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        put("RIFF"); put(UInt32(36 + body.count)); put("WAVEfmt ")
        put(UInt32(16)); put(UInt16(1)); put(UInt16(1)); put(UInt32(rate)); put(UInt32(rate * 2)); put(UInt16(2)); put(UInt16(16))
        put("data"); put(UInt32(body.count))
        return wav + body
    }

    /// A struck bell `t` seconds after the strike: inharmonic partials, the higher ones dying first. Peaks near 1.
    static func bell(_ t: Double, _ freq: Double, decay: Double = 0.9) -> Double {
        guard t >= 0 else { return 0 }
        let attack = min(t / 0.004, 1)
        let partials: [(ratio: Double, amp: Double, decay: Double)] = [(1, 0.6, 1), (2, 0.25, 0.55), (2.76, 0.12, 0.35), (5.4, 0.05, 0.15)]
        return attack * partials.reduce(0) { $0 + $1.amp * exp(-t / (decay * $1.decay)) * sin(2 * .pi * freq * $1.ratio * t) }
    }

    /// A soft sine note with a gentle attack and release.
    static func tone(_ t: Double, _ freq: Double, length: Double) -> Double {
        guard t >= 0, t < length else { return 0 }
        let envelope = min(t / 0.02, 1) * min((length - t) / 0.12, 1)
        return envelope * (sin(2 * .pi * freq * t) + 0.15 * sin(4 * .pi * freq * t)) / 1.15
    }
}

/// The cues besides the check-in chime and the alarm (docs/design.md, Garden › Sounds).
@MainActor enum Sounds {
    private static var cache: [Cue: NSSound] = [:]

    static func play(_ cue: Cue) {
        let sound = cache[cue] ?? NSSound(data: wav(cue))
        cache[cue] = sound
        sound?.stop()
        sound?.play()
    }

    /// Note frequencies: C5 523, E5 659, G5 784, A5 880, C6 1047, E6 1319.
    static func wav(_ cue: Cue) -> Data {
        switch cue {
        case .resume:   // a soft two-tone, G5 then C6
            Synth.wav(seconds: 0.7) { t in 0.3 * (Synth.tone(t, 784, length: 0.3) + Synth.tone(t - 0.22, 1047, length: 0.45)) }
        case .good:     // two soft bells rising a fourth
            Synth.wav(seconds: 1.4) { t in 0.32 * (Synth.bell(t, 659, decay: 0.7) + Synth.bell(t - 0.16, 880, decay: 0.8)) }
        case .perfect:  // a rising bell arpeggio
            Synth.wav(seconds: 2) { t in
                0.28 * [523, 659, 784, 1047].enumerated().reduce(0) { $0 + Synth.bell(t - Double($1.offset) * 0.11, Double($1.element), decay: 0.9) }
            }
        case .levelUp:  // a longer arpeggio that rings into a chord
            Synth.wav(seconds: 3) { t in
                let run = [523, 659, 784, 1047, 1319].enumerated().reduce(0) { $0 + Synth.bell(t - Double($1.offset) * 0.1, Double($1.element), decay: 1.1) }
                let chord = [523, 784, 1047].reduce(0) { $0 + Synth.bell(t - 0.6, Double($1), decay: 1.6) }
                return 0.2 * run + 0.16 * chord
            }
        }
    }
}
