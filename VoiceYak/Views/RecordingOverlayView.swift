import SwiftUI

/// Compact pill shown near the bottom of the screen while recording:
/// a live equalizer, a timer, and nothing else.
struct RecordingOverlayView: View {
    let appState: AppState

    @State private var spinnerRotation: Angle = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Live preview text shows while listening once chunked transcription
    /// has produced something.
    private var hasPreview: Bool {
        appState.status == .listening &&
        (!appState.previewStable.isEmpty || !appState.previewProvisional.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if case .error(let message) = appState.status {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(2)
                        .frame(maxWidth: 340)
                        .fixedSize(horizontal: false, vertical: true)
                } else if appState.status == .transcribing {
                    spinner
                    Text("Transcribing")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                } else {
                    equalizer
                    Text(appState.recordingDuration.dictationDurationLabel)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                        .contentTransition(.numericText())
                }
            }

            if hasPreview {
                previewText
            }
        }
        .padding(.horizontal, hasPreview ? 16 : 14)
        .padding(.vertical, hasPreview ? 12 : 9)
        .frame(width: hasPreview ? 380 : nil)
        // Regular (adaptive) Liquid Glass, not clear: the pill floats over
        // arbitrary desktop content and must stay legible everywhere. The
        // pill keeps its dark identity in both system appearances.
        .glassEffect(.regular, in: .rect(cornerRadius: hasPreview ? 18 : 32, style: .continuous))
        .environment(\.colorScheme, .dark)
        .shadow(color: .black.opacity(0.28), radius: 12, y: 5)
        .animation(reduceMotion ? nil : Theme.spring, value: hasPreview)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Stable text renders solid; the provisional tail renders dimmer and
    /// italic so it visibly may still refine.
    private var previewText: some View {
        Text("\(stableTextSegment)\(provisionalTextSegment)")
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .lineLimit(2)
            .truncationMode(.head)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stableTextSegment: Text {
        let separator = appState.previewStable.isEmpty || appState.previewProvisional.isEmpty ? "" : " "
        return Text(appState.previewStable + separator)
            .foregroundStyle(.white.opacity(0.9))
    }

    private var provisionalTextSegment: Text {
        Text(appState.previewProvisional)
            .italic()
            .foregroundStyle(.white.opacity(0.5))
    }

    // MARK: - Components

    /// Live wave: the shared bar visualizer at a fast interval. The view
    /// unmounts whenever the pill isn't showing the listening layout, so
    /// its animation task starts and stops with each recording naturally.
    private var equalizer: some View {
        AmbientEqualizer(
            barCount: 7,
            barWidth: 2.5,
            maxHeight: 16,
            color: Theme.accent,
            opacity: 1.0,
            interval: .milliseconds(140)
        )
        .frame(width: 36, height: 16)
    }

    private var spinner: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(
                AngularGradient(
                    colors: [Theme.accent.opacity(0), Theme.accent],
                    center: .center
                ),
                style: StrokeStyle(lineWidth: 2, lineCap: .round)
            )
            .frame(width: 14, height: 14)
            .rotationEffect(spinnerRotation)
            .accessibilityHidden(true)
            .onAppear {
                // Reset first: on remount the state still holds 360° and
                // animating to the same value would leave it frozen.
                spinnerRotation = .zero
                // Reduce Motion: render the static arc, no rotation.
                guard !reduceMotion else { return }
                Task { @MainActor in
                    withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                        spinnerRotation = .degrees(360)
                    }
                }
            }
    }

}
