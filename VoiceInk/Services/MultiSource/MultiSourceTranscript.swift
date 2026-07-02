// MultiSourceTranscript — the versioned envelope persisted for a multi-source recording.
// Wrapping segments + sources in a schema-versioned struct turns the eventual Phase-6
// migration (JSON blobs → @Model relationships) into a `switch schemaVersion` instead
// of a shape-guess, for the cost of one Int.

import Foundation

/// Versioned container for everything a multi-source transcript needs beyond the flat
/// `Transcription.text`. Encoded to JSON; stored on `Transcription.segmentsJSON`
/// (segments) — sources are stored separately on `audioSourcesJSON` but share this
/// version scheme.
struct MultiSourceTranscript: Codable, Hashable {
    /// Current on-disk schema version. Bump when `TranscriptSegment` / `AudioSourceRecord`
    /// gain fields or the persistence shape changes.
    /// v2: `TranscriptSegment.clusterId` (optional diarization cluster key; v1 rows decode
    /// with it nil, v1 builds ignore the extra key).
    static let currentSchemaVersion = 2

    var schemaVersion: Int
    var segments: [TranscriptSegment]
    var sources: [AudioSourceRecord]

    init(segments: [TranscriptSegment],
         sources: [AudioSourceRecord],
         schemaVersion: Int = MultiSourceTranscript.currentSchemaVersion) {
        self.schemaVersion = schemaVersion
        self.segments = segments
        self.sources = sources
    }
}

// MARK: - JSON helpers

extension MultiSourceTranscript {
    /// Encode the segment list as the JSON stored on `Transcription.segmentsJSON`.
    static func encodeSegments(_ segments: [TranscriptSegment]) -> String? {
        guard let data = try? JSONEncoder().encode(segments) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Encode the source list as the JSON stored on `Transcription.audioSourcesJSON`.
    static func encodeSources(_ sources: [AudioSourceRecord]) -> String? {
        guard let data = try? JSONEncoder().encode(sources) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decodeSegments(_ json: String?) -> [TranscriptSegment]? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([TranscriptSegment].self, from: data)
    }

    static func decodeSources(_ json: String?) -> [AudioSourceRecord]? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([AudioSourceRecord].self, from: data)
    }
}
