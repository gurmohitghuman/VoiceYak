import Foundation
import Observation
import os

@MainActor
@Observable
final class ModelDownloader {
    var downloadState: DownloadState?

    /// Bumped when the set of installed models changes on disk, so
    /// Observation-tracked views re-evaluate the filesystem-computed
    /// properties (there is no objectWillChange to send anymore).
    private var installedModelsVersion = 0

    struct DownloadState {
        /// The model this download belongs to — the UI must not render
        /// model A's progress on model B's page.
        let model: VoiceModel
        /// Identity of the run that owns this state, so late callbacks
        /// from a cancelled or superseded download can't touch it.
        let runID: UUID
        var progress: Double = 0
        var totalBytes: Int64 = 0
        var downloadedBytes: Int64 = 0
        var isComplete = false
        var error: String?
    }

    @ObservationIgnored private var downloadRun: Task<Void, Never>?

    /// Called after a model is installed and verified on disk, so the
    /// owner can load it — nothing else loads a freshly downloaded model
    /// until relaunch or a model switch.
    @ObservationIgnored var onModelInstalled: (@MainActor (VoiceModel) -> Void)?

    /// All extractions run here serially: two overlapping extractions
    /// targeting the same model directory would interleave the
    /// park/move/verify swap sequence.
    private nonisolated static let extractionQueue = DispatchQueue(
        label: "com.voiceyak.model-extraction",
        qos: .userInitiated
    )

    /// Runs the blocking tar extraction + swap off the main actor.
    private nonisolated static func runExtraction(archiveURL: URL, model: VoiceModel) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            extractionQueue.async {
                do {
                    try extractModel(from: archiveURL, for: model)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    var isModelDownloaded: Bool {
        _ = installedModelsVersion   // establish Observation tracking
        return Constants.isParakeetModelDownloaded
    }

    var isDownloading: Bool {
        downloadState != nil && !(downloadState?.isComplete ?? true)
    }

    func download() {
        Log.models.debug("download() called, current state: \(String(describing: self.downloadState), privacy: .public)")

        // Pin the model now: the user could switch selection mid-download.
        let model = VoiceModel.selected

        // A finished (completed or failed) state never blocks a new
        // download — a completed download for model A used to wedge
        // model B's Download button for the whole session. An ACTIVE
        // download owns the single session slot regardless of model.
        if let existing = downloadState {
            if existing.error != nil || existing.isComplete {
                downloadState = nil
            } else {
                Log.models.debug("download() blocked, a download is in progress")
                return
            }
        }

        // Ensure models directory exists
        try? FileManager.default.createDirectory(
            at: Constants.modelsDirectory,
            withIntermediateDirectories: true
        )

        guard let url = URL(string: model.downloadURL) else {
            downloadState = DownloadState(model: model, runID: UUID(), error: "Invalid download URL")
            return
        }

        let runID = UUID()
        downloadState = DownloadState(model: model, runID: runID)
        Log.models.debug("starting download from \(url, privacy: .public)")
        downloadRun = Task { [weak self] in
            await self?.performDownload(model: model, url: url, runID: runID)
        }
    }

    private func performDownload(model: VoiceModel, url: URL, runID: UUID) async {
        // Progress relay: URLSession calls it on its own queue; hop to the
        // main actor and drop callbacks that outlived their run.
        let relay = DownloadProgressRelay { [weak self] progress, totalBytes, downloadedBytes in
            Task { @MainActor in
                guard let self, self.downloadState?.runID == runID else { return }
                self.downloadState?.progress = progress
                self.downloadState?.totalBytes = totalBytes
                self.downloadState?.downloadedBytes = downloadedBytes
            }
        }

        var archiveURL: URL?
        defer {
            if let archiveURL {
                try? FileManager.default.removeItem(at: archiveURL)
            }
        }
        do {
            // Cancelling downloadRun cancels the transfer cooperatively.
            let (tmpURL, response) = try await URLSession.shared.download(from: url, delegate: relay)
            // Claim the transfer's temp file (a fast same-volume rename)
            // before anything else — the system may clean it up otherwise.
            // Parked in a dedicated scratch dir that launch sweeps, so a
            // crash here can't strand a ~600 MB archive.
            try FileManager.default.createDirectory(
                at: Self.downloadScratchDirectory,
                withIntermediateDirectories: true
            )
            let parked = Self.downloadScratchDirectory
                .appendingPathComponent(UUID().uuidString + ".tar.bz2")
            try FileManager.default.moveItem(at: tmpURL, to: parked)
            archiveURL = parked

            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            try Task.checkCancellation()

            // Extract tar.bz2 archive off the main actor — tar on a
            // ~600 MB bz2 takes seconds and froze the whole UI here.
            try await Self.runExtraction(archiveURL: parked, model: model)
            // Re-check AFTER the await: a cancel or replacement download
            // during extraction must not complete a stale state.
            try Task.checkCancellation()
            guard downloadState?.runID == runID else { return }

            downloadState?.isComplete = true
            downloadState?.progress = 1.0
            installedModelsVersion += 1
            onModelInstalled?(model)
        } catch is CancellationError {
            // cancelDownload() already cleared the UI state.
        } catch let error as URLError where error.code == .cancelled {
            // Task cancellation surfaces from URLSession this way.
        } catch {
            // Staleness guard on the error path — a stale failure must not
            // stamp its error onto a newer run's state.
            guard downloadState?.runID == runID else { return }
            downloadState?.error = error.localizedDescription
        }
    }

    func cancelDownload() {
        downloadRun?.cancel()
        downloadRun = nil
        downloadState = nil
    }

    func deleteModel(_ model: VoiceModel) {
        try? FileManager.default.removeItem(at: model.directory)
        // isModelDownloaded is computed from the filesystem, so observers
        // need an explicit change signal to re-render.
        downloadState = nil
        installedModelsVersion += 1
    }

    /// Clears stale download state when the user switches models, so the
    /// other model's Download button isn't blocked by a previous run.
    func resetForModelSwitch() {
        guard !isDownloading else { return }
        downloadState = nil
    }

    /// Holding pen for in-flight download archives.
    private nonisolated static var downloadScratchDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceYakDownloads", isDirectory: true)
    }

    /// Deletes archives stranded by a crash or force-quit mid-download.
    /// Call at launch, before any download can start.
    nonisolated static func sweepDownloadScratch() {
        try? FileManager.default.removeItem(at: downloadScratchDirectory)
    }

    /// Restores a model stranded as ".old" by a hard kill between the
    /// swap's park and move steps — otherwise an intact ~600 MB install
    /// is invisible and the user re-downloads it. Call at launch, before
    /// anything checks what's installed.
    nonisolated static func restoreOrphanedBackups() {
        let fm = FileManager.default
        for model in VoiceModel.allCases where !model.isDownloaded {
            let backup = model.directory.deletingLastPathComponent()
                .appendingPathComponent(model.directory.lastPathComponent + ".old")
            guard fm.fileExists(atPath: backup.path) else { continue }
            // Clear partial leftovers; the backup is the best copy we have.
            try? fm.removeItem(at: model.directory)
            try? fm.moveItem(at: backup, to: model.directory)
            Log.models.info("restored orphaned model backup: \(model.rawValue, privacy: .public)")
        }
    }

    /// Guards against concurrent VAD downloads racing each other's
    /// remove/move on the same destination.
    @ObservationIgnored private var vadDownloadInFlight = false

    /// Fetches the ~2 MB Silero VAD model used by chunked transcription.
    /// Small enough that no progress UI is needed. The response is
    /// validated (HTTP status + size) — URLSession does not throw on
    /// non-2xx, so a 404 page would otherwise be installed as the model
    /// and treated as downloaded forever.
    func downloadVadModelIfNeeded() async {
        guard !Constants.isVadModelDownloaded, !vadDownloadInFlight,
              let url = URL(string: Constants.vadModelURL) else { return }
        vadDownloadInFlight = true
        defer { vadDownloadInFlight = false }
        do {
            let (tmpURL, response) = try await URLSession.shared.download(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                Log.models.error("VAD download HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return
            }
            let size = (try? FileManager.default
                .attributesOfItem(atPath: tmpURL.path)[.size] as? Int) ?? 0
            guard size > Constants.vadModelMinBytes else {
                Log.models.error("VAD download too small (\(size) bytes), discarding")
                return
            }
            let fm = FileManager.default
            try fm.createDirectory(
                at: Constants.modelsDirectory,
                withIntermediateDirectories: true
            )
            // replaceItemAt requires an existing destination; the normal
            // case here is a missing one.
            if fm.fileExists(atPath: Constants.vadModelPath.path) {
                _ = try fm.replaceItemAt(Constants.vadModelPath, withItemAt: tmpURL)
            } else {
                try fm.moveItem(at: tmpURL, to: Constants.vadModelPath)
            }
            Log.models.info("VAD model downloaded")
        } catch {
            Log.models.error("VAD model download failed: \(error.localizedDescription)")
        }
    }

    private nonisolated static func extractModel(from archiveURL: URL, for model: VoiceModel) throws {
        let modelDir = model.directory

        // Extract tar.bz2 using /usr/bin/tar
        let extractionDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: extractionDir, withIntermediateDirectories: true)

        defer {
            try? FileManager.default.removeItem(at: extractionDir)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xjf", archiveURL.path, "-C", extractionDir.path]

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ModelDownloadError.extractionFailed(process.terminationStatus)
        }

        // Find the extracted directory (sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8/)
        let contents = try FileManager.default.contentsOfDirectory(
            at: extractionDir,
            includingPropertiesForKeys: nil
        )

        guard let extractedDir = contents.first(where: {
            $0.lastPathComponent.contains("parakeet")
        }) else {
            throw ModelDownloadError.missingExtractedFiles
        }

        // Validate the new model BEFORE touching the existing one — a
        // corrupt archive must never destroy a working installation.
        for file in Constants.parakeetModelFiles {
            let filePath = extractedDir.appendingPathComponent(file).path
            guard FileManager.default.fileExists(atPath: filePath) else {
                throw ModelDownloadError.missingModelFile(file)
            }
        }

        // Swap with rollback: park the old model beside the destination,
        // move the new one in, and restore the old on any failure — an I/O
        // error mid-swap must never leave the user with no model at all.
        let fm = FileManager.default
        try fm.createDirectory(
            at: modelDir.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let backupDir = modelDir.deletingLastPathComponent()
            .appendingPathComponent(modelDir.lastPathComponent + ".old")
        let hadOldModel = fm.fileExists(atPath: modelDir.path)
        if hadOldModel {
            // Clearing a stale .old is only safe while an intact model
            // exists at the destination — after a failed rollback, that
            // orphaned backup may be the only surviving model.
            try? fm.removeItem(at: backupDir)
            try fm.moveItem(at: modelDir, to: backupDir)
        }
        do {
            try fm.moveItem(at: extractedDir, to: modelDir)
        } catch {
            if hadOldModel {
                do {
                    try fm.moveItem(at: backupDir, to: modelDir)
                } catch {
                    Log.models.error("model swap rollback ALSO failed, previous model preserved at \(backupDir.path, privacy: .public): \(error.localizedDescription)")
                }
            }
            throw error
        }
        // Final verification at the destination — with the backup still on
        // hand so a failure here can roll back too.
        for file in Constants.parakeetModelFiles {
            let filePath = modelDir.appendingPathComponent(file).path
            guard fm.fileExists(atPath: filePath) else {
                try? fm.removeItem(at: modelDir)
                if hadOldModel {
                    do {
                        try fm.moveItem(at: backupDir, to: modelDir)
                    } catch {
                        Log.models.error("model swap rollback ALSO failed, previous model preserved at \(backupDir.path, privacy: .public): \(error.localizedDescription)")
                    }
                }
                throw ModelDownloadError.missingModelFile(file)
            }
        }

        // Success — no backup (including an orphan from a past failed
        // rollback) is needed once an intact model exists here.
        try? fm.removeItem(at: backupDir)
    }
}

// MARK: - Errors

private enum ModelDownloadError: LocalizedError {
    case extractionFailed(Int32)
    case missingExtractedFiles
    case missingModelFile(String)

    var errorDescription: String? {
        switch self {
        case .extractionFailed(let status):
            return "Failed to extract model archive (exit code \(status))."
        case .missingExtractedFiles:
            return "Archive did not contain expected model files."
        case .missingModelFile(let name):
            return "Missing required model file: \(name)"
        }
    }
}

// MARK: - Download Progress Relay

/// Per-task delegate for the async `URLSession.download(from:delegate:)`
/// call: the async API returns the file and errors, so this only relays
/// progress.
private final class DownloadProgressRelay: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double, Int64, Int64) -> Void

    init(_ onProgress: @escaping @Sendable (Double, Int64, Int64) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Required by URLSessionDownloadDelegate; the async API's return
        // value delivers the file to the caller.
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : totalBytesWritten
        onProgress(Double(totalBytesWritten) / Double(total), total, totalBytesWritten)
    }
}
