import Foundation

/// The speech models VoiceYak can run. Both are NVIDIA Parakeet TDT 0.6B
/// int8 transducers with identical file layouts, so they share all loading
/// and decoding code — only the weights differ.
/// nonisolated: pure static configuration, read from actors and views.
nonisolated enum VoiceModel: String, CaseIterable, Identifiable {
    /// Parakeet v3 — English plus 24 other European languages.
    case multilingual
    /// Parakeet v2 — English only, slightly better English accuracy,
    /// smaller download.
    case english

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .multilingual: return "Multilingual"
        case .english: return "English"
        }
    }

    var modelName: String {
        switch self {
        case .multilingual: return "NVIDIA Parakeet TDT 0.6B v3"
        case .english: return "NVIDIA Parakeet TDT 0.6B v2"
        }
    }

    var details: String {
        switch self {
        case .multilingual: return "State-of-the-art accuracy for English and 24 other European languages. Runs locally on your Mac."
        case .english: return "English only, with the best English accuracy and a smaller download. Runs locally on your Mac."
        }
    }

    var displaySize: String {
        switch self {
        case .multilingual: return "~640 MB"
        case .english: return "~460 MB"
        }
    }

    var downloadURL: String {
        switch self {
        case .multilingual:
            return "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2"
        case .english:
            return "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8.tar.bz2"
        }
    }

    var directoryName: String {
        switch self {
        case .multilingual: return "parakeet-tdt-0.6b-v3-int8"
        case .english: return "parakeet-tdt-0.6b-v2-int8"
        }
    }

    var directory: URL {
        Constants.modelsDirectory.appendingPathComponent(directoryName, isDirectory: true)
    }

    var isDownloaded: Bool {
        Constants.parakeetModelFiles.allSatisfy { file in
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(file).path
            )
        }
    }

    /// The model the user has chosen in settings.
    static var selected: VoiceModel {
        VoiceModel(rawValue: UserDefaults.standard.selectedVoiceModel) ?? .multilingual
    }
}
