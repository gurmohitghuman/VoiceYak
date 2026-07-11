import os
import SwiftUI

enum AppStatus: Equatable {
    case ready
    case listening
    case transcribing
    case error(String)

    var label: String {
        switch self {
        case .ready: return "Ready"
        case .listening: return "Listening..."
        case .transcribing: return "Transcribing..."
        case .error(let msg): return "Error: \(msg)"
        }
    }

    var iconName: String {
        switch self {
        case .ready: return "mic"
        case .listening: return "mic.fill"
        case .transcribing: return "text.bubble.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .ready: return Theme.accent
        case .listening: return .red
        case .transcribing: return .orange
        case .error: return .red
        }
    }

    var isRecording: Bool { self == .listening }
}

@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    var status: AppStatus = .ready
    var recordingDuration: TimeInterval = 0
    var lastTranscription: String = ""
    var showOnboarding = false

    /// Sidebar selection of the dashboard window.
    var dashboardSection: MainSection = .home

    /// Opens the dashboard window at a section. Installed by
    /// MenuBarIconView (alive for the app's whole lifetime) because only a
    /// View can reach the openWindow environment action; AppDelegate needs
    /// it for the dock-icon reopen path.
    @ObservationIgnored var openMainWindow: ((MainSection) -> Void)? {
        didSet {
            // A dock reopen can fire before the menu bar icon has appeared
            // and installed the bridge; deliver the buffered request now.
            if let pending = pendingMainWindowSection, let openMainWindow {
                pendingMainWindowSection = nil
                openMainWindow(pending)
            }
        }
    }
    @ObservationIgnored private var pendingMainWindowSection: MainSection?

    /// Route every open-main-window request through here: it buffers a
    /// request that arrives before the openWindow bridge is installed.
    func requestMainWindow(_ section: MainSection) {
        if let openMainWindow {
            openMainWindow(section)
        } else {
            pendingMainWindowSection = section
        }
    }

    // Live preview (chunked transcription)
    var previewStable = ""
    var previewProvisional = ""

    // Services
    let audioRecorder = AudioRecorder()
    let parakeetService = ParakeetService()
    let textOutput = TextOutputService()
    let modelDownloader = ModelDownloader()
    let permissions = PermissionsManager.shared
    let hotkeyManager = HotkeyManager()
    let chunkedTranscriber: ChunkedTranscriber

    @ObservationIgnored private var recordingDurationTask: Task<Void, Never>?
    @ObservationIgnored private var errorResetTask: Task<Void, Never>?
    /// Set to true when stopRecording() is called before the audio engine has started.
    @ObservationIgnored private var pendingStop = false
    /// Set to true when the audio engine is confirmed running.
    @ObservationIgnored private var engineRunning = false
    /// Wall-clock time when the audio engine went live (not key-press),
    /// used for the minimum duration check.
    @ObservationIgnored private var recordingStartedAt: Date?
    /// True while the current recording uses the chunked (VAD) pipeline.
    @ObservationIgnored private var chunkModeActive = false
    /// Session token of the current chunked recording, used to scope
    /// cancellation and (later) preview delivery to this session only.
    @ObservationIgnored private var activeChunkSession: Int?
    /// Ordered chunk delivery into the transcriber: one stream + one
    /// consumer task per recording. Per-chunk unstructured Tasks are NOT
    /// ordered and could reorder audio.
    @ObservationIgnored private var chunkStreamContinuation: AsyncStream<[Float]>.Continuation?
    @ObservationIgnored private var chunkConsumerTask: Task<Void, Never>?

    private init() {
        chunkedTranscriber = ChunkedTranscriber(parakeet: parakeetService)
        showOnboarding = !UserDefaults.standard.hasCompletedOnboarding

        // A model installed from the Voice Model page must be loaded —
        // nothing else loads it until relaunch or a model switch.
        modelDownloader.onModelInstalled = { [weak self] model in
            guard let self else { return }
            Task { @MainActor in
                guard VoiceModel.selected == model else { return }
                await self.loadModelIfNeeded()
            }
        }

        // Device/config change killed an active recording: end it through
        // the normal stop path immediately (best-effort UX); the
        // authoritative `invalidated` flag makes performStop discard the
        // partial audio with an explanation instead of pasting it.
        audioRecorder.onCaptureInvalidated = {
            Task { @MainActor in
                let state = AppState.shared
                guard state.status == .listening else { return }
                state.stopRecording()
            }
        }

        Task { [weak self, chunkedTranscriber] in
            await chunkedTranscriber.setOnPreview { preview in
                guard let self else { return }
                // Stale-preview gate: the main-actor hop has no ordering
                // guarantee, so a preview from a previous recording could
                // arrive after its session ended — or after a new one began.
                guard self.status == .listening,
                      preview.session == self.activeChunkSession else { return }
                self.previewStable = preview.stable
                self.previewProvisional = preview.provisional
            }
        }
    }

    /// Soft feedback when dictation ends without pasting anything —
    /// silence should never leave the user guessing whether they were heard.
    private func playNoResultSound() {
        guard UserDefaults.standard.playCompletionSound else { return }
        NSSound.pop?.stop()
        NSSound.pop?.play()
    }

    /// Show an error, then automatically return to .ready — startRecording()
    /// requires .ready, so a lingering error would block the hotkey forever.
    private func setTransientError(_ message: String) {
        errorResetTask?.cancel()
        status = .error(message)
        errorResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled else { return }
            if case .error = self.status { self.status = .ready }
        }
    }

    // MARK: - Recording Flow

    func startRecording() {
        guard status == .ready else {
            Log.recording.debug("startRecording: blocked, status is \(self.status.label, privacy: .public)")
            return
        }
        guard permissions.microphoneGranted else {
            setTransientError("Microphone access required")
            return
        }
        guard parakeetService.isModelLoaded else {
            Log.recording.debug("startRecording: no model loaded")
            if Constants.isParakeetModelDownloaded {
                setTransientError("Voice model is loading, try again in a moment")
            } else {
                setTransientError("\(VoiceModel.selected.displayName) model not downloaded. Open VoiceYak")
            }
            return
        }

        recordingDurationTask?.cancel()
        recordingDuration = 0
        pendingStop = false
        engineRunning = false
        recordingStartedAt = nil
        previewStable = ""
        previewProvisional = ""
        status = .listening
        Log.recording.debug("startRecording: status -> .listening")

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // Try the chunked (VAD) pipeline; falls back to the legacy
                // full-buffer path when the setting is off or VAD is missing.
                // The session token travels with every chunk so stale
                // in-flight audio can never leak into a later recording.
                let chunkSession = await self.chunkedTranscriber.begin(
                    previewEnabled: UserDefaults.standard.livePreview
                )
                self.chunkModeActive = chunkSession != nil
                self.activeChunkSession = chunkSession
                if let chunkSession {
                    let transcriber = self.chunkedTranscriber
                    let (stream, continuation) = AsyncStream.makeStream(of: [Float].self)
                    self.chunkStreamContinuation = continuation
                    self.chunkConsumerTask = Task {
                        for await chunk in stream {
                            await transcriber.append(chunk, session: chunkSession)
                        }
                    }
                    self.audioRecorder.onLiveSamples = { chunk in
                        continuation.yield(chunk)
                    }
                } else {
                    self.audioRecorder.onLiveSamples = nil
                }

                try await self.audioRecorder.startRecording()
                self.engineRunning = true
                // Clock starts when the engine is live, not at key-press:
                // engine spin-up ate into the minimum-duration window, so
                // quick utterances were judged against audio that was never
                // captured.
                self.recordingStartedAt = Date()
                Log.recording.debug("startRecording: engine running, pendingStop=\(self.pendingStop)")

                // If stopRecording() was called while we were awaiting,
                // handle the deferred stop now that the engine is running.
                if self.pendingStop {
                    self.pendingStop = false
                    self.performStop()
                    return
                }

                // If status changed for another reason (e.g. a capture
                // invalidation ended the recording early), just tear down.
                guard self.status == .listening else {
                    Log.recording.debug("startRecording: status changed to \(self.status.label, privacy: .public) while awaiting, tearing down")
                    self.audioRecorder.stopRecording()
                    return
                }

                // Engine is running — start the duration timer
                let startedAt = Date()
                self.recordingDurationTask = Task { @MainActor [weak self] in
                    while let self, !Task.isCancelled, self.status == .listening {
                        self.recordingDuration = Date().timeIntervalSince(startedAt)
                        if self.recordingDuration >= UserDefaults.standard.maxRecordingDuration {
                            self.stopRecording()
                            break
                        }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
            } catch {
                Log.recording.error("startRecording: engine failed: \(error.localizedDescription)")
                self.recordingDurationTask?.cancel()
                self.recordingDurationTask = nil
                self.recordingDuration = 0
                self.pendingStop = false
                self.engineRunning = false
                self.teardownChunkedSession()
                self.setTransientError(error.localizedDescription)
            }
        }
    }

    func stopRecording() {
        guard status == .listening else {
            Log.recording.debug("stopRecording: blocked, status is \(self.status.label, privacy: .public)")
            return
        }
        recordingDurationTask?.cancel()
        recordingDurationTask = nil

        // If the engine hasn't started yet, defer the stop.
        if !engineRunning {
            pendingStop = true
            Log.recording.debug("stopRecording: engine not running yet, set pendingStop")
            return
        }

        Log.recording.debug("stopRecording: engine running, calling performStop()")
        performStop()
    }

    /// Actually stops the audio engine and kicks off transcription.
    /// Must only be called when the engine is confirmed running.
    private func performStop() {
        engineRunning = false
        let elapsed = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? recordingDuration
        Log.recording.debug("performStop: elapsed=\(String(format: "%.2f", elapsed))s, recordingDuration=\(String(format: "%.2f", self.recordingDuration))s")

        // Ignore very short recordings
        if elapsed < Constants.minimumRecordingDuration {
            Log.recording.debug("performStop: too short (\(String(format: "%.2f", elapsed))s < \(Constants.minimumRecordingDuration)s), discarding")
            audioRecorder.stopRecording()
            // Read AFTER stopRecording(): its engineQueue.sync runs behind
            // any already-queued config-change block, so this can't race
            // an invalidation that was in flight when we entered here.
            let invalidated = audioRecorder.captureWasInvalidated
            teardownChunkedSession()
            recordingDuration = 0
            if invalidated {
                setTransientError("Microphone changed, dictation interrupted")
            } else {
                status = .ready
                playNoResultSound()
            }
            return
        }

        status = .transcribing
        let stopStart = Date()
        let chunked = chunkModeActive
        chunkModeActive = false

        Task {
            do {
                let text: String
                /// Whether the VAD emitted a speech segment; nil when the
                /// legacy (non-VAD) pipeline ran.
                var vadProducedSegment: Bool?
                let capture = await audioRecorder.finishRecording()
                let audioData = capture.samples
                let capturedSeconds = Double(audioData.count) / Constants.sampleRate
                Log.recording.debug("captured \(String(format: "%.2f", capturedSeconds))s of audio over a \(String(format: "%.2f", elapsed))s hold")

                // Authoritative device-death check: never transcribe/paste
                // a recording whose input device died midway. Explicit
                // chunk cleanup: chunkModeActive was already cleared above,
                // so teardownChunkedSession() would no-op here.
                if capture.invalidated {
                    if chunked {
                        audioRecorder.onLiveSamples = nil
                        chunkStreamContinuation?.finish()
                        chunkStreamContinuation = nil
                        chunkConsumerTask?.cancel()
                        chunkConsumerTask = nil
                        if let session = activeChunkSession {
                            activeChunkSession = nil
                            Task { await chunkedTranscriber.cancel(session: session) }
                        }
                    }
                    previewStable = ""
                    previewProvisional = ""
                    setTransientError("Microphone changed, dictation interrupted")
                    playNoResultSound()
                    return
                }
                if chunked {
                    // Segment decodes have been running during the recording;
                    // finish() flushes the VAD, reconciles the tail against
                    // the recorder's authoritative buffer, and decodes it.
                    audioRecorder.onLiveSamples = nil
                    // Drain the ordered chunk stream completely so every
                    // chunk yielded before the tap was removed has been
                    // appended before finishing.
                    chunkStreamContinuation?.finish()
                    chunkStreamContinuation = nil
                    await chunkConsumerTask?.value
                    chunkConsumerTask = nil
                    let finishStart = Date()
                    let result = await chunkedTranscriber.finish(fullAudio: audioData)
                    self.activeChunkSession = nil
                    text = result.text
                    vadProducedSegment = result.vadProducedSegment
                    let ms = Int(Date().timeIntervalSince(finishStart) * 1000)
                    Log.transcription.debug("chunked finish took \(ms)ms: \"\(text.prefix(100), privacy: .private)\"")

                    // A required decode threw and nothing was produced —
                    // surface the error like the legacy path does instead
                    // of a misleading "nothing heard" pop. Partial success
                    // (some segments decoded) still pastes what it has.
                    if result.decodeFailed && text.isEmpty {
                        previewStable = ""
                        previewProvisional = ""
                        setTransientError("Transcription failed")
                        playNoResultSound()
                        return
                    }
                } else {
                    // Samples are handed over as soon as the mic tap is
                    // removed; engine shutdown continues in parallel.
                    Log.recording.debug("performStop: got \(audioData.count) audio samples")
                    let transcriptionStart = Date()
                    text = try await parakeetService.transcribe(audioSamples: audioData)
                    let ms = Int(Date().timeIntervalSince(transcriptionStart) * 1000)
                    Log.transcription.debug("transcription took \(ms)ms for \(String(format: "%.1f", Double(audioData.count) / Constants.sampleRate))s of audio: \"\(text.prefix(100), privacy: .private)\"")
                }
                previewStable = ""
                previewProvisional = ""
                var processed = processText(text)
                // Silence hallucination guard: on speechless audio the model
                // invents short fillers ("Yeah", "Ooh"). Only 1–2 word results
                // are ever vetted — quiet or slow speech that produced a real
                // sentence always pastes. The VAD's verdict is authoritative
                // when available: loud non-speech (finger rubs, coughs, key
                // clacks) fools any level/shape heuristic but not the VAD.
                if !processed.isEmpty,
                   processed.split(whereSeparator: \.isWhitespace).count <= 2 {
                    let noSpeech: Bool
                    let source: String
                    if let vadProducedSegment {
                        noSpeech = !vadProducedSegment
                        source = "VAD found no speech"
                    } else {
                        noSpeech = !Self.containsLikelySpeech(audioData)
                        source = "no likely speech in audio"
                    }
                    if noSpeech {
                        Log.transcription.debug("discarding \"\(processed, privacy: .private)\": \(source, privacy: .public)")
                        processed = ""
                    }
                }
                if !processed.isEmpty {
                    if UserDefaults.standard.showLastTranscription {
                        lastTranscription = processed
                    }
                    UserDefaults.standard.totalDictations += 1
                    UserDefaults.standard.totalWords += processed
                        .split(whereSeparator: \.isWhitespace).count
                    textOutput.pasteText(processed)
                    let totalMs = Int(Date().timeIntervalSince(stopStart) * 1000)
                    Log.recording.debug("release -> paste: \(totalMs)ms")
                } else {
                    Log.recording.debug("processed text was empty, nothing to paste")
                    playNoResultSound()
                }
                // Only this task's own transcription owns the status; don't
                // clobber a state some future cancel/restart path set.
                if status == .transcribing {
                    status = .ready
                }
            } catch {
                Log.recording.error("transcription error: \(error.localizedDescription)")
                previewStable = ""
                previewProvisional = ""
                setTransientError(error.localizedDescription)
                playNoResultSound()
            }
        }
    }

    // cancelRecording() was removed: it had no callers, and wiring it to a
    // UI without cancelling the startup task and generation-guarding the
    // transcription task would let a cancelled dictation paste over a new
    // one. Re-introduce it together with an actual cancel feature — see
    // docs/audit-fix-plan.md §19 for the required design.

    /// Discards any in-flight chunked session and its preview state.
    private func teardownChunkedSession() {
        guard chunkModeActive else { return }
        chunkModeActive = false
        audioRecorder.onLiveSamples = nil
        chunkStreamContinuation?.finish()
        chunkStreamContinuation = nil
        chunkConsumerTask?.cancel()
        chunkConsumerTask = nil
        previewStable = ""
        previewProvisional = ""
        // Session-scoped: this async cancel can land AFTER a rapid
        // re-press has begun a new session; the token makes it a no-op
        // there instead of silently killing the new dictation.
        if let session = activeChunkSession {
            activeChunkSession = nil
            Task { await chunkedTranscriber.cancel(session: session) }
        }
    }

    /// Heuristic speech-presence check, used only to veto 1–2 word
    /// transcripts. Judges shape, not loudness: speech — even a whisper —
    /// is bursty, so its loudest 100 ms stands well above its own floor,
    /// while silence and stationary noise (fan, hiss) stay flat. An
    /// absolute-level short-circuit keeps clearly audible one-word
    /// dictations exempt even when they fill the whole recording.
    private nonisolated static func containsLikelySpeech(_ samples: [Float]) -> Bool {
        let window = Int(Constants.sampleRate / 10) // 100 ms
        guard window > 0, samples.count >= window else { return false }

        var windowRMS: [Float] = []
        windowRMS.reserveCapacity(samples.count / window + 1)
        var start = 0
        while start < samples.count {
            let end = min(start + window, samples.count)
            // A tiny tail can't produce a meaningful RMS; fold nothing
            // shorter than 25 ms into its own window.
            if end - start >= window / 4 {
                var sum: Float = 0
                for i in start..<end {
                    sum += samples[i] * samples[i]
                }
                windowRMS.append((sum / Float(end - start)).squareRoot())
            }
            start = end
        }
        guard let peak = windowRMS.max() else { return false }
        let quietFloor = windowRMS.sorted()[windowRMS.count / 4]
        // Never measure burstiness against a floor quieter than a real mic
        // idles at (~0.002–0.004 measured): the ramp-in right after the tap
        // installs can produce near-zero windows, which made a faint breath
        // look 15× "bursty" and paste a hallucinated filler.
        let ratio = peak / max(quietFloor, 0.0015)

        let speech: Bool
        let rule: String
        if peak < 0.003 {
            // Below the mic-hiss floor even at its loudest: nothing was
            // said. Measured: silence hallucinations peaked at 0.0027–0.0085
            // and the two flattest slipped the shape test at ~0.0028 — while
            // any real utterance must rise above the ~0.003 ambient floor to
            // be audible at all.
            speech = false
            rule = "below floor"
        } else if peak > 0.02 {
            // Clearly audible: definitely speech, skip the shape test so a
            // tightly-held one-word dictation can't be misjudged as flat.
            speech = true
            rule = "clearly audible"
        } else {
            // Gray zone (quiet audio): the loudest window must stand out
            // from the recording's quiet quantile. Speech always has
            // micro-dips between syllables, so even continuous quiet
            // talking passes; silence and noise are flat at every quantile.
            // Measured: breaths/silence reach ratio 3.7 (peak 0.0115);
            // real speech measures 20+. 6.0 splits with margin both ways.
            speech = ratio >= 6.0
            rule = "shape"
        }
        Log.recording.debug("speech check: peak=\(String(format: "%.4f", peak)) floor=\(String(format: "%.4f", quietFloor)) ratio=\(String(format: "%.1f", ratio)) -> \(speech ? "speech" : "no speech", privacy: .public) (\(rule, privacy: .public))")
        return speech
    }

    // MARK: - Text Processing

    private func processText(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return "" }

        // User dictionary: fix spellings the model can't know
        // (names, brands, jargon) before formatting.
        result = TextCustomizationStore.shared.applyDictionary(to: result)

        // Formatting follows the app being pasted into — a capitalized
        // command with a trailing space is broken in a terminal.
        let frontmostBundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let formatting = TextCustomizationStore.shared.effectiveFormatting(for: frontmostBundleId)
        Log.recording.debug("formatting for \(frontmostBundleId ?? "unknown", privacy: .private): \(String(describing: formatting.capitalization), privacy: .public), space=\(formatting.addTrailingSpace), stripPunct=\(formatting.stripTrailingPunctuation)")

        if formatting.stripTrailingPunctuation,
           let last = result.last, ".!?".contains(last) {
            result.removeLast()
        }

        // Dictionary spellings own their casing in either direction.
        if !TextCustomizationStore.shared.beginsWithCanonicalPhrase(result) {
            switch formatting.capitalization {
            case .capitalize:
                result = result.prefix(1).uppercased() + result.dropFirst()
            case .lowercase:
                result = result.prefix(1).lowercased() + result.dropFirst()
            case .preserve:
                break
            }
        }

        if formatting.addTrailingSpace {
            result += " "
        }

        return result
    }

    // MARK: - Model Management

    /// Deletes the selected model from disk AND unloads it from memory —
    /// otherwise dictation would keep working until relaunch while the UI
    /// says "Not downloaded". Guarded silently while dictating (the button
    /// is disabled then — and a status transition here would wedge the
    /// state machine by making stopRecording reject the coming key-up).
    func deleteModel() {
        guard status != .listening && status != .transcribing else { return }
        parakeetService.unloadModel()
        modelDownloader.deleteModel(VoiceModel.selected)
    }

    /// Serializes every model load: concurrent loadModel() calls would
    /// construct two recognizers and invalidate each other's generation.
    @ObservationIgnored private var modelLoadTask: Task<Void, Never>?

    /// Loads the selected model unless one is already loaded or loading.
    /// Joins an in-flight load instead of starting a second one.
    func loadModelIfNeeded() async {
        if parakeetService.isModelLoaded { return }
        if let task = modelLoadTask {
            await task.value
            return
        }
        let task = Task { await self.loadModel() }
        modelLoadTask = task
        await task.value
        // Only the owner may clear the slot — modelSelectionChanged may
        // have installed its own task while we were suspended.
        if modelLoadTask == task { modelLoadTask = nil }
    }

    /// Called when the user switches between the multilingual and English
    /// models: swap the loaded recognizer to the new selection if that
    /// model is on disk.
    func modelSelectionChanged() async {
        let target = VoiceModel.selected

        // Two preconditions must hold in the SAME pass before unloading:
        // no active dictation (the utterance must be transcribed by the
        // model it was recorded with) and no in-flight load (a concurrent
        // load would race the swap). Awaiting either can invalidate the
        // other, so loop until a pass establishes both. Only
        // .listening/.transcribing block: waiting for .ready let repeated
        // hotkey presses (each arming a 3s transient error) starve the
        // switch indefinitely.
        let waitStart = Date()
        while true {
            if Date().timeIntervalSince(waitStart) > 300 {
                // Abort rather than swap mid-dictation; the selection is
                // applied on the next successful switch or app launch.
                Log.models.info("model switch aborted: app never became idle")
                return
            }
            if status == .listening || status == .transcribing {
                try? await Task.sleep(for: .milliseconds(150))
                continue
            }
            if let inFlight = modelLoadTask {
                await inFlight.value
                continue
            }
            break
        }

        // A newer selection supersedes this one.
        guard VoiceModel.selected == target else { return }

        modelDownloader.resetForModelSwitch()
        parakeetService.unloadModel()
        // Forced load (no already-loaded short-circuit), but still through
        // the serialization slot so loadModelIfNeeded callers join it.
        let task = Task { await self.loadModel() }
        modelLoadTask = task
        await task.value
        if modelLoadTask == task { modelLoadTask = nil }
    }

    func loadModel() async {
        guard Constants.isParakeetModelDownloaded else { return }

        do {
            try await parakeetService.loadModel(modelDir: Constants.parakeetModelDirectory)

            // Warmup: ONNX Runtime allocates its memory arenas on the first
            // decode, which would otherwise make the first dictation after
            // launch noticeably slower than every one after it.
            let warmupStart = Date()
            _ = try? await parakeetService.transcribe(
                audioSamples: [Float](repeating: 0, count: Int(Constants.sampleRate / 2))
            )
            Log.models.debug("model warmup took \(Int(Date().timeIntervalSince(warmupStart) * 1000))ms")

            // Chunked transcription needs the small VAD model too.
            if UserDefaults.standard.chunkedTranscription {
                await modelDownloader.downloadVadModelIfNeeded()
            }
        } catch {
            setTransientError("Failed to load model")
        }
    }
}
