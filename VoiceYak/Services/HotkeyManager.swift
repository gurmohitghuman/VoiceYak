import AppKit
import ApplicationServices
import CoreGraphics
import os

@MainActor
final class HotkeyManager {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var eventHandler: HotkeyEventHandler?

    private var hotkeyDown = false

    /// Key events flow through ONE AsyncStream consumed by ONE main-actor
    /// task: unstructured per-event Tasks carry no FIFO guarantee, so a
    /// fast press/release could theoretically run stop-before-start and
    /// leave a recording stuck until the max-duration cap.
    private enum HotkeyEvent { case down, up }
    private var eventContinuation: AsyncStream<HotkeyEvent>.Continuation?
    private var eventConsumerTask: Task<Void, Never>?

    var onStartRecording: (@MainActor () -> Void)?
    var onStopRecording: (@MainActor () -> Void)?

    // MARK: - Health

    enum TapHealth { case notInstalled, disabled, listening }

    var tapHealth: TapHealth {
        guard let tap = eventTap else { return .notInstalled }
        return CGEvent.tapIsEnabled(tap: tap) ? .listening : .disabled
    }

    /// Idempotent: installs, re-enables, or rebuilds the tap as needed —
    /// startListening() alone early-returns whenever a tap object exists,
    /// which can never recover a disabled one.
    func ensureListening() {
        switch tapHealth {
        case .listening:
            return
        case .disabled:
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            if tapHealth != .listening {          // enable didn't stick
                stopListening()
                startListening()
            }
        case .notInstalled:
            startListening()
        }
    }

    // MARK: - Lifecycle

    func startListening() {
        guard eventTap == nil else { return }

        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)

        // Single consumer: strict event ordering.
        let (stream, continuation) = AsyncStream.makeStream(of: HotkeyEvent.self)
        eventContinuation = continuation
        eventConsumerTask = Task { @MainActor [weak self] in
            for await event in stream {
                if Task.isCancelled { break }
                guard let self else { break }
                switch event {
                case .down:
                    guard !self.hotkeyDown else { continue }
                    self.hotkeyDown = true
                    self.onStartRecording?()
                case .up:
                    guard self.hotkeyDown else { continue }
                    self.hotkeyDown = false
                    self.onStopRecording?()
                }
            }
        }

        // Use a separate class to bridge the C callback
        let handler = HotkeyEventHandler()
        handler.onKeyDown = { continuation.yield(.down) }
        handler.onKeyUp = { continuation.yield(.up) }
        handler.onTapDisabled = { [weak self] in
            Task { @MainActor [weak self] in
                self?.reenableTapIfNeeded()
            }
        }

        eventHandler = handler
        let handlerPtr = Unmanaged.passRetained(handler).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: hotkeyCallback,
            userInfo: handlerPtr
        ) else {
            // Balance the passRetained above — this failure path leaked it.
            Unmanaged<HotkeyEventHandler>.fromOpaque(handlerPtr).release()
            eventHandler = nil
            teardownEventStream()
            // A .listenOnly tap formally needs Input Monitoring; Accessibility
            // is the superset VoiceYak actually requests (it also covers the
            // CGEvent posting used for paste). Log both so a failure is
            // attributable.
            Log.hotkey.error("Event tap creation failed. listenAccess=\(CGPreflightListenEventAccess()) axTrusted=\(AXIsProcessTrusted())")
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stopListening() {
        // Order matters: stop event delivery FIRST so a queued key-down
        // can't start a recording after teardown…
        teardownEventStream()
        // …then synthesize the release for an in-flight hold, so a
        // mid-dictation teardown (e.g. accessibility revoked) ends the
        // recording instead of leaving AppState listening forever.
        if hotkeyDown {
            hotkeyDown = false
            onStopRecording?()
        }
        eventHandler?.activeKeyCode = nil

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            eventTap = nil
            runLoopSource = nil
        }
        // Balance the passRetained() call from startListening()
        if let handler = eventHandler {
            Unmanaged.passUnretained(handler).release()
        }
        eventHandler = nil
    }

    private func teardownEventStream() {
        eventContinuation?.finish()
        eventContinuation = nil
        eventConsumerTask?.cancel()
        eventConsumerTask = nil
    }

    private func reenableTapIfNeeded() {
        guard let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }
}

// MARK: - Event Handler (non-isolated bridge for C callback)

private final class HotkeyEventHandler: @unchecked Sendable {
    nonisolated(unsafe) var onKeyDown: (() -> Void)?
    nonisolated(unsafe) var onKeyUp: (() -> Void)?
    nonisolated(unsafe) var onTapDisabled: (() -> Void)?
    /// Key code of the hotkey currently held, so its release is still
    /// recognized even if the user changes the hotkey mid-hold.
    /// Only touched from the tap callback on the main run loop.
    nonisolated(unsafe) var activeKeyCode: Int64?
}

nonisolated private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let handler = Unmanaged<HotkeyEventHandler>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        // The disable window can swallow the key-up: the user may release
        // while the tap is dead, leaving recording running to the max
        // duration and desyncing the next press. Treat disable as release.
        if handler.activeKeyCode != nil {
            handler.activeKeyCode = nil
            handler.onKeyUp?()
        }
        handler.onTapDisabled?()
        return Unmanaged.passUnretained(event)
    }

    guard type == .flagsChanged else {
        return Unmanaged.passUnretained(event)
    }

    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags

    // A hold is in progress — only watch that key for its release.
    if let active = handler.activeKeyCode {
        if keyCode == active, let key = HotkeyKey(rawValue: active) {
            // Prefer the device-specific L/R bit: the aggregate mask stays
            // set while the paired sibling is held (hold Right Option, tap
            // Left Option — the Right release must still be recognized).
            let released: Bool
            if let deviceMask = key.deviceFlagMask {
                released = (flags.rawValue & deviceMask == 0) || !flags.contains(key.flagMask)
            } else {
                released = !flags.contains(key.flagMask)
            }
            if released {
                handler.activeKeyCode = nil
                handler.onKeyUp?()
            }
        }
        return Unmanaged.passUnretained(event)
    }

    let selected = UserDefaults.standard.hotkeyKey
    if keyCode == selected.rawValue, flags.contains(selected.flagMask) {
        handler.activeKeyCode = keyCode
        handler.onKeyDown?()
    }

    return Unmanaged.passUnretained(event)
}
