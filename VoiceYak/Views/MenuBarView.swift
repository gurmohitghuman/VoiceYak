import SwiftUI

struct MenuBarView: View {
    let appState: AppState
    @AppStorage("hotkeyKeyCode") private var hotkeyKeyCode = Int(HotkeyKey.default.rawValue)
    @AppStorage("showLastTranscription") private var showLastTranscription = true
    @AppStorage("totalDictations") private var totalDictations = 0
    @AppStorage("totalWords") private var totalWords = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hotkey: HotkeyKey {
        HotkeyKey(rawValue: Int64(hotkeyKeyCode)) ?? .default
    }

    var body: some View {
        VStack(spacing: 10) {
            statusHeader

            statsRow

            if let update = appState.updateChecker.available {
                updateRow(update)
            }

            if showLastTranscription && !appState.lastTranscription.isEmpty {
                LastTranscriptionCard(text: appState.lastTranscription, style: .compact)
            }

            footer
        }
        .padding(12)
        .frame(width: 300)
        .background(Theme.surfaceBackground)
    }

    // MARK: - Status Header

    private var statusHeader: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(.quaternary.opacity(0.5))
                    .frame(width: 40, height: 40)

                Image(systemName: appState.status.iconName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(appState.status.color)
                    .symbolEffect(.pulse, isActive: !reduceMotion && appState.status.isRecording)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(appState.status.label)
                    .font(.system(.body, design: .rounded, weight: .bold))
                    .foregroundStyle(.primary)

                if appState.status == .ready {
                    HStack(spacing: 5) {
                        Text("Hold")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        KeycapChip(label: hotkey.name)
                        Text("to dictate")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(statusSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if appState.status.isRecording {
                Text(appState.recordingDuration.dictationDurationLabel)
                    .font(.system(.callout, design: .monospaced, weight: .medium))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
        }
        .padding(12)
        .background(Theme.surfaceCard, in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
    }

    private var statusSubtitle: String {
        switch appState.status {
        case .ready: return "Hold \(hotkey.name) to dictate"
        case .listening: return "Release to transcribe"
        case .transcribing: return "Processing audio…"
        case .error: return "Something went wrong"
        }
    }

    // MARK: - Stats

    private var statsRow: some View {
        HStack(spacing: 8) {
            StatChip(value: formatCount(totalDictations), label: "dictations")
            StatChip(value: formatCount(totalWords), label: "words spoken")
        }
    }

    private func formatCount(_ value: Int) -> String {
        if value >= 10_000 {
            return String(format: "%.1fk", Double(value) / 1000)
        }
        return "\(value)"
    }

    // MARK: - Update

    private func updateRow(_ update: UpdateChecker.UpdateInfo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.body.weight(.medium))
                .foregroundStyle(Theme.accent)

            Text("VoiceYak \(update.version) is available")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)

            Spacer()

            Button("View") {
                NSWorkspace.shared.open(update.releaseURL)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(Theme.accent)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.surfaceCard, in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 4) {
            FooterButton(title: "Settings", icon: "gearshape.fill") {
                openMainWindow(.general)
            }

            Spacer()

            FooterButton(title: "Quit", icon: "power", isDestructive: true) {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func openMainWindow(_ section: MainSection) {
        appState.requestMainWindow(section)
    }
}

// MARK: - Components

/// Keyboard-key styled chip for the hotkey hint.
private struct KeycapChip: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(.caption2, design: .rounded, weight: .semibold))
            .foregroundStyle(.primary)
            .accessibilityHidden(true)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.quaternary.opacity(0.6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(.quaternary, lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.15), radius: 0, y: 1)
            }
    }
}

private struct StatChip: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(.primary)
                .contentTransition(.numericText())

            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Theme.surfaceCard, in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
    }
}

private struct FooterButton: View {
    let title: String
    let icon: String
    var isDestructive = false
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button {
            dismiss()
            action()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.caption2.weight(.medium))
                Text(title)
                    .font(.subheadline.weight(.medium))
            }
            .foregroundStyle(isDestructive ? AnyShapeStyle(Color.red.opacity(0.85)) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isHovered ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
