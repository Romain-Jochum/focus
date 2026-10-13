import AudioToolbox
import CoreAudio

/// Keeps the alarm audible: raises the default output device to at least 50% and unmutes it, then puts both back.
/// Devices without a software volume (some displays and USB interfaces) are left alone.
@MainActor enum SystemVolume {
    static let floor: Float32 = 0.5
    private static let volume = kAudioHardwareServiceDeviceProperty_VirtualMainVolume
    private static let mute = kAudioDevicePropertyMute
    /// What `raise` changed, so `restore` undoes only that.
    private static var saved: (device: AudioDeviceID, volume: Float32?, unmuted: Bool, set: Float32?)?

    static func raise() {
        guard saved == nil, let device = defaultOutput() else { return }
        let before: Float32? = read(device, volume)
        let muted = (read(device, mute) as UInt32?) == 1
        let raised = before.map { $0 < floor } == true && write(device, volume, floor)
        let unmuted = muted && write(device, mute, UInt32(0))
        guard raised || unmuted else { return }
        saved = (device, raised ? before : nil, unmuted, raised ? floor : nil)
    }

    /// Leaves the volume alone if it was changed while the alarm sounded.
    static func restore() {
        guard let s = saved else { return }
        saved = nil
        if let before = s.volume, let set = s.set, let now: Float32 = read(s.device, volume), abs(now - set) < 0.01 {
            _ = write(s.device, volume, before)
        }
        if s.unmuted { _ = write(s.device, mute, UInt32(1)) }
    }

    private static func defaultOutput() -> AudioDeviceID? {
        read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
    }

    private static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func read<T: Numeric & BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                                           scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput) -> T? {
        var addr = address(selector, scope)
        guard AudioObjectHasProperty(object, &addr) else { return nil }
        var value: T = 0
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func write<T: Numeric & BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: T) -> Bool {
        var addr = address(selector, kAudioDevicePropertyScopeOutput)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(object, &addr), AudioObjectIsPropertySettable(object, &addr, &settable) == noErr, settable.boolValue else { return false }
        var v = value
        return AudioObjectSetPropertyData(object, &addr, 0, nil, UInt32(MemoryLayout<T>.size), &v) == noErr
    }
}
