import AVFoundation
import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics
import Observation

@MainActor
@Observable
final class PermissionsManager {
    static let shared = PermissionsManager()

    var microphoneGranted = false
    var accessibilityGranted = false

    /// Posting synthesized events (the Cmd-V paste). Granted with
    /// Accessibility. Diagnostic only — `accessibilityGranted` stays the
    /// user-facing gate, since one permission covers both capabilities.
    private(set) var canPostEvents = false
    /// Event-tap listening. Formally Input Monitoring; Accessibility is a
    /// superset that also satisfies it.
    private(set) var canListenForEvents = false

    private init() {
        checkAll()
    }

    func checkAll() {
        checkMicrophone()
        checkAccessibility()
    }

    // MARK: - Microphone

    func checkMicrophone() {
        let permission = AVAudioApplication.shared.recordPermission
        microphoneGranted = (permission == .granted)
    }

    func requestMicrophone() async {
        let permission = AVAudioApplication.shared.recordPermission
        switch permission {
        case .undetermined:
            // This triggers the system permission dialog
            let granted = await AVAudioApplication.requestRecordPermission()
            microphoneGranted = granted
        case .granted:
            microphoneGranted = true
        case .denied:
            // Already denied — open System Settings so user can toggle it
            openMicrophoneSettings()
        @unknown default:
            openMicrophoneSettings()
        }
    }

    // MARK: - Accessibility

    func checkAccessibility() {
        accessibilityGranted = AXIsProcessTrusted()
        canPostEvents = CGPreflightPostEventAccess()
        canListenForEvents = CGPreflightListenEventAccess()
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        accessibilityGranted = trusted
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    var allPermissionsGranted: Bool {
        microphoneGranted && accessibilityGranted
    }
}
