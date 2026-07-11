import SwiftUI

/// VoiceYak's visual language: native structure with a warm identity.
/// One brand accent (amber-orange, sourced from the asset catalog so it
/// also drives `.tint`), system-adaptive surfaces, semantic red/green only
/// where they carry meaning, and no decorative gradients outside the hero.
enum Theme {
    /// The brand accent — a warm amber-orange (asset catalog AccentColor).
    static let accent = Color.accentColor

    /// Window-level surface behind the dashboard and menu popover.
    static let surfaceBackground = Color(nsColor: .underPageBackgroundColor)

    /// Elevated cards sitting on `surfaceBackground`.
    static let surfaceCard = Color(nsColor: .controlBackgroundColor)

    /// Hero card gradient — brand identity, deliberately identical in both
    /// appearances; text on it stays white.
    static let heroGradientStart = Color(red: 0.96, green: 0.45, blue: 0.14)
    static let heroGradientEnd = Color(red: 0.62, green: 0.13, blue: 0.10)

    /// Corner-radius scale for surfaces. Micro-geometry (keycaps, active
    /// indicator bars, the pill's own shape) keeps its literal values.
    enum Radius {
        /// Chips and small controls.
        static let small: CGFloat = 6
        /// Cards and rows.
        static let medium: CGFloat = 12
        /// Hero card and large panes.
        static let large: CGFloat = 20
    }

    /// The app's standard springy transition.
    static let spring = Animation.spring(response: 0.35, dampingFraction: 0.8)
}

/// Ambient equalizer — quiet monochrome bars that drift gently. Used in
/// onboarding; the recording pill draws its own live version.
struct AmbientEqualizer: View {
    var barCount: Int = 9
    var barWidth: CGFloat = 3
    var maxHeight: CGFloat = 22
    var color: Color = .secondary
    var opacity: Double = 0.55
    var interval: Duration = .milliseconds(600)

    @State private var amplitudes: [CGFloat] = []
    @State private var animationTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: barWidth * 1.2) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: barWidth / 2)
                    .fill(color.opacity(opacity))
                    .frame(width: barWidth, height: barHeight(index))
            }
        }
        .accessibilityHidden(true)
        .onAppear { start() }
        .onDisappear { stop() }
    }

    private func barHeight(_ index: Int) -> CGFloat {
        let amplitude = index < amplitudes.count ? amplitudes[index] : 0.3
        return maxHeight * 0.25 + amplitude * maxHeight * 0.75
    }

    private func start() {
        amplitudes = (0..<barCount).map { _ in CGFloat.random(in: 0.2...1.0) }
        animationTask?.cancel()
        // Reduce Motion: keep the once-randomized static bars, no loop.
        guard !reduceMotion else { return }
        animationTask = Task {
            while !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.55)) {
                    amplitudes = (0..<barCount).map { _ in CGFloat.random(in: 0.2...1.0) }
                }
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func stop() {
        animationTask?.cancel()
        animationTask = nil
    }
}
