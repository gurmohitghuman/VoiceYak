import Foundation
import os

/// Incremental transcription for long dictations.
///
/// While the user is recording, Silero VAD watches the audio stream and
/// closes a segment at each natural pause; closed segments are decoded by
/// Parakeet in the background immediately. On release only the trailing
/// speech remains to decode, so paste latency stays roughly constant no
/// matter how long the recording is.
///
/// All decodes (segments and the final tail) funnel through
/// ParakeetService's serial queue.
actor ChunkedTranscriber {

    private let parakeet: ParakeetService

    private var vad: SherpaOnnxVoiceActivityDetectorWrapper?

    // Per-recording state
    private var session = 0
    private var active = false
    private var samples: [Float] = []
    private var totalSegments = 0
    private var lastSegmentEnd = 0
    private var segmentTasks: [Int: Task<(text: String, failed: Bool), Never>] = [:]

    init(parakeet: ParakeetService) {
        self.parakeet = parakeet
    }

    // MARK: - Recording lifecycle

    /// Starts a chunked session. Returns the session token to pass with
    /// every append, or nil when chunked mode can't run (VAD model
    /// missing) — the caller then uses the legacy full-buffer path.
    func begin() -> Int? {
        guard ensureVad() else { return nil }

        session += 1
        active = true
        samples.removeAll(keepingCapacity: true)
        totalSegments = 0
        lastSegmentEnd = 0
        segmentTasks.removeAll()
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

        // Snapshot the residual tail BEFORE any await — cancel() clears
        // `samples` and a stale read after suspension could index a
        // different recording's buffer.
        let tailStart = min(lastSegmentEnd, samples.count)
        let residual = Array(samples[tailStart...])

        // Aggregate failure directly from the awaited task values.
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

        // A session cancelled while the segment tasks were awaited must not
        // queue a pointless tail decode ahead of the next recording's work.
        guard session == finishedSession else { return ("", false, false) }

        // Audio after the last VAD segment that never became a segment
        // (below min speech duration, too quiet, flush quirk) used to be
        // dropped silently. Decode it as a final part — with a veto so a
        // trailing breath can't append hallucinated filler: a 1-2 word tail
        // must also look like speech acoustically. Established segment text
        // is never affected by the veto.
        var tailText = ""
        if Double(residual.count) >= Constants.sampleRate * Constants.residualTailMinSeconds {
            do {
                tailText = try await parakeet.transcribe(audioSamples: residual)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                decodeFailed = true
            }
            if !tailText.isEmpty,
               tailText.split(whereSeparator: \.isWhitespace).count <= 2,
               !AppState.containsLikelySpeech(residual) {
                Log.transcription.debug("chunked: vetoed residual tail \"\(tailText, privacy: .private)\" (no likely speech)")
                tailText = ""
            }
            Log.transcription.debug("chunked: residual tail \(String(format: "%.2f", Double(residual.count) / Constants.sampleRate))s, accepted=\(!tailText.isEmpty)")
        }

        guard session == finishedSession else { return ("", false, false) } // cancelled meanwhile
        if !tailText.isEmpty {
            parts.append(tailText)
        }
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
    }

    // MARK: - Segments

    private func drainClosedSegments() {
        guard let vad else { return }
        while !vad.isEmpty() {
            // A nil front despite !isEmpty means the native queue is in a
            // bad state; popping blind could drop a valid segment. Stop
            // draining — the samples buffer is authoritative, so finish()
            // recovers the audio via full decode or the residual tail.
            guard let segment = vad.front() else {
                Log.transcription.error("VAD front returned nil with non-empty queue, stopping drain")
                return
            }
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
        guard let created = SherpaOnnxVoiceActivityDetectorWrapper(
            config: &config,
            buffer_size_in_seconds: 150
        ) else {
            Log.transcription.error("VAD native init failed, using legacy path")
            return false
        }
        vad = created
        return true
    }
}
