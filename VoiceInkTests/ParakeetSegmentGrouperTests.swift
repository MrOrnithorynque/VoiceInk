import Testing
import Foundation
@testable import VoiceInk

// Pure-logic tests for ParakeetSegmentGrouper — the token-timings → segments step of the
// model-agnostic (Parakeet) Conversation Mode path. No CoreML model is loaded.
struct ParakeetSegmentGrouperTests {

    private func tok(_ s: String, _ start: TimeInterval, _ end: TimeInterval) -> TimedToken {
        TimedToken(token: s, start: start, end: end)
    }

    @Test func emptyInputYieldsNoSegments() {
        #expect(ParakeetSegmentGrouper.group([]).isEmpty)
    }

    @Test func continuousRunIsOneSegment() {
        let tokens = [
            tok("\u{2581}Hello", 0.0, 0.4),
            tok("\u{2581}there", 0.4, 0.8),
            tok("\u{2581}friend", 0.85, 1.2),
        ]
        let segs = ParakeetSegmentGrouper.group(tokens, gapThreshold: 0.8)
        #expect(segs.count == 1)
        #expect(segs[0].text == "Hello there friend")
        #expect(segs[0].start == 0.0)
        #expect(segs[0].end == 1.2)
    }

    @Test func largeGapSplitsIntoTwoSegments() {
        let tokens = [
            tok("\u{2581}Hello", 0.0, 0.4),
            tok("\u{2581}world", 0.4, 0.8),
            // 2.0s of silence — a within-speaker pause → new segment
            tok("\u{2581}Again", 2.8, 3.2),
            tok("\u{2581}now", 3.2, 3.6),
        ]
        let segs = ParakeetSegmentGrouper.group(tokens, gapThreshold: 0.8)
        #expect(segs.count == 2)
        #expect(segs[0].text == "Hello world")
        #expect(segs[1].text == "Again now")
        #expect(segs[1].start == 2.8)
    }

    @Test func maxDurationCapForcesSplit() {
        // Contiguous tokens (no gap) spanning 20s should split at the 15s cap.
        var tokens: [TimedToken] = []
        for i in 0..<20 {
            let t = TimeInterval(i)
            tokens.append(tok("\u{2581}w\(i)", t, t + 1.0))
        }
        let segs = ParakeetSegmentGrouper.group(tokens, gapThreshold: 5.0, maxSegmentDuration: 15)
        #expect(segs.count >= 2)
        // No segment should span more than the cap.
        for s in segs {
            #expect((s.end - s.start) <= 15.0 + 1.0)  // +1 token tolerance
        }
    }

    @Test func normalizesSentencePieceMarkersAndCollapsesSpaces() {
        // Mixed raw ▁ markers and pre-normalised spaces should both clean up.
        let text = ParakeetSegmentGrouper.normalizedText(["\u{2581}Well", "come", "\u{2581}back", " home"])
        #expect(text == "Wellcome back home")
    }

    @Test func speakerIsLeftEmptyForMergerToStamp() {
        let segs = ParakeetSegmentGrouper.group([tok("\u{2581}Hi", 0, 0.3)])
        #expect(segs.count == 1)
        #expect(segs[0].speaker == "")
    }

    // FluidAudio's batch path synthesizes each token's end as the NEXT token's start — a token
    // before a silence "ends" when the next speech begins. The grouper must still detect the
    // pause (via the maxTokenDuration clamp) and must not let the segment end span the silence.
    @Test func fluidAudioShapedTokensSplitAtSilenceDespiteSynthesizedEnds() {
        let tokens = [
            tok("\u{2581}Hi", 0.0, 0.4),
            tok("\u{2581}there", 0.4, 12.0),      // end clamped to next token's start (10s+ silence!)
            tok("\u{2581}Sounds", 12.0, 12.4),
            tok("\u{2581}good", 12.4, 12.48),
        ]
        let segs = ParakeetSegmentGrouper.group(tokens, gapThreshold: 0.8, maxTokenDuration: 0.5)
        #expect(segs.count == 2)
        #expect(segs[0].text == "Hi there")
        #expect(segs[0].end <= 1.0)               // must NOT extend to 12.0 across the silence
        #expect(segs[1].text == "Sounds good")
        #expect(segs[1].start == 12.0)
    }
}

// Tests for the RIFF-walking WAV decoder — Apple's ExtAudioFile writer inserts a FLLR filler
// chunk before `data`, so a fixed 44-byte offset reads ~0.13s of zeros/garbage as audio.
struct WAVSampleReaderTests {

    /// Build a minimal RIFF/WAVE byte blob with the given chunks appended after "WAVE".
    private func wav(chunks: [(id: String, payload: [UInt8])]) -> Data {
        var body = Data()
        for c in chunks {
            body.append(contentsOf: Array(c.id.utf8))
            var size = UInt32(c.payload.count).littleEndian
            withUnsafeBytes(of: &size) { body.append(contentsOf: $0) }
            body.append(contentsOf: c.payload)
            if c.payload.count % 2 == 1 { body.append(0) }   // word alignment pad
        }
        var data = Data("RIFF".utf8)
        var riffSize = UInt32(4 + body.count).littleEndian
        withUnsafeBytes(of: &riffSize) { data.append(contentsOf: $0) }
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(body)
        return data
    }

    private func int16LE(_ values: [Int16]) -> [UInt8] {
        values.flatMap { v -> [UInt8] in
            let u = UInt16(bitPattern: v)
            return [UInt8(u & 0xFF), UInt8(u >> 8)]
        }
    }

    @Test func decodesCanonicalHeaderLayout() throws {
        let fmt = [UInt8](repeating: 0, count: 16)
        let data = wav(chunks: [("fmt ", fmt), ("data", int16LE([0, 16384, -16384]))])
        let samples = try WAVSampleReader.samples(from: data)
        #expect(samples.count == 3)
        #expect(samples[0] == 0)
        #expect(abs(samples[1] - 0.5) < 0.01)
        #expect(abs(samples[2] + 0.5) < 0.01)
    }

    @Test func skipsAppleFLLRFillerChunk() throws {
        let fmt = [UInt8](repeating: 0, count: 16)
        let filler = [UInt8](repeating: 0, count: 4044)      // real size observed in our WAVs
        let data = wav(chunks: [("fmt ", fmt), ("FLLR", filler), ("data", int16LE([16384, -16384]))])
        let samples = try WAVSampleReader.samples(from: data)
        // Exactly the 2 real samples — no leading zeros from the filler, no garbage from headers.
        #expect(samples.count == 2)
        #expect(abs(samples[0] - 0.5) < 0.01)
        #expect(abs(samples[1] + 0.5) < 0.01)
    }

    @Test func throwsOnNonWAVData() {
        #expect(throws: WAVSampleReader.ReadError.self) {
            _ = try WAVSampleReader.samples(from: Data("definitely not a wav file".utf8))
        }
    }

    @Test func throwsWhenDataChunkMissing() {
        let fmt = [UInt8](repeating: 0, count: 16)
        let data = wav(chunks: [("fmt ", fmt)])
        #expect(throws: WAVSampleReader.ReadError.self) {
            _ = try WAVSampleReader.samples(from: data)
        }
    }
}
