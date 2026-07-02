import Foundation
import SwiftData

enum TranscriptionStatus: String, Codable {
    case pending
    case completed
    case failed
}

@Model
final class Transcription {
    var id: UUID
    var text: String
    var enhancedText: String?
    var timestamp: Date
    var duration: TimeInterval
    var audioFileURL: String?
    var transcriptionModelName: String?
    var aiEnhancementModelName: String?
    var promptName: String?
    var transcriptionDuration: TimeInterval?
    var enhancementDuration: TimeInterval?
    var aiRequestSystemMessage: String?
    var aiRequestUserMessage: String?
    var powerModeName: String?
    var powerModeEmoji: String?
    var transcriptionStatus: String?

    // Multi-source (two-source conversation) support. Additive optional scalars → safe under
    // SwiftData lightweight migration. nil for single-source and legacy/imported rows, which
    // then fall back to the classic Original/Enhanced rendering.
    var segmentsJSON: String?      // JSON [TranscriptSegment] — the merged labeled transcript
    var audioSourcesJSON: String?  // JSON [AudioSourceRecord] — per-source WAV + t0Offset + role

    init(text: String,
         duration: TimeInterval,
         enhancedText: String? = nil,
         audioFileURL: String? = nil,
         transcriptionModelName: String? = nil,
         aiEnhancementModelName: String? = nil,
         promptName: String? = nil,
         transcriptionDuration: TimeInterval? = nil,
         enhancementDuration: TimeInterval? = nil,
         aiRequestSystemMessage: String? = nil,
         aiRequestUserMessage: String? = nil,
         powerModeName: String? = nil,
         powerModeEmoji: String? = nil,
         transcriptionStatus: TranscriptionStatus = .pending) {
        self.id = UUID()
        self.text = text
        self.enhancedText = enhancedText
        self.timestamp = Date()
        self.duration = duration
        self.audioFileURL = audioFileURL
        self.transcriptionModelName = transcriptionModelName
        self.aiEnhancementModelName = aiEnhancementModelName
        self.promptName = promptName
        self.transcriptionDuration = transcriptionDuration
        self.enhancementDuration = enhancementDuration
        self.aiRequestSystemMessage = aiRequestSystemMessage
        self.aiRequestUserMessage = aiRequestUserMessage
        self.powerModeName = powerModeName
        self.powerModeEmoji = powerModeEmoji
        self.transcriptionStatus = transcriptionStatus.rawValue
    }
}

// MARK: - Multi-source helpers

extension Transcription {
    /// True when this row has a merged, speaker-labeled segment list to render.
    var hasSegments: Bool { segmentsJSON != nil }

    /// True when this row was recorded from multiple audio sources.
    var isMultiSource: Bool { (decodedSources?.count ?? 0) > 1 }

    var decodedSegments: [TranscriptSegment]? { MultiSourceTranscript.decodeSegments(segmentsJSON) }
    var decodedSources: [AudioSourceRecord]? { MultiSourceTranscript.decodeSources(audioSourcesJSON) }

    /// Distinct speaker count for the History "N speakers" badge (nil if not multi-source).
    /// Counts distinct segment speakers so diarized transcripts ("Me" + "Speaker 1/2") report
    /// every detected voice; falls back to source roles when segments are missing.
    var speakerCount: Int? {
        guard let sources = decodedSources, sources.count > 1 else { return nil }
        if let segments = decodedSegments, !segments.isEmpty {
            var labels = Set(segments.map { $0.speaker })
            // When a track was split into "Speaker N" clusters, diarizer-gap segments on the
            // same track still display the role ("Them"); that's spillover of an already
            // counted physical track, not an extra voice — drop the role from the count.
            for source in sources {
                let rolePrefix = "\(source.role)#"
                let hasMintedClusters = segments.contains {
                    ($0.clusterId?.hasPrefix(rolePrefix) ?? false) && $0.speaker != source.role
                }
                if hasMintedClusters { labels.remove(source.role) }
            }
            return labels.count
        }
        return Set(sources.map { $0.role }).count
    }

    /// Every audio file backing this row: the per-source WAVs when multi-source, otherwise
    /// the single `audioFileURL`. Used by cleanup/deletion so per-source files aren't orphaned.
    var allAudioFileURLs: [URL] {
        if let sources = decodedSources, !sources.isEmpty {
            return sources.map { $0.fileURL }
        }
        if let audioFileURL, let url = URL(string: audioFileURL) {
            return [url]
        }
        return []
    }
}
