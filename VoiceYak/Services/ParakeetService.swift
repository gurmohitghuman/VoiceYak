import Foundation
import Observation
import Synchronization

@MainActor
@Observable
final class ParakeetService {
    @ObservationIgnored private nonisolated(unsafe) var recognizer: SherpaOnnxOfflineRecognizer?
    @ObservationIgnored private let processingQueue = DispatchQueue(label: "com.voiceyak.parakeet", qos: .userInitiated)

    /// Main-actor mirror of the load state. `recognizer` itself is only
    /// touched on processingQueue; reading it from the main actor for this
    /// check was a data race, and the queue-hopped unload left a window
    /// where a deleted model still looked loaded.
    private(set) var isModelLoaded = false
    /// WHICH model is loaded — status UI must not show "Ready" for a newly
    /// selected model while the previous one is still the loaded one.
    private(set) var loadedModelDirectory: URL?
    /// Bumped by every load/unload so a load that was interleaved with an
    /// unload can't mark the flag true after its recognizer is discarded.
    @ObservationIgnored private var loadGeneration = 0

    /// Builds a recognizer for the model directory. Shared by the normal
    /// load path and the --verify-model canary child, so both exercise the
    /// exact same native code. Throws on missing files or a native create
    /// that returns nil; corrupt files that make the native side exit()
    /// outright are what the canary exists to absorb.
    nonisolated static func makeRecognizer(modelDir: URL) throws -> SherpaOnnxOfflineRecognizer {
        let encoder = modelDir.appendingPathComponent("encoder.int8.onnx").path
        let decoder = modelDir.appendingPathComponent("decoder.int8.onnx").path
        let joiner = modelDir.appendingPathComponent("joiner.int8.onnx").path
        let tokens = modelDir.appendingPathComponent("tokens.txt").path

        // Verify all files exist
        for file in [encoder, decoder, joiner, tokens] {
            guard FileManager.default.fileExists(atPath: file) else {
                throw ParakeetError.missingModelFile(file)
            }
        }

        let transducerConfig = sherpaOnnxOfflineTransducerModelConfig(
            encoder: encoder,
            decoder: decoder,
            joiner: joiner
        )

        let modelConfig = sherpaOnnxOfflineModelConfig(
            tokens: tokens,
            transducer: transducerConfig,
            numThreads: max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)),
            debug: 0,
            modelType: "nemo_transducer"
        )

        let featConfig = sherpaOnnxFeatureConfig(
            sampleRate: 16000,
            featureDim: 80
        )

        var config = sherpaOnnxOfflineRecognizerConfig(
            featConfig: featConfig,
            modelConfig: modelConfig
        )

        return try SherpaOnnxOfflineRecognizer(config: &config)
    }

    func loadModel(modelDir: URL) async throws {
        isModelLoaded = false
        loadedModelDirectory = nil
        loadGeneration += 1
        let generation = loadGeneration
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            processingQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: ParakeetError.serviceDeallocated)
                    return
                }

                // A model that has never loaded successfully is proven in a
                // child process first: corrupt files can make the native
                // side exit() or abort, which no in-process guard survives.
                let stamp = ModelVerifier.stamp(for: modelDir)
                if !ModelVerifier.isVerified(stamp),
                   !ModelVerifier.verifyOutOfProcess(modelDir: modelDir) {
                    continuation.resume(throwing: ParakeetError.failedToLoadModel)
                    return
                }

                // Unmark before loading, re-mark after success: if this
                // load crashes the process (bit rot the stamp cannot see),
                // the next launch goes through the canary instead of
                // crash-looping.
                ModelVerifier.unmarkVerified(stamp)
                do {
                    let rec = try Self.makeRecognizer(modelDir: modelDir)
                    self.recognizer = rec
                    ModelVerifier.markVerified(stamp)
                    continuation.resume()
                } catch let error as ParakeetError {
                    continuation.resume(throwing: error)
                } catch {
                    continuation.resume(throwing: ParakeetError.failedToLoadModel)
                }
            }
        }
        // Only the newest load may declare success — an unload (or newer
        // load) during the await has already invalidated this one.
        if loadGeneration == generation {
            isModelLoaded = true
            loadedModelDirectory = modelDir
        }
    }

    func transcribe(audioSamples: [Float]) async throws -> String {
        // Honor task cancellation at DEQUEUE time: cancelling a chunked
        // session must not leave its queued decodes congesting the serial
        // queue ahead of the next recording. The flag is only consulted
        // before the decode starts — never mid-decode — so the
        // continuation still resumes exactly once.
        let cancelled = Mutex(false)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                processingQueue.async { [weak self] in
                    if cancelled.withLock({ $0 }) {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    guard let self, let rec = self.recognizer else {
                        continuation.resume(throwing: ParakeetError.modelNotLoaded)
                        return
                    }

                    do {
                        let result = try rec.decode(samples: audioSamples, sampleRate: 16_000)
                        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        continuation.resume(returning: text)
                    } catch {
                        continuation.resume(throwing: ParakeetError.failedToDecode)
                    }
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }

    func unloadModel() {
        // Flip the main-actor flag immediately so startRecording can't see
        // a model that is about to disappear.
        isModelLoaded = false
        loadedModelDirectory = nil
        loadGeneration += 1
        processingQueue.async { [weak self] in
            self?.recognizer = nil
        }
    }

    deinit {
        recognizer = nil
    }
}

enum ParakeetError: LocalizedError {
    case modelNotLoaded
    case failedToLoadModel
    case failedToDecode
    case serviceDeallocated
    case missingModelFile(String)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: return "No model loaded. Please download the model first."
        case .failedToLoadModel: return "Failed to load the Parakeet model."
        case .failedToDecode: return "Transcription failed. Please try again."
        case .serviceDeallocated: return "Parakeet service was deallocated."
        case .missingModelFile(let path): return "Missing model file: \(path)"
        }
    }
}
