import AppKit
import Carbon.HIToolbox

final class TextOutputService {

    enum PasteOutcome: Equatable {
        /// Cmd-V was posted with the resolved target frontmost.
        case pasted
        /// Paste was not attempted (target gone or focus unverifiable);
        /// the transcription remains on the clipboard for a manual paste
        /// and no restore will overwrite it.
        case skipped
        /// An external writer took the clipboard mid-flight; pasting would
        /// have injected someone else's content, so nothing was posted.
        case clipboardTaken
        /// A newer paste superseded this one; the newer paste owns the
        /// clipboard and restore transaction.
        case superseded
    }

    /// Whether reading the pasteboard is allowed without a privacy prompt.
    /// Snapshotting the clipboard for restore is a programmatic read; when
    /// "Paste from Other Apps" is Ask or Deny, that read would prompt on
    /// every dictation, so restore is skipped instead (paste still works).
    /// `.default` currently means enforcement is off; when Apple ships
    /// default-on enforcement, move `.default` to the false branch.
    private static var canReadPasteboardSilently: Bool {
        switch NSPasteboard.general.accessBehavior {
        case .alwaysAllow, .default: return true
        case .ask, .alwaysDeny: return false
        @unknown default: return false
        }
    }

    /// The user's real clipboard, captured when a restore transaction
    /// opens. May legitimately be empty — `restoreTransactionActive` is the
    /// source of truth for whether a transaction exists.
    private var pendingRestore: [NSPasteboardItem] = []
    private var restoreTransactionActive = false
    /// changeCount of OUR most recent clipboard write; anything else on the
    /// clipboard means an external writer owns it now.
    private var lastWriteChangeCount = -1
    /// Only the newest paste of a burst runs to completion — starting a
    /// new paste cancels the previous task, which then exits without
    /// touching the shared restore state.
    private var pasteTask: Task<PasteOutcome, Never>?
    /// The delayed clipboard restore runs detached from the paste task so
    /// the caller gets its outcome right after Cmd-V, not 750ms later — a
    /// blocked caller kept the app in "transcribing" and rejected rapid
    /// follow-up dictations. Cancelled alongside pasteTask by newer pastes.
    private var restoreTask: Task<Void, Never>?

    /// Pastes into `target`: when `activateFirst` is set (VoiceYak's own
    /// window had focus), the target app is activated first, and in every
    /// case the target must actually be frontmost before Cmd-V is posted —
    /// otherwise the text stays on the clipboard and `.skipped` is
    /// returned so the caller can tell the user.
    @discardableResult
    func pasteText(
        _ text: String,
        into target: NSRunningApplication?,
        activateFirst: Bool
    ) async -> PasteOutcome {
        let pasteboard = NSPasteboard.general
        let defaults = UserDefaults.standard
        // Decide once, at paste time — re-reading the setting in the
        // delayed task let a mid-flight toggle strand a stale transaction.
        let shouldRestore = defaults.restoreClipboard && Self.canReadPasteboardSilently

        if shouldRestore {
            // If anything external wrote to the clipboard since our last
            // paste, that content is the user's real clipboard now —
            // restart the transaction around it instead of restoring the
            // pre-burst snapshot over it.
            if restoreTransactionActive && pasteboard.changeCount != lastWriteChangeCount {
                restoreTransactionActive = false
            }
            if !restoreTransactionActive {
                pendingRestore = pasteboard.pasteboardItems?.compactMap { item -> NSPasteboardItem? in
                    let newItem = NSPasteboardItem()
                    for type in item.types {
                        if let data = item.data(forType: type) {
                            newItem.setData(data, forType: type)
                        }
                    }
                    return newItem
                } ?? []
                restoreTransactionActive = true
            }
        } else {
            restoreTransactionActive = false
            pendingRestore = []
        }

        // Write transcription to clipboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Remember our write so the delayed restore can tell whether the
        // clipboard still holds our text.
        let ourChangeCount = pasteboard.changeCount
        lastWriteChangeCount = ourChangeCount
        pasteTask?.cancel()
        restoreTask?.cancel()

        let task = Task { @MainActor () -> PasteOutcome in
            // Brief pause so the pasteboard write is visible to the target
            // app — without blocking the main thread.
            try? await Task.sleep(for: .milliseconds(20))

            // Superseded by a newer paste: exit WITHOUT touching shared
            // restore state — the newer paste owns the transaction, and
            // clearing pendingRestore here would make its restore write an
            // empty clipboard instead of the user's original contents.
            guard !Task.isCancelled else { return .superseded }
            // External write during the pause: pasting now would inject
            // someone else's (potentially sensitive) clipboard content.
            // Abort the paste; the external writer owns the clipboard.
            guard pasteboard.changeCount == ourChangeCount else {
                self.restoreTransactionActive = false
                self.pendingRestore = []
                return .clipboardTaken
            }

            // No verifiable destination: never post a blind Cmd-V — it
            // would land in whatever happens to have focus.
            guard let target else {
                self.restoreTransactionActive = false
                self.pendingRestore = []
                return .skipped
            }

            // The paste must land in the resolved app. Activation normally
            // takes effect within a tick or two; the bounded wait also
            // covers the plain case where focus shifted right at release.
            if activateFirst {
                // The reactivation decision assumed OUR window still has
                // focus. If the user deliberately switched apps in the
                // meantime, yanking focus back would hijack them mid-work.
                guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                        == Bundle.main.bundleIdentifier else {
                    self.restoreTransactionActive = false
                    self.pendingRestore = []
                    return .skipped
                }
                target.activate()
            }
            var waited = 0
            while NSWorkspace.shared.frontmostApplication?.processIdentifier
                    != target.processIdentifier {
                if Task.isCancelled { return .superseded }
                waited += 1
                if waited > 12 || target.isTerminated {   // ~600 ms
                    // Keep the text available for a manual paste: the
                    // restore transaction is dropped, never run, so it
                    // cannot overwrite the only copy.
                    self.restoreTransactionActive = false
                    self.pendingRestore = []
                    return .skipped
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            // Focus settled — re-check nothing took the clipboard
            // while we waited.
            guard !Task.isCancelled else { return .superseded }
            guard pasteboard.changeCount == ourChangeCount else {
                self.restoreTransactionActive = false
                self.pendingRestore = []
                return .clipboardTaken
            }

            self.simulatePaste()

            // Play completion sound. stop() first: NSSound is a shared
            // instance and play() on an already-playing sound is a no-op,
            // which swallowed the chime on back-to-back dictations.
            if defaults.playCompletionSound {
                NSSound.tink?.stop()
                NSSound.tink?.play()
            }

            // Restore clipboard after a delay — detached so the caller gets
            // the paste outcome now, not after the restore window.
            if shouldRestore {
                self.restoreTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(Constants.clipboardRestoreDelay))
                    // A newer paste supersedes this restore; it owns the
                    // transaction now.
                    guard !Task.isCancelled else { return }
                    // If anything else wrote to the clipboard during the
                    // delay, the user owns it — abandon the restore.
                    guard pasteboard.changeCount == ourChangeCount else {
                        self.restoreTransactionActive = false
                        self.pendingRestore = []
                        return
                    }
                    // Restoring an originally-empty clipboard means
                    // clearing it.
                    pasteboard.clearContents()
                    if !self.pendingRestore.isEmpty {
                        pasteboard.writeObjects(self.pendingRestore)
                    }
                    self.restoreTransactionActive = false
                    self.pendingRestore = []
                }
            }
            return .pasted
        }
        pasteTask = task
        return await task.value
    }

    private func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)

        // Key down: Cmd+V
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)

        // Key up: Cmd+V
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)
    }
}

// MARK: - NSSound Helpers

extension NSSound {
    static let tink = NSSound(named: "Tink")
    static let pop = NSSound(named: "Pop")
}
