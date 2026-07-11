import AppKit
import Observation
import SwiftUI

final class RecordingOverlayPanel {
    /// Built once and reused — rebuilding the panel and SwiftUI hosting
    /// view on every recording delayed the overlay's appearance.
    private var panel: NSPanel?
    private let appState: AppState
    private var statusTask: Task<Void, Never>?

    // Slightly larger than the pill itself so its glow isn't clipped.
    // The pill grows for the live transcription preview; the panel must
    // fit the larger of the two layouts (content stays centered).
    private var panelSize: NSSize {
        if UserDefaults.standard.chunkedTranscription && UserDefaults.standard.livePreview {
            return NSSize(width: 420, height: 120)
        }
        return NSSize(width: 220, height: 64)
    }

    init(appState: AppState) {
        self.appState = appState
        // Errors drive the pill directly: they can arrive after the key-up
        // already hid the panel (engine failure, transcription failure) or
        // mid-hold when the panel was sized for the normal layout.
        // Observations delivers coalesced, in-order values on the main
        // actor, so unlike the old @Published sink there is no stale-task
        // window. Transient errors reset to .ready, which hides the pill.
        statusTask = Task { @MainActor [weak self] in
            guard let appState = self?.appState else { return }
            for await status in Observations({ appState.status }) {
                guard let self else { return }
                switch status {
                case .error: self.show()
                case .ready: self.panel?.orderOut(nil)
                default: break
                }
            }
        }
    }

    @MainActor
    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // The preview setting may have changed since the panel was built.
        // An error message needs the wide layout regardless of settings.
        var size = panelSize
        if case .error = appState.status {
            size = NSSize(width: 420, height: 120)
        }
        if panel.frame.size != size {
            panel.setContentSize(size)
            panel.contentView?.frame = NSRect(origin: .zero, size: size)
        }
        position(panel)
        panel.orderFrontRegardless()
    }

    @MainActor
    func hide() {
        // Keep an error pill visible — the key-up that triggers hide()
        // arrives right after the failed key-down. The status observer
        // hides it when the transient error resets to .ready.
        if case .error = appState.status { return }
        panel?.orderOut(nil)
    }

    @MainActor
    private func makePanel() -> NSPanel {
        let hostingView = NSHostingView(rootView: RecordingOverlayView(appState: appState))
        // The panel is sized manually in show(); letting the hosting view
        // drive window size via constraints fights that and spirals into a
        // layout feedback loop (NSGenericException: too many Update
        // Constraints in Window passes).
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(origin: .zero, size: panelSize)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.contentView = hostingView
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = true
        return panel
    }

    /// Recomputed on every show — the main screen can change between
    /// recordings.
    @MainActor
    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - panel.frame.width / 2
        let y = screenFrame.minY + 32
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
