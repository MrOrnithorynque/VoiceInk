// SegmentSpeakerLabeler — pure assignment of diarizer speaker clusters onto raw ASR
// segments. Cluster→segment overlap is computed per source on the source WAV's 0-based
// timeline (the stage runs BEFORE TranscriptMerger applies t0Offset); display names are
// minted in ONE global pass ordered by shared-timeline first appearance, so "Speaker 1"
// is whoever spoke first in the merged conversation even across multiple tapped sources.
// No I/O, no CoreML — unit-testable in isolation, mirroring TranscriptMerger's design.

import Foundation

enum SegmentSpeakerLabeler {

    /// A diarizer-attributed time range on one source WAV's 0-based timeline.
    struct SpeakerRange: Hashable {
        /// Diarizer cluster id within one source ("1", "2", …).
        let speakerId: String
        /// Seconds from the start of the source WAV.
        let start: TimeInterval
        /// Seconds from the start of the source WAV.
        let end: TimeInterval
    }

    /// One source's transcription plus its diarizer output (empty when diarization was
    /// skipped or failed — the source then passes through untouched).
    struct DiarizedSource {
        let source: TranscriptMerger.SourceSegments
        let ranges: [SpeakerRange]
    }

    /// Label every diarized source's segments with cluster names.
    ///
    /// Rules (see docs/plans/meeting-diarization-spec.md):
    /// - Each segment gets the cluster with the greatest total time-overlap; zero overlap
    ///   leaves the segment untouched (empty `speaker` → role at merge, `clusterId` nil).
    /// - A source that resolves to a single cluster keeps its role label (a 1:1 call reads
    ///   "Them", not "Speaker 1") but `clusterId` is still recorded for provenance.
    /// - "Speaker N" names are minted across ALL multi-cluster sources in one pass, ordered
    ///   by first appearance on the shared timeline (segment start + t0Offset).
    static func labelAll(_ diarized: [DiarizedSource]) -> [TranscriptMerger.SourceSegments] {
        // Pass 1 — per source: best cluster per segment by total overlap.
        let assignments: [[String?]] = diarized.map { pair in
            assign(segments: pair.source.segments, ranges: pair.ranges)
        }

        // Pass 2 — global name minting for multi-cluster sources, ordered by the cluster's
        // first appearance on the SHARED timeline (start + t0Offset), not source order.
        var firstAppearance: [(clusterKey: String, globalStart: TimeInterval)] = []
        for (pairIndex, pair) in diarized.enumerated() {
            let assigned = assignments[pairIndex]
            let distinct = Set(assigned.compactMap { $0 })
            guard distinct.count > 1 else { continue }
            var earliest: [String: TimeInterval] = [:]
            for (segIndex, cluster) in assigned.enumerated() {
                guard let cluster else { continue }
                let globalStart = pair.source.segments[segIndex].start + pair.source.record.t0Offset
                let key = clusterKey(role: pair.source.record.role, cluster: cluster)
                earliest[key] = min(earliest[key] ?? .infinity, globalStart)
            }
            firstAppearance.append(contentsOf: earliest.map { ($0.key, $0.value) })
        }
        var names: [String: String] = [:]
        for (index, entry) in firstAppearance.sorted(by: { $0.globalStart < $1.globalStart }).enumerated() {
            names[entry.clusterKey] = "Speaker \(index + 1)"
        }

        // Pass 3 — rewrite each source's segments.
        return zip(diarized, assignments).map { pair, assigned in
            let distinct = Set(assigned.compactMap { $0 })
            let isMultiCluster = distinct.count > 1
            let segments = zip(pair.source.segments, assigned).map { seg, cluster -> TranscriptSegment in
                guard let cluster else { return seg }
                var copy = seg
                let key = clusterKey(role: pair.source.record.role, cluster: cluster)
                copy.clusterId = key
                if isMultiCluster, let name = names[key] {
                    copy.speaker = name
                }
                // Single-cluster: speaker stays "" → TranscriptMerger assigns the role.
                return copy
            }
            return TranscriptMerger.SourceSegments(record: pair.source.record, segments: segments)
        }
    }

    /// Rename every segment carrying one display label to a new one (user rename of a
    /// diarized cluster or a source role). Pure; callers must re-encode `segmentsJSON` AND
    /// recompose `Transcription.text` — the stored flat text is a canonical cache.
    static func rename(segments: [TranscriptSegment],
                       from oldLabel: String,
                       to newLabel: String) -> [TranscriptSegment] {
        let trimmed = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != oldLabel else { return segments }
        return segments.map { seg in
            guard seg.speaker == oldLabel else { return seg }
            var copy = seg
            copy.speaker = trimmed
            return copy
        }
    }

    // MARK: - Internals

    private static func clusterKey(role: String, cluster: String) -> String {
        "\(role)#\(cluster)"
    }

    /// Best cluster per segment by total overlap (a cluster may hit a segment through
    /// several ranges). Ties break toward the lexically-earlier cluster id so the result
    /// is deterministic. nil = no overlap at all.
    private static func assign(segments: [TranscriptSegment],
                               ranges: [SpeakerRange]) -> [String?] {
        guard !ranges.isEmpty else { return segments.map { _ in nil } }
        return segments.map { seg in
            var overlapByCluster: [String: TimeInterval] = [:]
            for range in ranges {
                let overlap = min(seg.end, range.end) - max(seg.start, range.start)
                guard overlap > 0 else { continue }
                overlapByCluster[range.speakerId, default: 0] += overlap
            }
            return overlapByCluster.max { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value < rhs.value }
                return lhs.key > rhs.key
            }?.key
        }
    }
}
