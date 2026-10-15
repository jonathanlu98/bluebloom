// The system default output device and the Blue Bloom virtual device: find, switch, and remember the previous output so it can be restored.
import BlueBloomEngine
import CoreAudio
import Foundation

enum AudioOutput {
    private static let previousOutputKey = "PreviousOutputUID"

    static func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T,
                            scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
        return status == noErr ? value : nil
    }

    static func device(uid: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<CFString>.size), $0, &size, &device)
        }
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    static var virtualDevice: AudioObjectID? { device(uid: VirtualDeviceUID) }

    static var defaultOutput: AudioObjectID? {
        property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(kAudioObjectUnknown))
    }

    static func uid(of device: AudioObjectID) -> String? {
        property(device, kAudioDevicePropertyDeviceUID, "" as CFString).map { $0 as String }
    }

    static func name(of device: AudioObjectID) -> String? {
        property(device, kAudioObjectPropertyName, "" as CFString).map { $0 as String }
    }

    static var isBlueBloomDefault: Bool {
        guard let virtual = virtualDevice, let current = defaultOutput else { return false }
        return virtual == current
    }

    static var defaultOutputName: String? { defaultOutput.flatMap(name(of:)) }

    // The device's current sample rate (Hz)
    static func nominalSampleRate(of device: AudioObjectID) -> Double? {
        property(device, kAudioDevicePropertyNominalSampleRate, Float64(0))
    }

    // Format of the device's first output stream: bit depth, and whether it is float (the Blue Bloom virtual device is fixed at 32-bit float, see Driver/BlueBloomDevice.c)
    static func outputSampleFormat(of device: AudioObjectID) -> (bits: Int, isFloat: Bool)? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size >= UInt32(MemoryLayout<AudioStreamID>.size) else { return nil }
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &streams) == noErr, let stream = streams.first,
              let format = property(stream, kAudioStreamPropertyPhysicalFormat, AudioStreamBasicDescription()), format.mBitsPerChannel > 0 else {
            return nil
        }
        return (Int(format.mBitsPerChannel), format.mFormatFlags & kAudioFormatFlagIsFloat != 0)
    }

    @discardableResult
    static func setDefaultOutput(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value = device
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                                UInt32(MemoryLayout<AudioObjectID>.size), &value)
        return status == noErr
    }

    // Remember the previous output before switching to Blue Bloom; restore it when streaming stops
    static func switchToBlueBloom() {
        guard let virtual = virtualDevice, let current = defaultOutput, current != virtual else { return }
        if let previous = uid(of: current) { UserDefaults.standard.set(previous, forKey: previousOutputKey) }
        if setDefaultOutput(virtual) { BBLogMessage("Sound output switched to Blue Bloom (was \(name(of: current) ?? "?"))") }
    }

    static func restorePrevious() {
        guard isBlueBloomDefault else { return }
        let previous = UserDefaults.standard.string(forKey: previousOutputKey).flatMap(device(uid:)).flatMap { outputStreamCount($0) > 0 ? $0 : nil }
        // The previous output is gone (e.g. unplugged headphones): fall back to the system's default built-in speakers
        let target = previous ?? builtInOutput
        guard let target else { return }
        if setDefaultOutput(target) { BBLogMessage("Sound output restored to \(name(of: target) ?? "?")") }
    }

    private static var builtInOutput: AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return nil }
        return devices.first { device in
            property(device, kAudioDevicePropertyTransportType, UInt32(0)) == kAudioDeviceTransportTypeBuiltIn && outputStreamCount(device) > 0
        }
    }

    // Input-only devices (microphones) cannot be outputs: decide by the number of output streams
    static func outputStreamCount(_ device: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioObjectID>.size
    }
}

// The variadic BBLog cannot be used from Swift
func BBLogMessage(_ message: String) {
    BBLogLine(message)
}
