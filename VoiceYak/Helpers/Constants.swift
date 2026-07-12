import Foundation

/// nonisolated: pure static configuration, read from actors and callbacks.
nonisolated enum Constants {
    static let appName = "VoiceYak"
    static let bundleIdentifier = "ghuman.VoiceYak"

    // MARK: - Model Storage
    static let modelsDirectoryName = "Models"
    static var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent(appName).appendingPathComponent(modelsDirectoryName)
    }

    /// Directory of the currently selected model (see VoiceModel).
    static var parakeetModelDirectory: URL {
        VoiceModel.selected.directory
    }

    // MARK: - Audio
    static let sampleRate: Double = 16000
    static let audioChannels: Int = 1
    static let minimumRecordingDuration: TimeInterval = 0.3
    static let maximumRecordingDuration: TimeInterval = 60

    // MARK: - Text Output
    static let clipboardRestoreDelay: TimeInterval = 0.75

    // MARK: - Model Files
    static let parakeetModelFiles = [
        "encoder.int8.onnx",
        "decoder.int8.onnx",
        "joiner.int8.onnx",
        "tokens.txt"
    ]

    // MARK: - Updates
    /// Anonymous read of the latest release; see UpdateChecker.
    static let latestReleaseAPIURL = "https://api.github.com/repos/g-ghuman/VoiceYak/releases/latest"
    static let updateCheckInterval: TimeInterval = 24 * 60 * 60

    // MARK: - Voice Activity Detection (chunked transcription)
    static let vadModelURL = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx"
    static var vadModelPath: URL {
        modelsDirectory.appendingPathComponent("silero_vad.onnx")
    }
    /// Anything smaller is an HTTP error page, not the ~2 MB Silero model.
    static let vadModelMinBytes = 500_000
    static var isVadModelDownloaded: Bool {
        let size = (try? FileManager.default
            .attributesOfItem(atPath: vadModelPath.path)[.size] as? Int) ?? 0
        return size > vadModelMinBytes
    }

    /// Padding kept around VAD speech boundaries so weak leading/trailing
    /// consonants aren't clipped from a segment.
    static let segmentPaddingSeconds: Double = 0.2
    /// A pause this long closes the current speech segment.
    static let vadMinSilenceSeconds: Float = 0.6
    /// Continuous speech is force-split after this long.
    static let vadMaxSpeechSeconds: Float = 15.0

    static var isParakeetModelDownloaded: Bool {
        parakeetModelFiles.allSatisfy { file in
            FileManager.default.fileExists(
                atPath: parakeetModelDirectory.appendingPathComponent(file).path
            )
        }
    }

    // MARK: - Legacy Migration

    /// The app was previously named "Lizn". Move its Application Support data
    /// (including the ~640 MB downloaded model) to the new location so users
    /// don't have to re-download after updating.
    static func migrateLegacyDataIfNeeded() {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let legacyDir = appSupport.appendingPathComponent("Lizn")
        let newDir = appSupport.appendingPathComponent(appName)
        guard fm.fileExists(atPath: legacyDir.path), !fm.fileExists(atPath: newDir.path) else { return }
        try? fm.moveItem(at: legacyDir, to: newDir)
    }
}
