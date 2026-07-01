// AudioSourceConfig — declarative description of a capture source, and the seam that
// keeps source-kind knowledge out of VoiceInkEngine. In v1 the engine hands the factory
// a hard-coded [mic, system] array; Phase 5 decodes a user-configured array from
// UserDefaults and the engine never changes.

import Foundation

/// The kind of a capture source. Persisted configs store device **UIDs**, never
/// `AudioDeviceID`s — IDs are not stable across device reconnects (see the audio-capture
/// skill), so a saved config resolves its UID to an ID at record time.
enum AudioSourceKind: Codable, Hashable {
    /// A microphone. `deviceUID == nil` means "current default input".
    case microphone(deviceUID: String?)
    /// All system output minus VoiceInk itself (the v1 "Them").
    case systemGlobal
    /// A single application's audio, by bundle identifier (Phase 5).
    case app(bundleID: String)
}

/// A configured capture source: what to capture and how to label it.
struct AudioSourceConfig: Codable, Hashable, Identifiable {
    var id: UUID
    var kind: AudioSourceKind
    /// Speaker label shown in the transcript ("Me", "Them", …).
    var role: String

    init(id: UUID = UUID(), kind: AudioSourceKind, role: String) {
        self.id = id
        self.kind = kind
        self.role = role
    }

    /// The two-source MVP default: microphone → "Me", global system audio → "Them".
    static var mvpDefault: [AudioSourceConfig] {
        [
            AudioSourceConfig(kind: .microphone(deviceUID: nil), role: "Me"),
            AudioSourceConfig(kind: .systemGlobal, role: "Them")
        ]
    }

    // MARK: - Persistence

    private static let userDefaultsKey = "MultiSourceConfigs"

    /// User-configured source list (Phase 5), or nil if the user hasn't customized it.
    static func loadConfigs() -> [AudioSourceConfig]? {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else { return nil }
        return try? JSONDecoder().decode([AudioSourceConfig].self, from: data)
    }

    static func saveConfigs(_ configs: [AudioSourceConfig]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(configs), forKey: userDefaultsKey)
    }

    static func clearConfigs() {
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
    }

    /// The source list the engine should actually record: the user's custom configs when set
    /// and non-empty, otherwise the mic+system default.
    static var active: [AudioSourceConfig] {
        if let configs = loadConfigs(), !configs.isEmpty { return configs }
        return mvpDefault
    }

    /// True when this config captures system/app output (as opposed to a microphone).
    /// The coordinator keys system-mute/pause suppression on whether *any* active source
    /// is a tap — a two-microphone session must NOT suppress system mute.
    var isSystemTap: Bool {
        switch kind {
        case .systemGlobal, .app: return true
        case .microphone: return false
        }
    }

    var isMicrophone: Bool {
        if case .microphone = kind { return true }
        return false
    }

    var isSystemGlobal: Bool { kind == .systemGlobal }
}
