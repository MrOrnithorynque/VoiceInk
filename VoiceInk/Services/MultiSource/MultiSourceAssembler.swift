// MultiSourceAssembler — turns captured sources into a merged transcript. Transcribes each
// source's WAV with segment timestamps (VAD-off), applies per-segment cleaning, and merges
// into ordered segments + flat labeled text. Lives here (not in VoiceInkEngine) so the
// engine's stop-branch stays a thin selector rather than accreting a second assembly path.

import Foundation
import SwiftData
import os

@MainActor
struct MultiSourceAssembler {

    enum AssemblerError: LocalizedError {
        case notSegmentCapable
        var errorDescription: String? {
            switch self {
            case .notSegmentCapable: return "Selected model cannot produce timestamped segments"
            }
        }
    }

    let serviceRegistry: TranscriptionServiceRegistry
    let modelContext: ModelContext
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MultiSourceAssembler")

    /// Whether a multi-source assembly can run for this model (segment-capable, i.e. local).
    func canAssemble(model: any TranscriptionModel) -> Bool {
        serviceRegistry.segmentingService(for: model) != nil
    }

    /// Transcribe every source and merge. Passes run sequentially (whisper's actor serializes
    /// them anyway) → ~N× single-source latency, surfaced honestly by the caller's UI.
    func assemble(sources: [AudioSourceRecord],
                  model: any TranscriptionModel) async throws -> (segments: [TranscriptSegment], flatText: String) {
        guard let service = serviceRegistry.segmentingService(for: model) else {
            throw AssemblerError.notSegmentCapable
        }

        var perSource: [TranscriptMerger.SourceSegments] = []
        for record in sources {
            let raw = try await service.transcribeWithSegments(audioURL: record.fileURL, model: model)
            logger.notice("Source '\(record.role, privacy: .public)': \(raw.count, privacy: .public) segments")
            perSource.append(.init(record: record, segments: raw))
        }

        let clean = makeCleaner()
        let merged = TranscriptMerger.merge(perSource, clean: clean)
        let flat = TranscriptMerger.composeFlatText(merged)
        return (merged, flat)
    }

    /// Per-segment text cleaning: the same filter → format → word-replace chain the
    /// single-source pipeline runs, but applied to each raw segment BEFORE composition so the
    /// `[mm:ss]` prefixes are never fed to the bracket-stripping output filter.
    private func makeCleaner() -> (String) -> String {
        let formatEnabled = UserDefaults.standard.bool(forKey: "IsTextFormattingEnabled")
        let context = modelContext
        return { text in
            var t = TranscriptionOutputFilter.filter(text)
            t = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if formatEnabled { t = WhisperTextFormatter.format(t) }
            t = WordReplacementService.shared.applyReplacements(to: t, using: context)
            return t
        }
    }
}
