// WAVSampleReader — decodes 16-bit little-endian PCM WAVs into normalized Float samples by
// walking RIFF chunks to the `data` chunk. Shared by LocalTranscriptionService (whisper) and
// ParakeetTranscriptionService so both engines read the identical sample timeline.
//
// WHY: Apple's ExtAudioFile WAVE writer (used by CoreAudioRecorder and SystemAudioTapRecorder)
// inserts a `FLLR` filler chunk before `data`, page-aligning samples at byte 4096. The common
// "samples start at byte 44" shortcut therefore prepends ~2000 zero/garbage samples (~0.13s at
// 16kHz), uniformly biasing every downstream segment timestamp (segmentsJSON, VTT/SRT export,
// multi-track playback cues) relative to the real audio.

import Foundation

enum WAVSampleReader {

    enum ReadError: Error {
        case notAWAV
        case dataChunkMissing
    }

    /// Decode a 16-bit little-endian PCM WAV file into `[-1, 1]` Float samples.
    static func samples(from url: URL) throws -> [Float] {
        try samples(from: Data(contentsOf: url))
    }

    /// Decode 16-bit little-endian PCM WAV bytes into `[-1, 1]` Float samples.
    static func samples(from data: Data) throws -> [Float] {
        let (offset, size) = try dataChunkRange(in: data)
        let end = min(data.count, offset + size)
        guard offset < end else { return [] }

        var floats = [Float]()
        floats.reserveCapacity((end - offset) / 2)
        var i = offset
        while i + 1 < end {
            let short = Int16(bitPattern: UInt16(data[i]) | (UInt16(data[i + 1]) << 8))
            floats.append(max(-1.0, min(Float(short) / 32767.0, 1.0)))
            i += 2
        }
        return floats
    }

    /// Walk the RIFF chunk list to the `data` chunk (skipping `fmt `, `FLLR`, etc.).
    /// - Returns: the payload offset and declared payload size in bytes.
    static func dataChunkRange(in data: Data) throws -> (offset: Int, size: Int) {
        guard data.count >= 12,
              data[0..<4].elementsEqual("RIFF".utf8),
              data[8..<12].elementsEqual("WAVE".utf8) else {
            throw ReadError.notAWAV
        }

        var cursor = 12
        while cursor + 8 <= data.count {
            let id = data[cursor..<cursor + 4]
            let size = Int(UInt32(data[cursor + 4])
                | (UInt32(data[cursor + 5]) << 8)
                | (UInt32(data[cursor + 6]) << 16)
                | (UInt32(data[cursor + 7]) << 24))
            let payload = cursor + 8
            if id.elementsEqual("data".utf8) {
                return (payload, size)
            }
            cursor = payload + size + (size & 1)   // RIFF chunks are word-aligned
        }
        throw ReadError.dataChunkMissing
    }
}
