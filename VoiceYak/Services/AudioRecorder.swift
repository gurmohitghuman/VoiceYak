@preconcurrency import AVFoundation
import os
import Synchronization

final class AudioRecorder {
    private let engineQueue = DispatchQueue(label: "com.voiceyak.audio-recorder", qos: .userInitiated)
    /// Serial queue that delivers live sample chunks to `onLiveSamples`,
    /// keeping consumer work off the real-time tap thread.
    private let fanoutQueue = DispatchQueue(label: "com.voiceyak.audio-fanout", qos: .userInitiated)
    private nonisolated(unsafe) var audioEngine: AVAudioEngine?
    private nonisolated(unsafe) var configChangeObserver: (any NSObjectProtocol)?

    /// Sample buffer plus the generation of the recording that owns it,
    /// under one lock: tap callbacks can run on their own thread after the
    /// tap is removed, and a stale callback must not append its audio (or
    /// fan it out) into the next recording.
    private struct CaptureState {
        var samples: [Float] = []
        var generation = 0
        /// Tap installed and not yet retired.
        var capturing = false
        /// The input device died (config change) under this recording.
        var invalidated = false
        /// Tap callbacks currently executing — drained before snapshot so
        /// a buffer mid-conversion at release isn't dropped.
        var inFlightCallbacks = 0
        /// Set while finishRecording waits for `inFlightCallbacks` to reach
        /// zero; the last callback (or the deadline) claims and runs it
        /// exactly once.
        var drainCompletion: (@Sendable () -> Void)?
        /// Identity of the drain that stored `drainCompletion`: a deadline
        /// block can run arbitrarily late on a congested queue, and must
        /// not claim a completion stored by a LATER drain.
        var drainID = 0
    }
    private let captureState = Mutex(CaptureState())

    /// Fired (on engineQueue) when a device/config change kills an active
    /// recording — best-effort fast path; `finishRecording`'s returned
    /// `invalidated` flag is the authoritative signal.
    nonisolated(unsafe) var onCaptureInvalidated: (@Sendable () -> Void)?

    /// The recording's converter, kept for the stop-time flush: the
    /// resampler holds a few ms of audio internally, and without an
    /// explicit end-of-stream drain that tail is dropped at every
    /// recording end. Written on engineQueue at tap install; read for the
    /// flush on engineQueue after the in-flight drain — the tap thread
    /// only ever uses the instance captured in its closure.
    private nonisolated(unsafe) var activeConverter: AVAudioConverter?
    private nonisolated(unsafe) var activeTargetFormat: AVAudioFormat?

    /// Synchronous read for early exits that never reach finishRecording
    /// (the too-short discard path).
    nonisolated var captureWasInvalidated: Bool {
        captureState.withLock { $0.invalidated }
    }
    /// Set when the engine starts; cleared by the first tap callback so we
    /// can log how long the input device took to actually deliver audio.
    private let engineStartedAtLock = Mutex<Date?>(nil)

    /// Optional live consumer of converted 16 kHz samples (chunked
    /// transcription). Set before startRecording(); called on fanoutQueue.
    nonisolated(unsafe) var onLiveSamples: (@Sendable ([Float]) -> Void)?

    /// Build the engine and preallocate audio resources before the first
    /// recording, so engine.start() on key-down is fast.
    func prewarm() {
        engineQueue.async { [weak self] in
            _ = self?.preparedEngine()
        }
    }

    func startRecording() async throws {
        let sampleRate = Constants.sampleRate
        let channelCount = AVAudioChannelCount(Constants.audioChannels)

        try await withCheckedThrowingContinuation { continuation in
            engineQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: ())
                    return
                }

                let engine = self.preparedEngine()
                let inputNode = engine.inputNode
                let hardwareFormat = inputNode.outputFormat(forBus: 0)

                guard let targetFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: sampleRate,
                    channels: channelCount,
                    interleaved: false
                ) else {
                    continuation.resume(throwing: AudioRecorderError.failedToCreateFormat)
                    return
                }

                guard let converter = AVAudioConverter(from: hardwareFormat, to: targetFormat) else {
                    continuation.resume(throwing: AudioRecorderError.failedToCreateConverter)
                    return
                }
                // Streaming setup: no priming delay, one reset per
                // RECORDING (the converter now keeps its resampler history
                // across tap buffers — per-buffer resets caused boundary
                // artifacts and cumulative sample loss).
                converter.primeMethod = .none
                converter.reset()
                self.activeConverter = converter
                self.activeTargetFormat = targetFormat

                // Open a new capture generation; anything still in flight
                // from the previous tap is retired and will be dropped.
                let generation = self.captureState.withLock { state in
                    state.generation += 1
                    state.samples.removeAll(keepingCapacity: true)
                    state.capturing = true
                    state.invalidated = false
                    return state.generation
                }
                // Captured at install so a stale callback can't feed a
                // later recording's chunk consumer.
                let liveConsumer = self.onLiveSamples
                // Before install: a warm engine delivers the first buffer
                // immediately.
                self.engineStartedAtLock.withLock { $0 = Date() }

                inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { [weak self] buffer, _ in
                    guard let self else { return }
                    self.convertAndAppend(
                        buffer: buffer,
                        converter: converter,
                        targetFormat: targetFormat,
                        generation: generation,
                        liveConsumer: liveConsumer
                    )
                }

                do {
                    try engine.start()
                    continuation.resume()
                } catch {
                    self.engineStartedAtLock.withLock { $0 = nil }
                    self.activeConverter = nil
                    self.activeTargetFormat = nil
                    // Retire the generation opened above — an in-flight
                    // callback must not append after this failure.
                    self.captureState.withLock { state in
                        state.generation += 1
                        state.capturing = false
                    }
                    Log.audio.error("Failed to start engine: \(error.localizedDescription)")
                    // The prepared engine is suspect after a failed start —
                    // rebuild from scratch next time.
                    inputNode.removeTap(onBus: 0)
                    self.discardEngine()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    @discardableResult
    func stopRecording() -> [Float] {
        engineQueue.sync {
            audioEngine?.inputNode.removeTap(onBus: 0)
            // Discard path: no flush — the tail is thrown away anyway.
            activeConverter = nil
            activeTargetFormat = nil
            pauseEngine()
        }

        // Retire the generation while snapshotting, so a tap callback that
        // slipped past removeTap can't append after the handoff. No drain
        // here: this path serves cancel/discard flows where the tail is
        // thrown away anyway.
        return captureState.withLock { state in
            state.generation += 1
            state.capturing = false
            return state.samples
        }
    }

    /// Hands the samples over once in-flight tap callbacks have drained
    /// (a buffer mid-conversion at release would otherwise be dropped,
    /// clipping the final syllable). The engine is paused before the
    /// result is returned, so the system mic indicator clears as soon as
    /// the dictation ends.
    func finishRecording() async -> (samples: [Float], invalidated: Bool) {
        await withCheckedContinuation { continuation in
            engineQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: ([], false))
                    return
                }
                self.audioEngine?.inputNode.removeTap(onBus: 0)
                self.drainThenSnapshot { result in
                    // Resume BEFORE pausing: pause() can block on a wedged
                    // render callback (the drain's 100ms deadline path) and
                    // must never delay the paste. Pause still runs after the
                    // drain + tail flush, and engineQueue is serial, so it
                    // completes before any later recording starts.
                    continuation.resume(returning: result)
                    self.pauseEngine()
                }
            }
        }
    }

    /// Pauses the engine, releasing the input hardware — this is what turns
    /// the system mic indicator off. Unlike stop(), pause() keeps the
    /// resources from prepare(), so the next start() skips most of the
    /// 100–300ms graph setup; only the input device's own wake-up (notably
    /// Bluetooth mics) remains. Must be called on engineQueue.
    private nonisolated func pauseEngine() {
        audioEngine?.pause()
    }

    /// Runs the flush + snapshot once no tap callback is executing. After
    /// removeTap no NEW callbacks start, so the counter only drains; the
    /// common case (nothing in flight) completes inline with zero waiting,
    /// and otherwise the LAST in-flight callback hands off directly — no
    /// polling. A 100 ms deadline bounds a pathological scheduler stall;
    /// that path degrades to dropping the converter tail instead of
    /// delaying the paste. Must be called on engineQueue.
    private nonisolated func drainThenSnapshot(
        completion: @escaping @Sendable ((samples: [Float], invalidated: Bool)) -> Void
    ) {
        let myDrainID = captureState.withLock { state -> Int? in
            if state.inFlightCallbacks == 0 { return nil }
            state.drainID += 1
            state.drainCompletion = { [weak self] in
                guard let self else { return }
                self.engineQueue.async {
                    self.finishDrain(flushTail: true, completion: completion)
                }
            }
            return state.drainID
        }
        guard let myDrainID else {
            finishDrain(flushTail: true, completion: completion)
            return
        }
        // Deadline: claim the completion back if the straggler still hasn't
        // finished. Claiming under the lock, keyed by drainID, makes
        // handoff-vs-deadline exactly-once — a deadline block delayed by a
        // congested queue must not claim a LATER drain's completion.
        engineQueue.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
            guard let self else { return }
            let timedOut = self.captureState.withLock { state -> Bool in
                guard state.drainID == myDrainID, state.drainCompletion != nil else { return false }
                state.drainCompletion = nil
                return true
            }
            if timedOut {
                // The wedged callback may be using the converter RIGHT NOW,
                // so flushing would race it. Drop the tail.
                self.finishDrain(flushTail: false, completion: completion)
            }
        }
    }

    /// Flushes (or drops) the converter tail, retires the generation, and
    /// hands the snapshot to `completion`. Must run on engineQueue.
    private nonisolated func finishDrain(
        flushTail: Bool,
        completion: @Sendable ((samples: [Float], invalidated: Bool)) -> Void
    ) {
        if flushTail {
            // Tap callbacks have drained — flush the converter's held
            // tail into the buffer BEFORE retiring the generation.
            flushConverterTail()
        } else {
            activeConverter = nil
            activeTargetFormat = nil
        }
        let result = captureState.withLock { state -> ([Float], Bool) in
            state.generation += 1
            state.capturing = false
            return (state.samples, state.invalidated)
        }
        completion((result.0, result.1))
    }

    /// Drains the resampler's internally-held frames (typically a few ms)
    /// with an end-of-stream convert. Runs on engineQueue after the
    /// in-flight drain, so nothing else touches the converter.
    private nonisolated func flushConverterTail() {
        guard let converter = activeConverter, let targetFormat = activeTargetFormat else { return }
        activeConverter = nil
        activeTargetFormat = nil

        var error: NSError?
        while true {
            guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 4096) else { return }
            let status = converter.convert(to: out, error: &error) { _, outStatus in
                outStatus.pointee = .endOfStream
                return nil
            }
            guard status != .error else { return }
            if out.frameLength > 0, let channelData = out.floatChannelData {
                let tail = Array(UnsafeBufferPointer(start: channelData[0], count: Int(out.frameLength)))
                captureState.withLock { state in
                    // Generation is still current here — retirement happens
                    // after this flush in drainThenSnapshot.
                    state.samples.append(contentsOf: tail)
                }
            }
            if status != .haveData { return }
        }
    }

    // MARK: - Engine lifecycle

    /// Reuse one engine across recordings — rebuilding the graph on every
    /// key-down cost 100–300ms before capture began.
    private nonisolated func preparedEngine() -> AVAudioEngine {
        if let engine = audioEngine { return engine }

        let engine = AVAudioEngine()
        _ = engine.inputNode // force the graph to wire the input
        engine.prepare()
        audioEngine = engine

        // A device or format change invalidates the prepared graph;
        // drop it and rebuild lazily on the next recording. If a
        // recording is active it just died with the device — mark it
        // invalidated (authoritative, read at finish) and notify for
        // fast UI feedback.
        // Deliberately block-based, NOT NotificationCenter.notifications:
        // the invalidated flag must be set synchronously on the posting
        // thread, and an async-sequence consumer hops — reopening the race
        // with an interleaved finishRecording (audit-fix-plan item 6).
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            // Mark SYNCHRONOUSLY on the posting thread: hopping to
            // engineQueue first loses a race with a finishRecording()
            // block enqueued in between, which would snapshot un-flagged
            // and paste the partial audio.
            let wasCapturing = self.captureState.withLock { state in
                if state.capturing { state.invalidated = true }
                return state.capturing
            }
            self.engineQueue.async {
                self.audioEngine?.inputNode.removeTap(onBus: 0)
                self.audioEngine?.stop()
                // The converter belongs to the dead engine's format;
                // invalidated recordings are discarded, so no flush.
                self.activeConverter = nil
                self.activeTargetFormat = nil
                self.discardEngine()
                if wasCapturing { self.onCaptureInvalidated?() }
            }
        }

        return engine
    }

    private nonisolated func discardEngine() {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        audioEngine = nil
    }

    private nonisolated func convertAndAppend(
        buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat,
        generation: Int,
        liveConsumer: (@Sendable ([Float]) -> Void)?
    ) {
        // In-flight accounting BEFORE any work (and before the generation
        // check) so retirement drains can see this callback.
        captureState.withLock { $0.inFlightCallbacks += 1 }
        defer {
            // The LAST callback to finish hands off to a waiting drain
            // (claimed under the lock, exactly-once vs the deadline).
            let drainCompletion = captureState.withLock { state -> (@Sendable () -> Void)? in
                state.inFlightCallbacks -= 1
                guard state.inFlightCallbacks == 0, let completion = state.drainCompletion else {
                    return nil
                }
                state.drainCompletion = nil
                return completion
            }
            drainCompletion?()
        }

        let startedAt = engineStartedAtLock.withLock { started -> Date? in
            defer { started = nil }
            return started
        }
        if let startedAt {
            let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
            Log.audio.debug("first audio buffer \(ms)ms after tap install")
        }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        // Round UP plus slack: truncation dropped a fractional frame per
        // buffer, shortening long recordings.
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard capacity > 0 else { return }

        var error: NSError?
        // Use a reference type to avoid data race warning on captured var.
        final class Flag: @unchecked Sendable { var consumed = false }
        let flag = Flag()
        var samples: [Float] = []

        // Streaming: hand the buffer over once, then report "no data right
        // now" — NOT end-of-stream, which would finalize the converter.
        // Loop while the converter reports more output available.
        while true {
            guard let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: capacity
            ) else { return }

            let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                if !flag.consumed {
                    flag.consumed = true
                    outStatus.pointee = .haveData
                    return buffer
                } else {
                    outStatus.pointee = .noDataNow
                    return nil
                }
            }
            guard status != .error else { return }

            if convertedBuffer.frameLength > 0, let channelData = convertedBuffer.floatChannelData {
                samples.append(contentsOf: UnsafeBufferPointer(
                    start: channelData[0],
                    count: Int(convertedBuffer.frameLength)
                ))
            }
            if status != .haveData { break }   // .inputRanDry: done for this tap buffer
        }
        guard !samples.isEmpty else { return }
        let converted = samples   // immutable for the @Sendable fanout hop

        let accepted = captureState.withLock { state -> Bool in
            guard state.generation == generation else { return false }
            state.samples.append(contentsOf: converted)
            return true
        }
        // A retired generation's audio belongs to a finished recording —
        // don't leak it into the buffer or the live chunk stream.
        guard accepted else { return }

        if let liveConsumer {
            fanoutQueue.async {
                liveConsumer(converted)
            }
        }
    }
}

enum AudioRecorderError: LocalizedError {
    case failedToCreateFormat
    case failedToCreateConverter

    var errorDescription: String? {
        switch self {
        case .failedToCreateFormat:
            return "Failed to configure the recording format."
        case .failedToCreateConverter:
            return "Failed to configure audio conversion."
        }
    }
}
