//  TranscriptMergerTests.swift
//  Unit tests for the pure, N-source transcript merge/interleave.

import Testing
import Foundation
@testable import VoiceInk

struct TranscriptMergerTests {

    private func record(_ role: String, offset: TimeInterval) -> AudioSourceRecord {
        AudioSourceRecord(role: role, fileURL: URL(fileURLWithPath: "/tmp/\(role).wav"), t0Offset: offset)
    }

    private func seg(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> TranscriptSegment {
        TranscriptSegment(speaker: "", text: text, start: start, end: end)
    }

    private let identity: (String) -> String = { $0 }

    @Test func interleavesTwoSourcesByAdjustedStart() {
        let me = TranscriptMerger.SourceSegments(record: record("Me", offset: 0),
                                                 segments: [seg("hello", 0, 1), seg("how are you", 2, 3)])
        let them = TranscriptMerger.SourceSegments(record: record("Them", offset: 0),
                                                   segments: [seg("hi there", 1, 2)])

        let merged = TranscriptMerger.merge([me, them], clean: identity)

        #expect(merged.map(\.speaker) == ["Me", "Them", "Me"])
        #expect(merged.map(\.text) == ["hello", "hi there", "how are you"])
    }

    @Test func appliesT0OffsetSoLaterAnchoredSourceCanStillComeFirst() {
        // "Them" started 0.5s BEFORE "Me" on the shared timeline (smaller offset).
        let me = TranscriptMerger.SourceSegments(record: record("Me", offset: 1.0),
                                                 segments: [seg("mine", 0, 0.4)])   // → 1.0..1.4
        let them = TranscriptMerger.SourceSegments(record: record("Them", offset: 0.5),
                                                   segments: [seg("theirs", 0, 0.4)]) // → 0.5..0.9

        let merged = TranscriptMerger.merge([me, them], clean: identity)

        #expect(merged.map(\.speaker) == ["Them", "Me"])
        #expect(merged[0].start == 0.5)
        #expect(merged[1].start == 1.0)
    }

    @Test func dropsSegmentsThatCleanToEmpty() {
        let source = TranscriptMerger.SourceSegments(record: record("Me", offset: 0),
                                                     segments: [seg("keep", 0, 1), seg("   ", 1, 2)])
        let merged = TranscriptMerger.merge([source], clean: identity)
        #expect(merged.count == 1)
        #expect(merged[0].text == "keep")
    }

    @Test func handlesZeroSegmentSourceAndUnevenCounts() {
        let me = TranscriptMerger.SourceSegments(record: record("Me", offset: 0),
                                                 segments: [seg("solo", 0, 1)])
        let them = TranscriptMerger.SourceSegments(record: record("Them", offset: 0), segments: [])
        let merged = TranscriptMerger.merge([me, them], clean: identity)
        #expect(merged.map(\.text) == ["solo"])
    }

    @Test func composeGroupsConsecutiveSameSpeaker() {
        let segments = [
            TranscriptSegment(speaker: "Me", text: "hello", start: 0, end: 1),
            TranscriptSegment(speaker: "Me", text: "world", start: 1, end: 2),
            TranscriptSegment(speaker: "Them", text: "hi", start: 3, end: 4)
        ]
        let text = TranscriptMerger.composeFlatText(segments)
        #expect(text == "[00:00] Me: hello world\n[00:03] Them: hi")
    }

    @Test func cleanTransformIsAppliedPerSegment() {
        let source = TranscriptMerger.SourceSegments(record: record("Me", offset: 0),
                                                     segments: [seg("HELLO", 0, 1)])
        let merged = TranscriptMerger.merge([source], clean: { $0.lowercased() })
        #expect(merged[0].text == "hello")
    }
}
