// AudioProcessEnumerator — lists running audio-capable processes (macOS 14.4+) so the
// settings UI can offer an app picker, and re-resolves a persisted bundle ID to live process
// objects at record time. Process AudioObjectIDs are ephemeral (invalid across relaunch), so
// configs persist only the bundle ID and re-resolve here — mirroring how mic UIDs are handled.

import Foundation
import CoreAudio
import AppKit

/// One tappable audio process for the picker.
struct AudioProcessInfo: Identifiable, Hashable {
    let id: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let name: String
    let isPlaying: Bool

    var icon: NSImage? {
        if let bundleID,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            return app.icon
        }
        return nil
    }
}

@available(macOS 14.4, *)
enum AudioProcessEnumerator {

    /// All audio processes except VoiceInk itself, currently-playing sorted first, then by name.
    static func list() -> [AudioProcessInfo] {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let runningByPID = Dictionary(
            NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var infos: [AudioProcessInfo] = []
        for objectID in processObjectList() {
            guard let pid = CoreAudioUtils.pidProperty(objectID, kAudioProcessPropertyPID), pid != selfPID else { continue }
            let bundleID = CoreAudioUtils.stringProperty(objectID, kAudioProcessPropertyBundleID)
            let isPlaying = (CoreAudioUtils.uint32Property(objectID, kAudioProcessPropertyIsRunningOutput) ?? 0) != 0
            let name = runningByPID[pid]?.localizedName
                ?? bundleID
                ?? "PID \(pid)"
            // Only surface processes we can name/attribute to an app (skip anonymous helpers).
            guard bundleID != nil || runningByPID[pid] != nil else { continue }
            infos.append(AudioProcessInfo(id: objectID, pid: pid, bundleID: bundleID, name: name, isPlaying: isPlaying))
        }

        return infos.sorted { lhs, rhs in
            if lhs.isPlaying != rhs.isPlaying { return lhs.isPlaying }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// Re-resolve a persisted bundle ID to the live process object(s) to tap. Includes the main
    /// app process plus any audio processes sharing that bundle ID (helper coverage for many
    /// apps). Returns [] if the app isn't running / has no audio process (caller degrades).
    static func resolveProcessObjects(forBundleID bundleID: String) -> [AudioObjectID] {
        let appPIDs = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map { $0.processIdentifier })
        var result: [AudioObjectID] = []
        for objectID in processObjectList() {
            let objBundle = CoreAudioUtils.stringProperty(objectID, kAudioProcessPropertyBundleID)
            let objPID = CoreAudioUtils.pidProperty(objectID, kAudioProcessPropertyPID)
            if objBundle == bundleID || (objPID.map { appPIDs.contains($0) } ?? false) {
                result.append(objectID)
            }
        }
        return Array(Set(result))
    }

    // MARK: - Raw list

    private static func processObjectList() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        let status = ids.withUnsafeMutableBytes { buffer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, buffer.baseAddress!)
        }
        guard status == noErr else { return [] }
        return ids.filter { $0 != kAudioObjectUnknown }
    }
}
