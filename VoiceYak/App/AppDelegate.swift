import AppKit
import Observation
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var overlayPanel: RecordingOverlayPanel?
    private var permissionPollTask: Task<Void, Never>?
    private var accessibilityWatchTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.registerVoiceYakDefaults()
        Constants.migrateLegacyDataIfNeeded()
        // A hard kill mid-model-swap can strand an intact model as ".old";
        // reclaim it before anything checks what's installed. Stranded
        // download archives just get deleted.
        ModelDownloader.restoreOrphanedBackups()
        ModelDownloader.sweepDownloadScratch()

        // The generated Info.plist sets LSUIElement; the Dock icon is
        // opt-out at runtime so users can see the app is running.
        AppDelegate.applyDockIconPolicy()

        let appState = AppState.shared

        // Set up overlay panel
        overlayPanel = RecordingOverlayPanel(appState: appState)

        // Preallocate audio resources so the first recording starts fast
        appState.audioRecorder.prewarm()

        // Set up hotkey callbacks. No inner Task wrappers: HotkeyManager's
        // single-consumer event stream already delivers on the main actor
        // in strict order, and a second unstructured hop could reorder a
        // fast press/release.
        appState.hotkeyManager.onStartRecording = { [weak self] in
            appState.startRecording()
            self?.overlayPanel?.show()
        }

        appState.hotkeyManager.onStopRecording = { [weak self] in
            appState.stopRecording()
            // Keep the pill visible while transcribing — the status
            // observer hides it at .ready (or shows the error). Non-
            // transcribing exits (too-short, blocked) hide immediately.
            if appState.status != .transcribing {
                self?.overlayPanel?.hide()
            }
        }

        // Start the hotkey listener as soon as Accessibility is granted —
        // at launch, after onboarding, or when the user grants it later in
        // System Settings. ensureListening() is idempotent.
        accessibilityWatchTask = Task { @MainActor in
            for await granted in Observations({ appState.permissions.accessibilityGranted }) where granted {
                appState.hotkeyManager.ensureListening()
            }
        }

        // Permission/tap health loop. Grants and revocations both happen
        // outside the app with no notification, and a transiently-failed
        // or disabled tap needs a retry — so this polls for the app's
        // lifetime: fast while unhealthy, slow heartbeat once healthy.
        permissionPollTask = Task { @MainActor in
            while !Task.isCancelled {
                appState.permissions.checkAll()
                if appState.permissions.accessibilityGranted {
                    appState.hotkeyManager.ensureListening()
                } else if appState.hotkeyManager.tapHealth != .notInstalled {
                    // Revoked mid-session: tear down (this also ends any
                    // in-flight hold via the synthesized release).
                    appState.hotkeyManager.stopListening()
                }
                let healthy = appState.permissions.accessibilityGranted
                    && appState.permissions.microphoneGranted
                    && appState.hotkeyManager.tapHealth == .listening
                try? await Task.sleep(for: .seconds(healthy ? 15 : 2))
            }
        }

        // Load model if available
        Task {
            await appState.loadModelIfNeeded()
        }
    }

    /// Clicking the Dock icon opens the dashboard — otherwise it would do nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            AppState.shared.requestMainWindow(.home)
        }
        return true
    }

    static func applyDockIconPolicy() {
        NSApp.setActivationPolicy(UserDefaults.standard.showDockIcon ? .regular : .accessory)
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.hotkeyManager.stopListening()
        AppState.shared.parakeetService.unloadModel()
    }
}
