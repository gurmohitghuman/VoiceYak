import SwiftUI

/// Sections reachable from the dashboard sidebar.
enum MainSection: String, CaseIterable, Identifiable {
    case home
    case general
    case model
    case output
    case dictionary
    case advanced
    case credits

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .general: return "General"
        case .model: return "Voice Model"
        case .output: return "Output"
        case .dictionary: return "Dictionary"
        case .advanced: return "Advanced"
        case .credits: return "Credits"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .general: return "gearshape.fill"
        case .model: return "waveform"
        case .output: return "text.cursor"
        case .dictionary: return "character.book.closed.fill"
        case .advanced: return "flask.fill"
        case .credits: return "heart.fill"
        }
    }
}

/// VoiceYak's main window: a dark dashboard with sidebar navigation.
/// Home is the hero surface; the settings panes live in the same window.
/// The sidebar selection lives on AppState so the menu popover (and dock
/// reopen) can open the window at a specific section via openMainWindow.
struct MainWindowView: View {
    @Bindable var appState: AppState

    var body: some View {
        HStack(spacing: 0) {
            sidebar

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.surfaceBackground)
        .frame(minWidth: 940, minHeight: 620)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Logo — white-tile brand mark for the dark sidebar
            HStack(spacing: 10) {
                Image("LogoWhite")
                    .resizable()
                    .frame(width: 30, height: 30)
                    .clipShape(Circle())

                Text("VoiceYak")
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 48)
            .padding(.bottom, 28)

            SidebarItem(section: .home, current: $appState.dashboardSection)

            Text("Settings")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .tracking(0.8)
                .padding(.horizontal, 20)
                .padding(.top, 22)
                .padding(.bottom, 6)

            SidebarItem(section: .general, current: $appState.dashboardSection)
            SidebarItem(section: .model, current: $appState.dashboardSection)
            SidebarItem(section: .output, current: $appState.dashboardSection)
            SidebarItem(section: .dictionary, current: $appState.dashboardSection)
            SidebarItem(section: .advanced, current: $appState.dashboardSection)

            Spacer()

            SidebarItem(section: .credits, current: $appState.dashboardSection)
                .padding(.bottom, 16)
        }
        .frame(width: 210)
        .background(.thinMaterial)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch appState.dashboardSection {
        case .home:
            HomeDashboardView(appState: appState)
        case .general:
            GeneralSettingsPane(appState: appState)
                .scrollContentBackground(.hidden)
        case .model:
            ModelManagerView(appState: appState)
                .scrollContentBackground(.hidden)
        case .output:
            OutputSettingsPane(appState: appState)
                .scrollContentBackground(.hidden)
        case .dictionary:
            DictionaryPane()
                .scrollContentBackground(.hidden)
        case .advanced:
            AdvancedSettingsPane()
                .scrollContentBackground(.hidden)
        case .credits:
            CreditsView()
                .scrollContentBackground(.hidden)
        }
    }
}

// MARK: - Sidebar Item

private struct SidebarItem: View {
    let section: MainSection
    @Binding var current: MainSection
    @State private var isHovered = false

    private var isActive: Bool { current == section }

    var body: some View {
        Button {
            current = section
        } label: {
            HStack(spacing: 11) {
                // Active indicator bar, like the reference's nav
                RoundedRectangle(cornerRadius: 2)
                    .fill(isActive ? Theme.accent : .clear)
                    .frame(width: 3, height: 18)

                Image(systemName: section.icon)
                    .font(.body.weight(.medium))
                    .foregroundStyle(isActive ? Theme.accent : .secondary)
                    .frame(width: 20)

                Text(section.title)
                    .font(.body.weight(isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? Theme.accent : Color.primary.opacity(0.8))

                Spacer()
            }
            .padding(.vertical, 8)
            .padding(.trailing, 12)
            .padding(.leading, 9)
            .background(
                isHovered && !isActive ? Color.primary.opacity(0.06) : .clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .onHover { isHovered = $0 }
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

// MARK: - Home

private struct HomeDashboardView: View {
    let appState: AppState
    @AppStorage("hotkeyKeyCode") private var hotkeyKeyCode = Int(HotkeyKey.default.rawValue)
    @AppStorage("totalDictations") private var totalDictations = 0
    @AppStorage("totalWords") private var totalWords = 0
    @AppStorage("showLastTranscription") private var showLastTranscription = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var downloader: ModelDownloader { appState.modelDownloader }

    private var hotkey: HotkeyKey {
        HotkeyKey(rawValue: Int64(hotkeyKeyCode)) ?? .default
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                heroCard

                HStack(spacing: 16) {
                    statCard(value: "\(totalDictations)", label: "Dictations", icon: "mic.fill")
                    statCard(value: "\(totalWords)", label: "Words spoken", icon: "text.word.spacing")
                    modelCard
                }

                if showLastTranscription && !appState.lastTranscription.isEmpty {
                    LastTranscriptionCard(text: appState.lastTranscription, style: .regular)
                }
            }
            .padding(24)
        }
    }

    // MARK: Hero

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 10) {
                    Text(heroTitle)
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .foregroundStyle(.white)

                    HStack(spacing: 7) {
                        Text("Hold")
                            .font(.body)
                            .foregroundStyle(.white.opacity(0.85))

                        Text(hotkey.name)
                            .font(.system(.callout, design: .rounded, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 5, style: .continuous))

                        Text("and speak. Your words appear wherever your cursor is.")
                            .font(.body)
                            .foregroundStyle(.white.opacity(0.85))
                    }

                    Text("Private, on-device, works in every app.")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.6))
                }

                Spacer()

                ZStack {
                    Circle()
                        .fill(.white.opacity(0.14))
                        .frame(width: 84, height: 84)

                    Image(systemName: appState.status.isRecording ? "mic.fill" : "mic")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(.white)
                        .symbolEffect(.pulse, isActive: !reduceMotion && appState.status.isRecording)
                }
            }
            .padding(26)

            AmbientEqualizer(barCount: 42, barWidth: 3, maxHeight: 26, color: .white)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 26)
                .padding(.bottom, 22)
                .opacity(0.75)
        }
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Theme.heroGradientStart, Theme.heroGradientEnd],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
    }

    private var heroTitle: String {
        switch appState.status {
        case .ready: return "Ready to dictate"
        case .listening: return "Listening…"
        case .transcribing: return "Transcribing…"
        case .error: return "Something went wrong"
        }
    }

    // MARK: Cards

    private func statCard(value: String, label: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.title3.weight(.medium))
                .foregroundStyle(Theme.accent)

            Text(value)
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .foregroundStyle(.primary)
                .contentTransition(.numericText())

            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Theme.surfaceCard, in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
    }

    private var modelCard: some View {
        Button {
            appState.dashboardSection = .model
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "waveform")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(Theme.accent)

                Text(downloader.isModelDownloaded ? "Ready" : "Not installed")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .foregroundStyle(downloader.isModelDownloaded ? .primary : Theme.accent)

                Text("Parakeet voice model")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(Theme.surfaceCard, in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Voice model status. Opens voice model settings.")
    }

}
