import SwiftUI

struct OnboardingView: View {
    let appState: AppState

    @State private var currentStep = 0
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let totalSteps = 4

    private var permissions: PermissionsManager { appState.permissions }
    private var downloader: ModelDownloader { appState.modelDownloader }

    var body: some View {
        VStack(spacing: 0) {
            stepIndicator
                .padding(.top, 28)
                .padding(.bottom, 24)

            ZStack {
                stepContent
                    .id(currentStep)
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            navigationBar
                .padding(24)
        }
        .frame(width: 540, height: 560)
        .animation(reduceMotion ? nil : Theme.spring, value: currentStep)
        // Poll permission status while on the permission steps — grants
        // happen in System Settings with no notification. .task(id:)
        // auto-cancels on step change and on disappear.
        .task(id: currentStep) {
            guard currentStep == 1 || currentStep == 2 else { return }
            while !Task.isCancelled {
                permissions.checkAll()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case 0: welcomeStep
        case 1: microphoneStep
        case 2: accessibilityStep
        case 3: modelStep
        default: welcomeStep
        }
    }

    // MARK: - Step Indicator

    private var stepIndicator: some View {
        HStack(spacing: 7) {
            ForEach(0..<totalSteps, id: \.self) { step in
                Capsule()
                    .fill(step == currentStep
                          ? AnyShapeStyle(Theme.accent)
                          : AnyShapeStyle(Color.secondary.opacity(step < currentStep ? 0.5 : 0.25)))
                    .frame(width: step == currentStep ? 22 : 6, height: 6)
            }
        }
        .animation(reduceMotion ? nil : Theme.spring, value: currentStep)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(currentStep + 1) of \(totalSteps)")
    }

    // MARK: - Navigation

    private var navigationBar: some View {
        HStack {
            if currentStep > 0 {
                Button("Back") {
                    currentStep -= 1
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if currentStep < totalSteps - 1 {
                Button("Continue") {
                    currentStep += 1
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            } else {
                Button("Start Dictating") {
                    finishOnboarding()
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(!canFinish)
            }
        }
    }

    private var canFinish: Bool {
        permissions.microphoneGranted &&
        Constants.isParakeetModelDownloaded
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 0) {
            Spacer()

            // Hero: the app icon itself
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.25), radius: 10, y: 5)
                .padding(.bottom, 18)

            AmbientEqualizer(barCount: 9, barWidth: 3, maxHeight: 18)
                .padding(.bottom, 28)

            VStack(spacing: 10) {
                Text("Welcome to VoiceYak")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))

                Text("Speak anywhere text goes.\nPrivate, on-device, no internet required.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 26)

            VStack(alignment: .leading, spacing: 14) {
                FeatureRow(icon: "keyboard", text: "Hold \(HotkeyKey.default.name) and talk")
                FeatureRow(icon: "cursorarrow.rays", text: "Words appear where your cursor is")
                FeatureRow(icon: "lock.shield.fill", text: "Audio never leaves your Mac")
            }

            Spacer()
        }
        .padding(.horizontal, 48)
    }

    // MARK: - Step 2: Microphone

    private var microphoneStep: some View {
        PermissionStep(
            icon: "mic.badge.plus",
            title: "Microphone",
            subtitle: "VoiceYak listens only while you hold the\ndictation key, and only on this Mac.",
            isGranted: permissions.microphoneGranted,
            grantedLabel: "Microphone allowed",
            primaryLabel: "Allow Microphone",
            primaryAction: {
                Task { await permissions.requestMicrophone() }
            }
        )
    }

    // MARK: - Step 3: Accessibility

    private var accessibilityStep: some View {
        PermissionStep(
            icon: "hand.raised.fill",
            title: "Accessibility",
            subtitle: "Lets VoiceYak notice the dictation key anywhere\nand place text into the app you're using.",
            isGranted: permissions.accessibilityGranted,
            grantedLabel: "Accessibility allowed",
            primaryLabel: "Open System Settings",
            primaryAction: {
                permissions.requestAccessibility()
            },
            secondaryLabel: "Check Again",
            secondaryAction: {
                permissions.checkAccessibility()
            }
        )
    }

    // MARK: - Step 4: Model Download

    private var modelStep: some View {
        VStack(spacing: 0) {
            Spacer()

            StepHero(icon: "waveform.and.arrow.down")

            VStack(spacing: 10) {
                Text("Voice Model")
                    .font(.system(.title, design: .rounded, weight: .bold))

                Text("One download (\(VoiceModel.selected.displaySize)), then VoiceYak\nworks offline forever.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 24)

            let downloadState = downloader.downloadState

            if Constants.isParakeetModelDownloaded || downloadState?.isComplete == true {
                GrantedPill(label: "Model downloaded and ready")
            } else if let state = downloadState, state.error == nil {
                VStack(spacing: 10) {
                    ProgressView(value: state.progress)
                        .tint(Theme.accent)
                        .frame(width: 220)

                    Text("Downloading… \(Int(state.progress * 100))%")
                        .font(.system(.callout, design: .monospaced, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 10) {
                    Button("Download Model") {
                        downloader.download()
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)

                    if let error = downloadState?.error {
                        Text(error)
                            .font(.subheadline)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
                }
            }

            Spacer()
        }
        .padding(.horizontal, 48)
    }

    // MARK: - Actions

    private func finishOnboarding() {
        UserDefaults.standard.hasCompletedOnboarding = true
        appState.showOnboarding = false
        Task { await appState.loadModelIfNeeded() }
        dismiss()
    }
}

// MARK: - Shared step components

/// Icon hero used by every step after the welcome screen.
private struct StepHero: View {
    let icon: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .fill(.quaternary.opacity(0.5))
                .frame(width: 76, height: 76)

            Image(systemName: icon)
                .font(.system(size: 34, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Theme.accent)
        }
        .padding(.bottom, 20)
    }
}

/// Layout shared by the two permission steps: hero, copy, then either a
/// granted pill or the action buttons.
private struct PermissionStep: View {
    let icon: String
    let title: String
    let subtitle: String
    let isGranted: Bool
    let grantedLabel: String
    let primaryLabel: String
    let primaryAction: () -> Void
    var secondaryLabel: String? = nil
    var secondaryAction: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            StepHero(icon: icon)

            VStack(spacing: 10) {
                Text(title)
                    .font(.system(.title, design: .rounded, weight: .bold))

                Text(subtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 24)

            if isGranted {
                GrantedPill(label: grantedLabel)
            } else {
                VStack(spacing: 12) {
                    Button(primaryLabel, action: primaryAction)
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)

                    if let secondaryLabel, let secondaryAction {
                        Button(secondaryLabel, action: secondaryAction)
                            .buttonStyle(.plain)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()
        }
        .padding(.horizontal, 48)
    }
}

private struct GrantedPill: View {
    let label: String

    var body: some View {
        Label(label, systemImage: "checkmark.circle.fill")
            .font(.body.weight(.medium))
            .foregroundStyle(.green)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background {
                Capsule().fill(.green.opacity(0.12))
            }
    }
}

// MARK: - Feature Row

struct FeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 28, height: 28)
                .background(.quaternary.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(text)
                .font(.body)
                .foregroundStyle(.primary)
        }
    }
}
