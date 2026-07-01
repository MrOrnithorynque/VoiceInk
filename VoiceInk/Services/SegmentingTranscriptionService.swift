// SegmentingTranscriptionService — narrow, additive protocol for services that can emit
// segment-level timestamps. Kept separate from TranscriptionService so the 5 existing
// conformers are untouched, while the multi-source path (and future cloud diarization,
// Phase 6) route through one uniform seam on the registry instead of a concrete type.

import Foundation

/// A transcription service that can return per-segment timestamps in addition to text.
/// Segment times are in seconds on the transcribed WAV's own (0-based) timeline; the
/// caller shifts them onto the shared recording timeline via each source's `t0Offset`.
protocol SegmentingTranscriptionService: TranscriptionService {
    /// Transcribe with segment boundaries. Implementations MUST run on a VAD-disabled
    /// path so the returned times map linearly to the raw WAV (see LibWhisper.forceDisableVAD).
    func transcribeWithSegments(audioURL: URL, model: any TranscriptionModel) async throws -> [TranscriptSegment]
}
