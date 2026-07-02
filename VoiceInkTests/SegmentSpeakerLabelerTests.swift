//  SegmentSpeakerLabelerTests.swift
//  Unit tests for the pure diarization-cluster → segment labeling logic (no CoreML —
//  diarizer output is simulated as SpeakerRange fixtures, mirroring ParakeetSegmentGrouper's
//  test-without-models precedent).

import Testing
import Foundation
@testable import VoiceInk

struct SegmentSpeakerLabelerTests {

    private func record(_ role: String, offset: TimeInterval = 0) -> AudioSourceRecord {
        AudioSourceRecord(role: role, fileURL: URL(fileURLWithPath: "/tmp/\(role).wav"), t0Offset: offset)
    }

    private func seg(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> TranscriptSegment {
        TranscriptSegment(speaker: "", text: text, start: start, end: end)
    }

    private func range(_ id: String, _ start: TimeInterval, _ end: TimeInterval) -> SegmentSpeakerLabeler.SpeakerRange {
        .init(speakerId: id, start: start, end: end)
    }

    private func pair(_ role: String, offset: TimeInterval = 0,
                      segments: [TranscriptSegment],
                      ranges: [SegmentSpeakerLabeler.SpeakerRange]) -> SegmentSpeakerLabeler.DiarizedSource {
        .init(source: .init(record: record(role, offset: offset), segments: segments), ranges: ranges)
    }

    // MARK: - Assignment

    @Test func assignsMajorityOverlapCluster() {
        // Segment 0..4 overlaps cluster 1 for 1s and cluster 2 for 3s → cluster 2 wins.
        let labeled = SegmentSpeakerLabeler.labelAll([
            pair("Them",
                 segments: [seg("mixed", 0, 4), seg("pure", 5, 8)],
                 ranges: [range("1", 0, 1), range("2", 1, 4), range("1", 5, 8)])
        ])[0].segments

        #expect(labeled[0].clusterId == "Them#2")
        #expect(labeled[1].clusterId == "Them#1")
        #expect(labeled[0].speaker != labeled[1].speaker)
    }

    @Test func sumsSplitRangesOfSameClusterBeforeComparing() {
        // Cluster 1 hits the segment twice (1s + 1.5s = 2.5s) vs cluster 2 once (2s).
        let labeled = SegmentSpeakerLabeler.labelAll([
            pair("Them",
                 segments: [seg("a", 0, 5), seg("b", 6, 7)],
                 ranges: [range("1", 0, 1), range("2", 1, 3), range("1", 3.5, 5), range("2", 6, 7)])
        ])[0].segments

        #expect(labeled[0].clusterId == "Them#1")
    }

    @Test func firstSpeakerByTimeGetsSpeakerOneEvenWhenSegmentsOutOfOrder() {
        // Diarizer ids are arbitrary ("7" speaks first); display numbering follows time.
        let labeled = SegmentSpeakerLabeler.labelAll([
            pair("Them",
                 segments: [seg("late", 10, 12), seg("early", 0, 2)],
                 ranges: [range("3", 10, 12), range("7", 0, 2)])
        ])[0].segments

        #expect(labeled[1].speaker == "Speaker 1")   // "early", cluster 7
        #expect(labeled[0].speaker == "Speaker 2")   // "late", cluster 3
    }

    // MARK: - Passthrough rules

    @Test func singleClusterKeepsRoleLabelButRecordsProvenance() {
        let labeled = SegmentSpeakerLabeler.labelAll([
            pair("Them",
                 segments: [seg("only voice", 0, 2), seg("still them", 3, 5)],
                 ranges: [range("1", 0, 5)])
        ])[0].segments

        // speaker stays "" → TranscriptMerger assigns the role; provenance kept.
        #expect(labeled.allSatisfy { $0.speaker.isEmpty })
        #expect(labeled.allSatisfy { $0.clusterId == "Them#1" })
    }

    @Test func zeroOverlapSegmentKeepsRoleAndNilCluster() {
        let labeled = SegmentSpeakerLabeler.labelAll([
            pair("Them",
                 segments: [seg("covered", 0, 2), seg("gap", 10, 11), seg("covered2", 20, 22)],
                 ranges: [range("1", 0, 2), range("2", 20, 22)])
        ])[0].segments

        #expect(labeled[1].speaker.isEmpty)
        #expect(labeled[1].clusterId == nil)
        #expect(labeled[0].speaker == "Speaker 1")
        #expect(labeled[2].speaker == "Speaker 2")
    }

    @Test func emptyRangesPassesSourceThroughUntouched() {
        let input = [seg("a", 0, 1)]
        let out = SegmentSpeakerLabeler.labelAll([pair("Me", segments: input, ranges: [])])
        #expect(out[0].segments == input)
    }

    // MARK: - Cross-source numbering (global first appearance on the shared timeline)

    @Test func globalNumberingFollowsSharedTimelineNotSourceOrder() {
        // AppA is processed FIRST but its speech starts at t=30; AppB speaks from t=0.
        // "Speaker 1" must be AppB's first voice, not AppA's.
        let out = SegmentSpeakerLabeler.labelAll([
            pair("AppA",
                 segments: [seg("a1", 30, 32), seg("a2", 33, 35)],
                 ranges: [range("1", 30, 32), range("2", 33, 35)]),
            pair("AppB",
                 segments: [seg("b1", 0, 2), seg("b2", 3, 5)],
                 ranges: [range("1", 0, 2), range("2", 3, 5)])
        ])

        #expect(out[1].segments[0].speaker == "Speaker 1")   // AppB spoke first
        #expect(out[1].segments[1].speaker == "Speaker 2")
        #expect(out[0].segments[0].speaker == "Speaker 3")
        #expect(out[0].segments[1].speaker == "Speaker 4")
    }

    @Test func globalNumberingAccountsForT0Offset() {
        // Same WAV-local times, but AppA anchored 10s later on the shared timeline.
        let out = SegmentSpeakerLabeler.labelAll([
            pair("AppA", offset: 10,
                 segments: [seg("a1", 0, 2), seg("a2", 3, 5)],
                 ranges: [range("1", 0, 2), range("2", 3, 5)]),
            pair("AppB", offset: 0,
                 segments: [seg("b1", 1, 2), seg("b2", 3, 5)],
                 ranges: [range("1", 1, 2), range("2", 3, 5)])
        ])

        #expect(out[1].segments[0].speaker == "Speaker 1")   // t=1 global
        #expect(out[0].segments[0].speaker == "Speaker 3")   // t=10 global
    }

    // MARK: - Merge integration

    @Test func preLabeledSpeakerAndClusterSurviveMerge() {
        let rec = record("Them", offset: 1.0)
        var labeled = seg("hello", 0, 2)
        labeled.speaker = "Speaker 1"
        labeled.clusterId = "Them#1"
        let plain = seg("world", 3, 4)   // un-diarized → role at merge

        let merged = TranscriptMerger.merge([.init(record: rec, segments: [labeled, plain])],
                                            clean: { $0 })

        #expect(merged.map(\.speaker) == ["Speaker 1", "Them"])
        #expect(merged.map(\.clusterId) == ["Them#1", nil])
        #expect(merged[0].start == 1.0)   // t0Offset still applied
    }

    // MARK: - Rename

    @Test func renameRewritesOnlyMatchingLabel() {
        let segments = [
            TranscriptSegment(speaker: "Speaker 1", text: "hi", start: 0, end: 1, clusterId: "Them#1"),
            TranscriptSegment(speaker: "Me", text: "hey", start: 1, end: 2),
            TranscriptSegment(speaker: "Speaker 1", text: "again", start: 2, end: 3, clusterId: "Them#1")
        ]
        let renamed = SegmentSpeakerLabeler.rename(segments: segments, from: "Speaker 1", to: "Alice")

        #expect(renamed.map(\.speaker) == ["Alice", "Me", "Alice"])
        #expect(renamed[0].clusterId == "Them#1")   // provenance untouched
        #expect(TranscriptMerger.composeFlatText(renamed)
            == "[00:00] Alice: hi\n[00:01] Me: hey\n[00:02] Alice: again")
    }

    @Test func renameToEmptyOrWhitespaceIsNoOp() {
        let segments = [TranscriptSegment(speaker: "Speaker 1", text: "hi", start: 0, end: 1)]
        #expect(SegmentSpeakerLabeler.rename(segments: segments, from: "Speaker 1", to: "   ") == segments)
    }

    // MARK: - speakerCount badge

    @Test func speakerCountExcludesRoleSpilloverOfDiarizedTrack() {
        // 3 physical voices: Me + Speaker 1 + Speaker 2. The "Them" gap segment is spillover
        // of the diarized track, not a fourth voice.
        let t = Transcription(text: "x", duration: 10)
        t.segmentsJSON = MultiSourceTranscript.encodeSegments([
            TranscriptSegment(speaker: "Me", text: "hi", start: 0, end: 1),
            TranscriptSegment(speaker: "Speaker 1", text: "a", start: 1, end: 2, clusterId: "Them#1"),
            TranscriptSegment(speaker: "Speaker 2", text: "b", start: 2, end: 3, clusterId: "Them#2"),
            TranscriptSegment(speaker: "Them", text: "uh huh", start: 3, end: 4)   // diarizer gap
        ])
        t.audioSourcesJSON = MultiSourceTranscript.encodeSources([
            record("Me"), record("Them")
        ])

        #expect(t.speakerCount == 3)
    }

    @Test func speakerCountKeepsRoleForSingleClusterTrack() {
        // Single-cluster passthrough: "Them" IS the counted voice (clusterId set, same label).
        let t = Transcription(text: "x", duration: 10)
        t.segmentsJSON = MultiSourceTranscript.encodeSegments([
            TranscriptSegment(speaker: "Me", text: "hi", start: 0, end: 1),
            TranscriptSegment(speaker: "Them", text: "a", start: 1, end: 2, clusterId: "Them#1")
        ])
        t.audioSourcesJSON = MultiSourceTranscript.encodeSources([
            record("Me"), record("Them")
        ])

        #expect(t.speakerCount == 2)
    }

    // MARK: - Legacy decode safety

    @Test func v1JSONWithoutClusterIdDecodes() throws {
        let v1 = #"[{"speaker":"Them","text":"hi","start":0,"end":1}]"#
        let decoded = try JSONDecoder().decode([TranscriptSegment].self, from: Data(v1.utf8))
        #expect(decoded[0].clusterId == nil)
        #expect(decoded[0].speaker == "Them")
    }
}
