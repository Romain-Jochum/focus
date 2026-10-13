import AppKit

/// The alarm of a check-in left unanswered for 30 s: a digital alarm clock, four 2.4 kHz beeps then a pause, looped until stopped.
/// Synthesized, so no sound file ships. While it sounds the output volume is at least 50% (`SystemVolume`).
@MainActor enum Alarm {
    static let wav = Synth.wav(seconds: 1) { t in
        let beep = 0.07, gap = 0.055, slot = t.truncatingRemainder(dividingBy: beep + gap)
        guard t < 4 * (beep + gap), slot < beep else { return 0 }
        let ramp = min(slot, beep - slot, 0.003) / 0.003   // 3 ms fades, so the beeps don't click
        return (sin(2 * .pi * 2400 * t) + 0.3 * sin(6 * .pi * 2400 * t)) / 0.92 * ramp * 0.95   // the two-tone sum peaks at 0.92
    }

    private static let sound: NSSound? = {
        let sound = NSSound(data: wav)
        sound?.loops = true
        return sound
    }()

    static func start() {
        guard sound?.isPlaying == false else { return }
        SystemVolume.raise()
        sound?.play()
    }

    static func stop() {
        sound?.stop()
        SystemVolume.restore()
    }
}
