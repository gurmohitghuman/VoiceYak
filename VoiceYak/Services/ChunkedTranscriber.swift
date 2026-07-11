import Foundation
import os

/// Incremental transcription for long dictations (experimental).
///
/// While the user is recording, Silero VAD watches the audio stream and
/// closes a segment at each natural pause; closed segments are decoded by
/// Parakeet in the background immediately. On release only the trailing
/// speech remains to decode, so paste latency stays roughly constant no
/// matter how long the recording is. The same machinery feeds the live
/// preview: completed segments are stable text, and the open tail is
/// re-decoded periodically as provisional text.
///
/// All decodes (segments, previews, final tail) funnel through
/// ParakeetService's serial queue, so at most one preview job can ever
/// delay the final decode.
actor ChunkedTranscriber {

    struct PreviewText: Sendable {
        /// Session that produced this preview — the receiver drops stale
        /// previews from a previous recording (the main-actor hop has no
        /// other ordering guarantee).
        let session: Int
        let stable: String
        let provisional: String
    }

    private let parakeet: ParakeetService

    private var vad: SherpaOnnxVoiceActivityDetectorWrapper?

    // Per-recording state
    private var session = 0
    private var active = false
    private var previewEnabled = false
    private var samples: [Float] = []
    private var totalSegments = 0
    private var lastSegmentEnd = 0
    private var segmentTasks: [Int: Task<(text: String, failed: Bool), Never>] = [:]
    private var completedTexts: [Int: String] = [:]
    private var provisionalText = ""
    private var previewInFlight = false
    private var previewTask: Task<Void, Never>?
    private var lastPreviewAt = Date.distantPast

    private var onPreview: (@MainActor @Sendable (PreviewText) -> Void)?

    init(parakeet: ParakeetService) {
        self.parakeet = parakeet
    }

    func setOnPreview(_ callback: @escaping @MainActor @Sendable (PreviewText) -> Void) {
        onPreview = callback
    }

    // MARK: - Recording lifecycle

    /// Starts a chunked session. Returns the session token to pass with
    /// every append, or nil when chunked mode can't run (setting off, VAD
    /// model missing) — the caller then uses the legacy full-buffer path.
    func begin(previewEnabled: Bool) -> Int? {
        guard UserDefaults.standard.chunkedTranscription, ensureVad() else { return nil }

        session += 1
        active = true
        self.previewEnabled = previewEnabled
        samples.removeAll(keepingCapacity: true)
        totalSegments = 0
        lastSegmentEnd = 0
        segmentTasks.removeAll()
        completedTexts.removeAll()
        provisionalText = ""
        previewInFlight = false
        lastPreviewAt = .distantPast
        vad?.reset()
        return session
    }

    /// Feed converted 16 kHz mono samples from the recorder. The session
    /// token rejects chunks that were still in flight when a recording
    /// ended — without it they could contaminate the next recording.
    func append(_ chunk: [Float], session chunkSession: Int) {
        guard active, chunkSession == session, let vad else { return }
        samples.append(contentsOf: chunk)
        vad.acceptWaveform(samples: chunk)
        drainClosedSegments()
        maybeKickPreview()
    }

    /// Flushes the VAD, decodes what remains, and returns the full ordered
    /// transcription plus whether the VAD emitted at least one speech
    /// segment — the caller uses that verdict to veto hallucinated short
    /// results. Zero segments doesn't prove acoustic silence (a very quiet
    /// murmur can slip under the VAD's threshold/minimum duration), but
    /// it is the only signal that rejects loud non-speech like finger rubs.
    /// Ends the session.
    ///
    /// `fullAudio` is the recorder's authoritative buffer: chunks dispatched
    /// through the async fan-out right before the tap was removed may never
    /// have arrived here, so the tail is reconciled from it — otherwise the
    /// last fraction of a second could be dropped.
    func finish(fullAudio: [Float]) async -> (text: String, vadProducedSegment: Bool, decodeFailed: Bool) {
        guard active, let vad else { return ("", false, false) }
        active = false
        let finishedSession = session

        if fullAudio.count > samples.count {
            let missingTail = Array(fullAudio[samples.count...])
            samples = fullAudio
            vad.acceptWaveform(samples: missingTail)
            drainClosedSegments()
        }

        vad.flush()
        drainClosedSegments()

        // VAD-miss fallback: quiet speech or an unusual mic may produce no
        // segments at all. Never drop audio — decode the whole buffer.
        if totalSegments == 0 {
            let everything = samples
            samples.removeAll(keepingCapacity: false)
            guard !everything.isEmpty else { return ("", false, false) }
            Log.transcription.info("chunked: no VAD segments, falling back to full decode")
            var text = ""
            var failed = false
            do {
                text = try await parakeet.transcribe(audioSamples: everything)
            } catch {
                failed = true
            }
            // Same staleness check as the segmented path: a session that
            // was cancelled/superseded during the await must not paste.
            guard session == finishedSession else { return ("", false, false) }
            return (text, false, failed)
        }

        // Aggregate failure directly from the awaited task values — going
        // through actor state via segmentCompleted would race this loop.
        // Previews never contribute: they're cosmetic.
        var parts: [String] = []
        var decodeFailed = false
        for index in 0..<totalSegments {
            guard let task = segmentTasks[index] else { continue }
            let result = await task.value
            if result.failed { decodeFailed = true }
            if !result.text.isEmpty {
                parts.append(result.text)
            }
        }

        guard session == finishedSession else { return ("", false, false) } // cancelled meanwhile
        samples.removeAll(keepingCapacity: false)
        segmentTasks.removeAll()
        return (parts.joined(separator: " "), true, decodeFailed)
    }

    /// Session-scoped: a stale cancel queued by a previous recording's
    /// teardown must not kill a session that began after it was queued.
    func cancel(session cancelledSession: Int) {
        guard cancelledSession == session else { return }
        session += 1
        active = false
        vad?.reset()
        samples.removeAll(keepingCapacity: false)
        for task in segmentTasks.values {
            task.cancel()
        }
        segmentTasks.removeAll()
        previewTask?.cancel()
        previewTask = nil
        completedTexts.removeAll()
        provisionalText = ""
    }

    // MARK: - Segments

    private func drainClosedSegments() {
        guard let vad else { return }
        while !vad.isEmpty() {
            let segment = vad.front()
            vad.pop()

            // Pad boundaries so weak consonants survive, but clamp against
            // the previous segment's padded end so adjacent segments never
            // share audio — a forced split in continuous speech would
            // otherwise decode the boundary twice and paste duplicate words.
            let pad = Int(Constants.segmentPaddingSeconds * Constants.sampleRate)
            let lo = max(max(0, segment.start - pad), lastSegmentEnd)
            let hi = min(samples.count, segment.start + segment.n + pad)
            guard lo < hi else {
                lastSegmentEnd = max(lastSegmentEnd, hi)
                continue
            }

            let index = totalSegments
            totalSegments += 1
            lastSegmentEnd = max(lastSegmentEnd, hi)

            let audio = Array(samples[lo..<hi])
            let currentSession = session
            let parakeet = self.parakeet

            let task = Task<(text: String, failed: Bool), Never> {
                do {
                    let text = try await parakeet.transcribe(audioSamples: audio)
                    return (text.trimmingCharacters(in: .whitespacesAndNewlines), false)
                } catch {
                    return ("", true)
                }
            }
            segmentTasks[index] = task

            Task { [weak self] in
                let result = await task.value
                await self?.segmentCompleted(index: index, text: result.text, session: currentSession)
            }
        }
    }

    private func segmentCompleted(index: Int, text: String, session completedSession: Int) {
        guard completedSession == session else { return }
        completedTexts[index] = text
        publishPreview()
    }

    // MARK: - Live preview

    private func maybeKickPreview() {
        guard previewEnabled, active, !previewInFlight else { return }
        guard Date().timeIntervalSince(lastPreviewAt) >= Constants.previewInterval else { return }

        let tailStart = min(lastSegmentEnd, samples.count)
        let tailLength = samples.count - tailStart
        // Don't bother decoding less than half a second of tail.
        guard Double(tailLength) >= Constants.sampleRate / 2 else { return }

        let windowSamples = Int(Constants.previewWindowSeconds * Constants.sampleRate)
        let windowStart = max(tailStart, samples.count - windowSamples)
        let window = Array(samples[windowStart...])

        previewInFlight = true
        lastPreviewAt = Date()
        let currentSession = session
        let parakeet = self.parakeet

        previewTask = Task { [weak self] in
            let text = (try? await parakeet.transcribe(audioSamples: window)) ?? ""
            await self?.previewCompleted(
                text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                session: currentSession
            )
        }
    }

    private func previewCompleted(text: String, session completedSession: Int) {
        // Session check BEFORE clearing previewInFlight: a stale completion
        // un-flagging a newer session's in-flight preview let overlapping
        // preview decodes pile onto the serial Parakeet queue.
        guard completedSession == session else { return }
        previewInFlight = false
        guard active else { return }
        provisionalText = text
        publishPreview()
    }

    private func publishPreview() {
        guard previewEnabled, active, let onPreview else { return }

        // Stable text: the contiguous prefix of completed segments, so text
        // never appears out of order.
        var stableParts: [String] = []
        for index in 0..<totalSegments {
            guard let text = completedTexts[index] else { break }
            if !text.isEmpty {
                stableParts.append(text)
            }
        }

        let preview = PreviewText(
            session: session,
            stable: stableParts.joined(separator: " "),
            provisional: provisionalText
        )
        Task { @MainActor in
            onPreview(preview)
        }
    }

    // MARK: - VAD

    private func ensureVad() -> Bool {
        if vad != nil { return true }
        guard Constants.isVadModelDownloaded else {
            Log.transcription.info("chunked: VAD model not downloaded, using legacy path")
            return false
        }

        let sileroConfig = sherpaOnnxSileroVadModelConfig(
            model: Constants.vadModelPath.path,
            threshold: 0.5,
            minSilenceDuration: Constants.vadMinSilenceSeconds,
            minSpeechDuration: 0.25,
            windowSize: 512,
            maxSpeechDuration: Constants.vadMaxSpeechSeconds
        )
        var config = sherpaOnnxVadModelConfig(
            sileroVad: sileroConfig,
            sampleRate: Int32(Constants.sampleRate)
        )
        vad = SherpaOnnxVoiceActivityDetectorWrapper(
            config: &config,
            buffer_size_in_seconds: 150
        )
        return true
    }
}
