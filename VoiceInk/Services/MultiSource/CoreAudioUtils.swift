// CoreAudioUtils — shared Core Audio helpers for the multi-source capture path (process-tap
// era, macOS 14.4+). Hoisted so SystemAudioTapRecorder and AudioProcessEnumerator share one
// implementation of PID→process-object translation.

import Foundation
import CoreAudio

enum CoreAudioUtils {
    /// Translate a PID to its Core Audio process object. Returns nil on miss (the property
    /// returns noErr + kAudioObjectUnknown for a PID with no audio process, not an error).
    @available(macOS 14.4, *)
    static func translatePIDToProcessObject(_ pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var inputPID = pid
        var processObject = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &inputPID, &size, &processObject)
        guard status == noErr, processObject != kAudioObjectUnknown else { return nil }
        return processObject
    }

    /// Read a `CFString` process/device property, or nil.
    static func stringProperty(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let str = value as String?, !str.isEmpty else { return nil }
        return str
    }

    /// Read a `UInt32` (e.g. a bool-ish flag) property, or nil.
    static func uint32Property(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    /// Read a `pid_t` property (e.g. `kAudioProcessPropertyPID`), or nil.
    static func pidProperty(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }
}
