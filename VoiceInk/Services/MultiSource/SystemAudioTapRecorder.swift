// SystemAudioTapRecorder — captures system output (all apps minus VoiceInk itself) via a
// Core Audio process tap on macOS 14.4+, writing a 16 kHz / mono / Int16 WAV. Chosen over
// ScreenCaptureKit because SCK re-nags for Screen Recording permission on every launch;
// process taps are a one-time audio-capture TCC grant (Apple's AudioCap sample pattern).
//
// The tap → private aggregate (clock-anchored on the default output device) → IOProc chain
// runs on a dispatch queue. The RT block captures a Sendable `TapWriter` (never `self`) that
// owns the ExtAudioFile and computes meters + first-buffer host time under lightweight locks.
// ExtAudioFile does SRC + downmix + format conversion (native tap format → 16k/mono/Int16).

import Foundation
import CoreAudio
import AudioToolbox
import os

@available(macOS 14.4, *)
@MainActor
final class SystemAudioTapRecorder: CaptureSource {

    /// What to tap: all system output minus VoiceInk, or a specific app's process objects.
    enum TapMode {
        case globalExcludingSelf
        case processes([AudioObjectID], bundleID: String)
    }

    let role: String
    var isSystemTap: Bool { true }
    var deviceName: String? { nil }
    private(set) var processBundleID: String?   // nil = global tap; set for per-app
    private let mode: TapMode

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "SystemAudioTapRecorder")
    private let ioQueue = DispatchQueue(label: "com.prakashjoshipax.voiceink.system-tap.io", qos: .userInitiated)

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateID: AudioDeviceID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var writer: TapWriter?

    private weak var timeline: RecordingTimeline?
    private var fileURL: URL?

    var averagePower: Float { writer?.averagePower ?? -160 }
    var peakPower: Float { writer?.peakPower ?? -160 }

    init(role: String, mode: TapMode = .globalExcludingSelf) {
        self.role = role
        self.mode = mode
        if case let .processes(_, bundleID) = mode { self.processBundleID = bundleID }
    }

    enum TapError: LocalizedError {
        case processTranslationFailed(OSStatus)
        case tapCreationFailed(OSStatus)
        case tapFormatUnavailable(OSStatus)
        case defaultOutputUnavailable(OSStatus)
        case aggregateCreationFailed(OSStatus)
        case fileCreationFailed(OSStatus)
        case ioProcFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .processTranslationFailed(let s): return "Could not resolve own audio process object (\(s))"
            case .tapCreationFailed(let s): return "Could not create system-audio tap (\(s)) — check audio-capture permission and code signing"
            case .tapFormatUnavailable(let s): return "Could not read tap format (\(s))"
            case .defaultOutputUnavailable(let s): return "Could not resolve default output device (\(s))"
            case .aggregateCreationFailed(let s): return "Could not create aggregate device (\(s))"
            case .fileCreationFailed(let s): return "Could not create output audio file (\(s))"
            case .ioProcFailed(let s): return "Could not start audio IO proc (\(s))"
            }
        }
    }

    // MARK: - CaptureSource

    func start(toOutputFile url: URL, timeline: RecordingTimeline) async throws {
        self.timeline = timeline
        self.fileURL = url

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            ioQueue.async { [self] in
                do {
                    try self.setUpTapChain(outputURL: url)
                    cont.resume()
                } catch {
                    self.teardownChain()
                    cont.resume(throwing: error)
                }
            }
        }
        logger.notice("🔊 System-audio source '\(self.role, privacy: .public)' started")
    }

    func stop() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            ioQueue.async { [self] in
                self.teardownChain()
                cont.resume()
            }
        }
    }

    func makeSourceRecord() -> AudioSourceRecord? {
        guard let fileURL, let writer else { return nil }
        // No frames written → the tap delivered nothing (permission/silent). Treat as no source.
        guard writer.totalFrames > 0 else {
            logger.warning("🔊 System-audio source '\(self.role, privacy: .public)' produced 0 frames — omitting")
            return nil
        }
        let host = writer.firstHostTime
        let offset = (host != 0) ? (timeline?.offsetSeconds(forHostTime: host) ?? 0) : 0
        return AudioSourceRecord(role: role, fileURL: fileURL, t0Offset: offset,
                                 deviceName: nil, processBundleID: processBundleID,
                                 kind: processBundleID != nil ? "app" : "system")
    }

    // MARK: - Tap chain setup (runs on ioQueue)

    private func setUpTapChain(outputURL: URL) throws {
        // 1-2. Build the tap description for the configured mode.
        let tapDescription: CATapDescription
        switch mode {
        case .globalExcludingSelf:
            guard let selfObject = CoreAudioUtils.translatePIDToProcessObject(getpid()) else {
                throw TapError.processTranslationFailed(0)
            }
            tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [selfObject])
            tapDescription.name = "VoiceInk System Capture"
        case .processes(let processes, let bundleID):
            guard !processes.isEmpty else { throw TapError.tapCreationFailed(0) }
            // Include-list mixdown of one app's process objects. Do NOT set .isExclusive.
            tapDescription = CATapDescription(stereoMixdownOfProcesses: processes)
            tapDescription.name = "VoiceInk App Capture (\(bundleID))"
        }
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = CATapMuteBehavior.unmuted
        tapDescription.uuid = UUID()

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &newTapID)
        guard tapStatus == noErr, newTapID != kAudioObjectUnknown else {
            throw TapError.tapCreationFailed(tapStatus)
        }
        self.tapID = newTapID

        // 3. Tap's native stream format (what the IOProc will deliver).
        var tapFormat = try Self.readTapFormat(newTapID)

        // 4. Default output device is the aggregate's clock anchor.
        let outputUID = try Self.defaultSystemOutputDeviceUID()

        // 5. Private aggregate device wrapping the tap, drift-compensated, auto-started.
        let aggregateUID = "com.prakashjoshipax.voiceink.aggregate.\(tapDescription.uuid.uuidString)"
        let description: [String: Any] = [
            kAudioAggregateDeviceUIDKey as String: aggregateUID,
            kAudioAggregateDeviceNameKey as String: "VoiceInk System Capture",
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceMainSubDeviceKey as String: outputUID,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceTapListKey as String: [[
                kAudioSubTapUIDKey as String: tapDescription.uuid.uuidString,
                kAudioSubTapDriftCompensationKey as String: true
            ]]
        ]
        var newAggregateID = AudioDeviceID(0)
        let aggStatus = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggregateID)
        guard aggStatus == noErr, newAggregateID != 0 else {
            throw TapError.aggregateCreationFailed(aggStatus)
        }
        self.aggregateID = newAggregateID

        // 6. Output file: 16k/mono/Int16 on disk; client format = tap native → ExtAudioFile
        //    converts (SRC + downmix + Int16) on write.
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }
        var fileFormat = AudioStreamBasicDescription(
            mSampleRate: 16000.0,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0
        )
        var fileRef: ExtAudioFileRef?
        let createStatus = ExtAudioFileCreateWithURL(outputURL as CFURL, kAudioFileWAVEType,
                                                     &fileFormat, nil,
                                                     AudioFileFlags.eraseFile.rawValue, &fileRef)
        guard createStatus == noErr, let extFile = fileRef else {
            throw TapError.fileCreationFailed(createStatus)
        }
        let clientStatus = ExtAudioFileSetProperty(extFile, kExtAudioFileProperty_ClientDataFormat,
                                                   UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &tapFormat)
        guard clientStatus == noErr else {
            ExtAudioFileDispose(extFile)
            throw TapError.fileCreationFailed(clientStatus)
        }

        let tapWriter = TapWriter(file: extFile, clientFormat: tapFormat)
        self.writer = tapWriter

        // 7. IOProc block captures the Sendable writer (not self) and drives it on ioQueue.
        let block: AudioDeviceIOBlock = { _, inInputData, inInputTime, _, _ in
            let ts = inInputTime.pointee
            let host = (ts.mFlags.contains(.hostTimeValid) && ts.mHostTime != 0) ? ts.mHostTime : mach_absolute_time()
            tapWriter.handle(input: inInputData, hostTime: host)
        }
        var newProcID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&newProcID, newAggregateID, ioQueue, block)
        guard procStatus == noErr, let procID = newProcID else {
            throw TapError.ioProcFailed(procStatus)
        }
        self.ioProcID = procID

        let startStatus = AudioDeviceStart(newAggregateID, procID)
        guard startStatus == noErr else {
            throw TapError.ioProcFailed(startStatus)
        }
    }

    private func teardownChain() {
        if aggregateID != 0, let procID = ioProcID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        ioProcID = nil
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        writer?.close()
    }

    // MARK: - Core Audio property helpers

    private static func readTapFormat(_ tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
        guard status == noErr, format.mBytesPerFrame > 0 else {
            throw TapError.tapFormatUnavailable(status)
        }
        return format
    }

    private static func defaultSystemOutputDeviceUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != 0 else {
            throw TapError.defaultOutputUnavailable(status)
        }
        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: CFString? = nil
        size = UInt32(MemoryLayout<CFString?>.size)
        status = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let uidString = uid as String? else {
            throw TapError.defaultOutputUnavailable(status)
        }
        return uidString
    }
}

// MARK: - TapWriter (Sendable RT sink captured by the IOProc block)

/// Owns the ExtAudioFile and does the real-time write + metering + first-host-time capture.
/// `@unchecked Sendable`: all mutable state is guarded by `OSAllocatedUnfairLock`, mirroring
/// the lightweight-lock-in-the-audio-path pattern the existing CoreAudioRecorder meter uses.
@available(macOS 14.4, *)
final class TapWriter: @unchecked Sendable {
    private let file: ExtAudioFileRef
    private let bytesPerFrame: UInt32
    private let fileLock = OSAllocatedUnfairLock<Bool>(initialState: true)   // guards `file` validity

    private let meter = OSAllocatedUnfairLock<(avg: Float, peak: Float)>(initialState: (-160, -160))
    private let hostTime = OSAllocatedUnfairLock<UInt64>(initialState: 0)
    private let frames = OSAllocatedUnfairLock<Int64>(initialState: 0)

    init(file: ExtAudioFileRef, clientFormat: AudioStreamBasicDescription) {
        self.file = file
        self.bytesPerFrame = max(1, clientFormat.mBytesPerFrame)
    }

    var averagePower: Float { meter.withLock { $0.avg } }
    var peakPower: Float { meter.withLock { $0.peak } }
    var firstHostTime: UInt64 { hostTime.withLock { $0 } }
    var totalFrames: Int64 { frames.withLock { $0 } }

    /// Real-time: called from the IOProc. Writes the tap buffer (ExtAudioFile converts to
    /// 16k/mono/Int16), updates the meter, and records the first buffer's host time.
    func handle(input: UnsafePointer<AudioBufferList>, hostTime hostTimeValue: UInt64) {
        hostTime.withLock { if $0 == 0 { $0 = hostTimeValue } }

        let buffer = input.pointee.mBuffers
        guard let data = buffer.mData, buffer.mDataByteSize > 0 else { return }

        // Meter on the first buffer (Float32 samples).
        let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float32>.size
        if sampleCount > 0 {
            let samples = data.assumingMemoryBound(to: Float32.self)
            var sum: Float = 0, peak: Float = 0
            for i in 0..<sampleCount {
                let s = abs(samples[i])
                sum += s * s
                if s > peak { peak = s }
            }
            let rms = sqrt(sum / Float(sampleCount))
            let avgDb = 20.0 * log10(max(rms, 0.000001))
            let peakDb = 20.0 * log10(max(peak, 0.000001))
            meter.withLock { $0 = (avgDb, peakDb) }
        }

        let frameCount = buffer.mDataByteSize / bytesPerFrame
        guard frameCount > 0 else { return }
        let ok = fileLock.withLock { valid -> Bool in
            guard valid else { return false }
            return ExtAudioFileWrite(file, frameCount, input) == noErr
        }
        if ok { frames.withLock { $0 += Int64(frameCount) } }
    }

    /// Close the file. Guarded so no in-flight IOProc write touches a disposed file.
    func close() {
        fileLock.withLock { valid in
            if valid { ExtAudioFileDispose(file); valid = false }
        }
    }
}
