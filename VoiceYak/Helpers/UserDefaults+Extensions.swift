import Foundation

extension UserDefaults {

    // MARK: - Keys
    private nonisolated enum Keys {
        static let showDockIcon = "showDockIcon"
        static let showLastTranscription = "showLastTranscription"
        static let playCompletionSound = "playCompletionSound"
        static let autoCapitalize = "autoCapitalize"
        static let addTrailingSpace = "addTrailingSpace"
        static let restoreClipboard = "restoreClipboard"
        static let maxRecordingDuration = "maxRecordingDuration"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let hotkeyKeyCode = "hotkeyKeyCode"
        static let checkForUpdates = "checkForUpdates"
        static let lastUpdateCheckAt = "lastUpdateCheckAt"
        static let totalDictations = "totalDictations"
        static let totalWords = "totalWords"
        static let selectedVoiceModel = "selectedVoiceModel"
    }

    // MARK: - Registration

    /// Registers every preference whose default is not the type's zero
    /// value, so plain `bool(forKey:)`/`double(forKey:)` reads return the
    /// right default before anything is written. Called first thing at
    /// launch, before any other code reads a preference.
    nonisolated static func registerVoiceYakDefaults() {
        standard.register(defaults: [
            Keys.showDockIcon: true,
            Keys.showLastTranscription: true,
            Keys.playCompletionSound: true,
            Keys.autoCapitalize: true,
            Keys.addTrailingSpace: true,
            Keys.restoreClipboard: true,
            Keys.maxRecordingDuration: Constants.maximumRecordingDuration,
            Keys.selectedVoiceModel: "multilingual",
        ])
    }

    // MARK: - Voice Model
    /// nonisolated: read from VoiceModel.selected in nonisolated contexts.
    nonisolated var selectedVoiceModel: String {
        get { string(forKey: Keys.selectedVoiceModel) ?? "multilingual" }
        set { set(newValue, forKey: Keys.selectedVoiceModel) }
    }

    // MARK: - Usage Stats
    var totalDictations: Int {
        get { integer(forKey: Keys.totalDictations) }
        set { set(newValue, forKey: Keys.totalDictations) }
    }

    var totalWords: Int {
        get { integer(forKey: Keys.totalWords) }
        set { set(newValue, forKey: Keys.totalWords) }
    }

    // MARK: - Updates
    /// Opt-in, chosen during onboarding; off unless the user enables it.
    var checkForUpdates: Bool {
        get { bool(forKey: Keys.checkForUpdates) }
        set { set(newValue, forKey: Keys.checkForUpdates) }
    }

    var lastUpdateCheckAt: TimeInterval {
        get { double(forKey: Keys.lastUpdateCheckAt) }
        set { set(newValue, forKey: Keys.lastUpdateCheckAt) }
    }

    // MARK: - Hotkey
    /// nonisolated: read from the event-tap C callback.
    nonisolated var hotkeyKey: HotkeyKey {
        get { HotkeyKey(rawValue: Int64(integer(forKey: Keys.hotkeyKeyCode))) ?? .default }
        set { set(Int(newValue.rawValue), forKey: Keys.hotkeyKeyCode) }
    }

    // MARK: - General
    var showDockIcon: Bool {
        get { bool(forKey: Keys.showDockIcon) }
        set { set(newValue, forKey: Keys.showDockIcon) }
    }

    var showLastTranscription: Bool {
        get { bool(forKey: Keys.showLastTranscription) }
        set { set(newValue, forKey: Keys.showLastTranscription) }
    }

    var playCompletionSound: Bool {
        get { bool(forKey: Keys.playCompletionSound) }
        set { set(newValue, forKey: Keys.playCompletionSound) }
    }

    // MARK: - Output
    var autoCapitalize: Bool {
        get { bool(forKey: Keys.autoCapitalize) }
        set { set(newValue, forKey: Keys.autoCapitalize) }
    }

    var addTrailingSpace: Bool {
        get { bool(forKey: Keys.addTrailingSpace) }
        set { set(newValue, forKey: Keys.addTrailingSpace) }
    }

    var restoreClipboard: Bool {
        get { bool(forKey: Keys.restoreClipboard) }
        set { set(newValue, forKey: Keys.restoreClipboard) }
    }

    // MARK: - Advanced
    var maxRecordingDuration: TimeInterval {
        get {
            // Guard against a stray 0 write; registration provides the
            // normal default.
            let val = double(forKey: Keys.maxRecordingDuration)
            return val > 0 ? val : Constants.maximumRecordingDuration
        }
        set { set(newValue, forKey: Keys.maxRecordingDuration) }
    }

    // MARK: - Onboarding
    var hasCompletedOnboarding: Bool {
        get { bool(forKey: Keys.hasCompletedOnboarding) }
        set { set(newValue, forKey: Keys.hasCompletedOnboarding) }
    }
}
