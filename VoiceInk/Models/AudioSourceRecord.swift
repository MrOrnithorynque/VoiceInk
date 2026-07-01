// AudioSourceRecord — a captured audio source in a multi-source recording.
// Value type persisted as JSON on `Transcription.audioSourcesJSON`. Field-compatible
// with the future @Model so a Phase-6 relationship migration is a straight backfill.

import Foundation

/// One capture stream that contributed to a multi-source transcript: its role
/// (speaker label), its recorded WAV file, and the offset that aligns its local
/// (0-based) audio timeline onto the shared recording timeline.
struct AudioSourceRecord: Codable, Hashable, Identifiable {
    /// Speaker label / display name ("Me", "Them", …). Free string — N-ready.
    var role: String
    /// The 16 kHz / mono / Int16 WAV this source recorded.
    var fileURL: URL
    /// Seconds between the shared pre-start anchor and this source's first buffer;
    /// added to every segment's start/end to place it on the shared timeline.
    var t0Offset: TimeInterval
    /// Human-readable input device name, when the source is a microphone.
    var deviceName: String?
    /// Bundle identifier of the tapped app, when the source is per-app audio (Phase 5).
    var processBundleID: String?
    /// Capture kind: "mic" | "system" | "app". Optional so pre-Phase-5 rows decode as nil.
    var kind: String?

    var id: String { fileURL.absoluteString }

    init(role: String,
         fileURL: URL,
         t0Offset: TimeInterval,
         deviceName: String? = nil,
         processBundleID: String? = nil,
         kind: String? = nil) {
        self.role = role
        self.fileURL = fileURL
        self.t0Offset = t0Offset
        self.deviceName = deviceName
        self.processBundleID = processBundleID
        self.kind = kind
    }

    /// Whether this record came from a microphone. Used to pick the primary (mic) source so
    /// reordering can never drop the user's own voice track. Falls back to the field heuristic
    /// for legacy records that predate `kind`.
    var isMicrophone: Bool {
        if let kind { return kind == "mic" }
        return deviceName != nil && processBundleID == nil
    }
}
