import SwiftUI

@main
struct VoiceYakApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    private let appState = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appState: appState)
        } label: {
            MenuBarIconView(appState: appState)
        }
        .menuBarExtraStyle(.window)

        Window("VoiceYak", id: "main") {
            MainWindowView(appState: appState)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 960, height: 640)
        .defaultPosition(.center)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window("Welcome to VoiceYak", id: "onboarding") {
            OnboardingView(appState: appState)
                // Accessory apps don't take focus on their own.
                .onAppear { NSApp.activate() }
                // Manual close means "skip for now" — otherwise
                // showOnboarding stays true with the window gone, stranding
                // onboarding until relaunch. The General pane still surfaces
                // any missing permissions afterward.
                .onDisappear { appState.showOnboarding = false }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .windowBackgroundDragBehavior(.enabled)
        .defaultPosition(.center)
        .defaultLaunchBehavior(
            UserDefaults.standard.hasCompletedOnboarding ? .suppressed : .presented
        )
        .restorationBehavior(.disabled)
    }
}

/// The status-bar icon. Also installs the openMainWindow bridge: this view
/// exists for the app's whole lifetime, and only a View can reach the
/// openWindow environment action that AppDelegate and the menu popover need.
struct MenuBarIconView: View {
    let appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Label("VoiceYak", systemImage: appState.status.iconName)
            .onAppear {
                appState.openMainWindow = { section in
                    appState.dashboardSection = section
                    openWindow(id: "main")
                    NSApp.activate()
                }
            }
    }
}
