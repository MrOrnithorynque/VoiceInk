// ParakeetSegmentGrouper — turns Parakeet/FluidAudio token-level timings into readable
// `TranscriptSegment`s for the multi-source (Conversation Mode) path. Pure & synchronous so it
// is unit-tested without loading a CoreML model: it operates on a minimal `TimedToken` shape
// (mapped from FluidAudio's `TokenTiming` at the call site), never on the FluidAudio type.
//
// Grouping rule: start a new segment when the silent gap before a token exceeds `gapThreshold`
// (a within-speaker pause = a turn/phrase boundary), or when the running segment would exceed
// `maxSegmentDuration` (keeps granularity for interleaving). SentencePiece `▁` markers are
// normalised to spaces defensively — FluidAudio may hand back either raw or space-normalised
// token strings depending on its decode path.
//
// CRITICAL: FluidAudio's batch path emits NO real token durations — each token's `endTime` is
// synthesized as the NEXT token's start (clamped to >= start + 0.08). A token before a 10s
// silence therefore "ends" 10s late, which would make `token.start - last.end` always <= 0 and
// swallow every pause (one speaker's segment spanning the other speaker's whole turn, breaking
// TranscriptMerger's interleave order). So the grouper trusts only `start` and clamps each
// token's effective end to `start + maxTokenDuration` for gap detection and segment ends.

import Foundation

/// Minimal timing shape the grouper works on. Map `FluidAudio.TokenTiming` → this at the seam.
struct TimedToken: Equatable {
    let token: String
    let start: TimeInterval
    let end: TimeInterval
}

enum ParakeetSegmentGrouper {

    /// Group ordered token timings into speaker-less segments (the caller/merger assigns the role).
    /// - Parameters:
    ///   - gapThreshold: silent seconds between tokens that forces a new segment.
    ///   - maxSegmentDuration: hard cap on a single segment's span, so one long monologue still
    ///     breaks into interleaving-friendly chunks.
    ///   - maxTokenDuration: cap on a single token's believable length. FluidAudio synthesizes
    ///     token end times from the next token's start (see header), so raw ends can span
    ///     silences; only `start + maxTokenDuration` of each token is trusted.
    static func group(_ tokens: [TimedToken],
                      gapThreshold: TimeInterval = 0.8,
                      maxSegmentDuration: TimeInterval = 15,
                      maxTokenDuration: TimeInterval = 0.5) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        var current: [TimedToken] = []

        // A token's trustworthy end (see header: raw `end` may be the next token's start).
        func clampedEnd(_ t: TimedToken) -> TimeInterval {
            min(t.end, t.start + maxTokenDuration)
        }

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = normalizedText(current.map { $0.token })
            if !text.isEmpty {
                segments.append(TranscriptSegment(speaker: "",
                                                  text: text,
                                                  start: first.start,
                                                  end: max(clampedEnd(last), first.start)))
            }
            current.removeAll(keepingCapacity: true)
        }

        for token in tokens {
            if let last = current.last, let segStart = current.first {
                let gap = token.start - clampedEnd(last)
                let wouldExceed = (token.start - segStart.start) > maxSegmentDuration
                if gap > gapThreshold || wouldExceed {
                    flush()
                }
            }
            current.append(token)
        }
        flush()
        return segments
    }

    /// Concatenate SentencePiece tokens into clean text: `▁` → space, collapse runs of spaces,
    /// trim. Works whether the tokens still carry `▁` or were already space-normalised upstream.
    static func normalizedText(_ tokens: [String]) -> String {
        tokens.joined()
            .replacingOccurrences(of: "\u{2581}", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }
}
