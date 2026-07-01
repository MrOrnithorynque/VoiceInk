import Foundation

/// One capture source's live level for the recorder UI (per-source meter bars + silent hint).
struct MultiSourceLevel: Identifiable, Equatable {
    let role: String        // "Me", "Them", …
    let level: Double        // 0…1 normalized
    let isSilent: Bool       // true once the source has been silent for a couple seconds
    let colorIndex: Int      // stable per-source palette index
    var id: String { role }
}

/// Protocol for objects that can serve as the recorder's state source.
/// VoiceInkEngine conforms to this protocol.
@MainActor
protocol RecorderStateProvider: AnyObject {
    var recordingState: RecordingState { get }
    var partialTranscript: String { get }
    var enhancementService: AIEnhancementService? { get }
    /// Per-source live levels during a multi-source recording; empty on the single-source path.
    var multiSourceLevels: [MultiSourceLevel] { get }
}

extension RecorderStateProvider {
    var multiSourceLevels: [MultiSourceLevel] { [] }
}
