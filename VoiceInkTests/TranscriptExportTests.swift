//  TranscriptExportTests.swift
//  Pure serializer tests for Markdown / WebVTT / SRT export.

import Testing
import Foundation
@testable import VoiceInk

struct TranscriptExportTests {

    private func multiSourceTranscription(_ segments: [TranscriptSegment]) -> Transcription {
        let t = Transcription(text: "flat", duration: 12)
        t.segmentsJSON = MultiSourceTranscript.encodeSegments(segments)
        t.audioSourcesJSON = MultiSourceTranscript.encodeSources([
            AudioSourceRecord(role: "Me", fileURL: URL(fileURLWithPath: "/tmp/a.wav"), t0Offset: 0, kind: "mic"),
            AudioSourceRecord(role: "Them", fileURL: URL(fileURLWithPath: "/tmp/b.wav"), t0Offset: 0, kind: "system")
        ])
        return t
    }

    private let sample: [TranscriptSegment] = [
        TranscriptSegment(speaker: "Me", text: "Hello", start: 0, end: 1),
        TranscriptSegment(speaker: "Me", text: "there", start: 1, end: 2),
        TranscriptSegment(speaker: "Them", text: "Hi", start: 3, end: 4)
    ]

    // MARK: - Timecode

    @Test func timecodeFormats() {
        #expect(TranscriptTimecode.vtt(0) == "00:00:00.000")
        #expect(TranscriptTimecode.srt(0) == "00:00:00,000")
        #expect(TranscriptTimecode.vtt(3.48) == "00:00:03.480")
        #expect(TranscriptTimecode.srt(3.48) == "00:00:03,480")
        #expect(TranscriptTimecode.vtt(3661.5) == "01:01:01.500")
    }

    // MARK: - Markdown

    @Test func markdownGroupsConsecutiveSameSpeaker() {
        let md = MarkdownTranscriptSerializer.serialize(multiSourceTranscription(sample))
        #expect(md.contains("# Conversation Transcript"))
        #expect(md.contains("**Speakers:** Me, Them"))
        #expect(md.contains("**[00:00] Me:** Hello there"))
        #expect(md.contains("**[00:03] Them:** Hi"))
    }

    @Test func markdownSingleSourceFallback() {
        let t = Transcription(text: "just dictation", duration: 3)
        let md = MarkdownTranscriptSerializer.serialize(t)
        #expect(md.contains("# Transcription"))
        #expect(md.contains("just dictation"))
        #expect(!md.contains("# Conversation Transcript"))
    }

    // MARK: - VTT

    @Test func vttStructureAndVoiceTag() {
        let vtt = VTTTranscriptSerializer.serialize(multiSourceTranscription(sample))
        #expect(vtt.hasPrefix("WEBVTT\n\n"))
        #expect(vtt.contains("00:00:00.000 --> 00:00:01.000"))
        #expect(vtt.contains("<v Me>Hello"))
        #expect(vtt.contains("<v Them>Hi"))
    }

    @Test func vttEscapesSpecialCharsAndPadsZeroDuration() {
        let segs = [TranscriptSegment(speaker: "Me", text: "a < b & c", start: 5, end: 5)] // zero-length
        let vtt = VTTTranscriptSerializer.serialize(multiSourceTranscription(segs))
        #expect(vtt.contains("a &lt; b &amp; c"))
        #expect(vtt.contains("00:00:05.000 --> 00:00:05.500")) // padded to +0.5
    }

    // MARK: - SRT

    @Test func srtStructureAndRolePrefix() {
        let srt = SRTTranscriptSerializer.serialize(multiSourceTranscription(sample))
        #expect(srt.hasPrefix("1\n"))
        #expect(srt.contains("00:00:00,000 --> 00:00:01,000"))
        #expect(srt.contains("Me: Hello"))
        #expect(srt.contains("3\n00:00:03,000 --> 00:00:04,000\nThem: Hi"))
    }
}
