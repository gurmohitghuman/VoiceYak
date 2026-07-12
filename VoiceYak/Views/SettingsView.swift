import AppKit
import os
import ServiceManagement
import SwiftUI

// Settings panes hosted by the main window's sidebar (MainWindowView).

// MARK: - General

struct GeneralSettingsPane: View {
    let appState: AppState
    @AppStorage("checkForUpdates") private var checkForUpdates = false
    @AppStorage("hotkeyKeyCode") private var hotkeyKeyCode = Int(HotkeyKey.default.rawValue)
    @AppStorage("showDockIcon") private var showDockIcon = true
    @AppStorage("playCompletionSound") private var playCompletionSound = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var permissions: PermissionsManager { appState.permissions }

    private var selectedHotkey: HotkeyKey {
        HotkeyKey(rawValue: Int64(hotkeyKeyCode)) ?? .default
    }

    var body: some View {
        Form {
            Section("Hotkey") {
                Picker("Record key", selection: $hotkeyKeyCode) {
                    ForEach(HotkeyKey.allCases) { key in
                        Text(key.displayName).tag(Int(key.rawValue))
                    }
                }
                .pickerStyle(.menu)

                Text("Hold \(selectedHotkey.name) to record. Release to transcribe.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Behavior") {
                Toggle(isOn: Binding(
                    get: { launchAtLogin },
                    set: { enable in
                        do {
                            if enable {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                            launchAtLogin = enable
                        } catch {
                            Log.app.error("launch at login failed: \(error.localizedDescription)")
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Launch at login")
                        Text("Start VoiceYak automatically when you log in")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle(isOn: $showDockIcon) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show Dock icon")
                        Text("See at a glance that VoiceYak is running")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: showDockIcon) { _, _ in
                    AppDelegate.applyDockIconPolicy()
                    // Switching back to .regular can drop window focus
                    NSApp.activate()
                }

                Toggle(isOn: $playCompletionSound) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Play sound on completion")
                        Text("Chime when text is pasted, soft pop when nothing was heard")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Permissions") {
                PermissionRow(
                    title: "Microphone",
                    subtitle: "Required for recording audio",
                    isGranted: permissions.microphoneGranted,
                    action: {
                        if !permissions.microphoneGranted {
                            permissions.openMicrophoneSettings()
                        }
                    }
                )

                PermissionRow(
                    title: "Accessibility",
                    subtitle: "Required for global hotkey & text input",
                    isGranted: permissions.accessibilityGranted,
                    action: {
                        if !permissions.accessibilityGranted {
                            permissions.requestAccessibility()
                        }
                    }
                )

                if !permissions.accessibilityGranted && UserDefaults.standard.hasCompletedOnboarding {
                    Text("macOS can drop previously granted access after an update. If dictation stopped working, remove VoiceYak from the Accessibility list in System Settings and add it back.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Updates") {
                Toggle(isOn: $checkForUpdates) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Check for updates automatically")
                        Text("Once a day, VoiceYak asks GitHub for the latest version number. Nothing about you is sent.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: checkForUpdates) { _, enabled in
                    if enabled {
                        appState.updateChecker.startDailyChecks()
                    } else {
                        appState.updateChecker.stopDailyChecks()
                    }
                }

                LabeledContent {
                    Button(appState.updateChecker.isChecking ? "Checking…" : "Check Now") {
                        Task { await appState.updateChecker.checkNow() }
                    }
                    .disabled(appState.updateChecker.isChecking)
                } label: {
                    if let update = appState.updateChecker.available {
                        HStack(spacing: 8) {
                            Text("VoiceYak \(update.version) is available")
                            Button("View") {
                                NSWorkspace.shared.open(update.releaseURL)
                            }
                            .buttonStyle(.link)
                        }
                    } else if appState.updateChecker.upToDateConfirmed {
                        Text("You're up to date")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Check for a newer version")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("App") {
                LabeledContent("Version") {
                    Text(appVersionLabel)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var appVersionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "VoiceYak v\(version)"
    }
}

// MARK: - Output

struct OutputSettingsPane: View {
    let appState: AppState
    private let customization = TextCustomizationStore.shared
    @AppStorage("autoCapitalize") private var autoCapitalize = true
    @AppStorage("addTrailingSpace") private var addTrailingSpace = true
    @AppStorage("restoreClipboard") private var restoreClipboard = true
    @AppStorage("showLastTranscription") private var showLastTranscription = true
    @State private var workspaceTick = 0

    var body: some View {
        @Bindable var customization = customization
        return Form {
            Section("Text Processing") {
                Toggle(isOn: $autoCapitalize) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-capitalize first word")
                        Text("Capitalize the first letter of transcriptions")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle(isOn: $addTrailingSpace) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Add trailing space")
                        Text("Add a space after pasted text so you can keep typing")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("App-Specific Formatting") {
                Toggle(isOn: $customization.plainTextInTerminals) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Plain text in terminals")
                        Text("Paste commands as plain text in Terminal, iTerm, Warp, Ghostty and other dedicated terminal apps: no initial capital, trailing period or added space. For a terminal inside an IDE (Cursor, VS Code, JetBrains), add the IDE below and uncheck Capitalize.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                ForEach($customization.appRules) { $rule in
                    AppRuleRow(rule: $rule) { id in
                        // id by value — reading rule.id through the binding
                        // during removeAll violates exclusivity.
                        customization.appRules.removeAll { $0.id == id }
                    }
                }

                addAppMenu
            }

            Section("Clipboard") {
                Toggle(isOn: $restoreClipboard) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Restore clipboard after paste")
                        Text("Your clipboard contents are preserved after dictation")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if restoreClipboard,
                   NSPasteboard.general.accessBehavior == .ask
                    || NSPasteboard.general.accessBehavior == .alwaysDeny {
                    Text("macOS is set to ask before apps read the clipboard, so VoiceYak will paste without restoring your previous clipboard. To restore it silently, allow VoiceYak under Privacy and Security, Paste from Other Apps.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Privacy") {
                Toggle(isOn: $showLastTranscription) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep last transcription")
                        Text("Show your most recent dictation in the menu and dashboard so it can be copied")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: showLastTranscription) { _, keep in
                    if !keep {
                        appState.lastTranscription = ""
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Menu of running apps that don't have a rule yet. `workspaceTick`
    /// forces re-evaluation when apps launch or quit — the menu content
    /// otherwise goes stale until an unrelated state change.
    private var addAppMenu: some View {
        Menu("Add App…") {
            let _ = workspaceTick
            let ruledIds = Set(customization.appRules.map(\.bundleId))
            let candidates = NSWorkspace.shared.runningApplications
                .filter { app in
                    app.activationPolicy == .regular
                        && app.bundleIdentifier != nil
                        && app.bundleIdentifier != Bundle.main.bundleIdentifier
                        && !ruledIds.contains(app.bundleIdentifier ?? "")
                }
                .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }

            if candidates.isEmpty {
                Text("All running apps already have rules")
            } else {
                ForEach(candidates, id: \.processIdentifier) { app in
                    Button(app.localizedName ?? app.bundleIdentifier ?? "Unknown") {
                        customization.addRule(for: app)
                    }
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.didLaunchApplicationNotification
        )) { _ in workspaceTick += 1 }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.didTerminateApplicationNotification
        )) { _ in workspaceTick += 1 }
    }
}

// MARK: - App Rule Row

private struct AppRuleRow: View {
    @Binding var rule: AppFormattingRule
    let onDelete: (UUID) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(rule.displayName)
                .font(.body.weight(.medium))

            Spacer()

            Toggle("Capitalize", isOn: $rule.autoCapitalize)
                .toggleStyle(.checkbox)
                .controlSize(.small)

            Toggle("Trailing space", isOn: $rule.addTrailingSpace)
                .toggleStyle(.checkbox)
                .controlSize(.small)

            Button {
                onDelete(rule.id)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove rule for \(rule.displayName)")
            .accessibilityLabel("Remove rule for \(rule.displayName)")
        }
    }
}

// MARK: - Advanced

struct AdvancedSettingsPane: View {
    @AppStorage("maxRecordingDuration") private var maxRecordingDuration = Constants.maximumRecordingDuration

    var body: some View {
        Form {
            Section("Recording") {
                LabeledContent("Max recording duration") {
                    HStack(spacing: 12) {
                        Slider(value: $maxRecordingDuration, in: 10...120, step: 5)
                            .frame(width: 190)
                            .controlSize(.small)

                        Text("\(Int(maxRecordingDuration))s")
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)
                    }
                }

                Text("Recording will automatically stop after this duration")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Data") {
                LabeledContent("Models directory") {
                    Button("Show in Finder") {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: Constants.modelsDirectory.path)
                    }
                    .buttonStyle(.borderless)
                }

                Text(Constants.modelsDirectory.path)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Permission Row

struct PermissionRow: View {
    let title: String
    let subtitle: String
    let isGranted: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.title3)
                .foregroundStyle(isGranted ? .green : .red)
                .symbolEffect(.pulse, options: .nonRepeating, isActive: !reduceMotion && !isGranted)
                .accessibilityLabel(isGranted ? "Granted" : "Not granted")

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !isGranted {
                Button("Grant") {
                    action()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else {
                Text("Granted")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.green)
            }
        }
    }
}
