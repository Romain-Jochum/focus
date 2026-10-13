import CoreAudio

/// Whether any app is recording from a microphone: CoreAudio's per-process input flag. No audio is read and no microphone is
/// opened, so no permission is needed.
enum Microphone {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    static func inUse() -> Bool {
        // Cheap gate: most of the time no audio device runs. A running device can also be playing (a headset's output),
        // so the processes are asked which of them records.
        guard list(system, kAudioHardwarePropertyDevices).contains(where: { (read($0, kAudioDevicePropertyDeviceIsRunningSomewhere) as UInt32?) == 1 }) else { return false }
        return list(system, kAudioHardwarePropertyProcessObjectList).contains { (read($0, kAudioProcessPropertyIsRunningInput) as UInt32?) == 1 }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func read<T: Numeric & BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var addr = address(selector)
        guard AudioObjectHasProperty(object, &addr) else { return nil }
        var value: T = 0
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func list(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }
}
