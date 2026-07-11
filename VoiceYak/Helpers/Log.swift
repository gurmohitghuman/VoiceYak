import os

/// Unified logging. Filter in Console.app by subsystem ghuman.VoiceYak.
/// Transcribed text and the identity of the app being dictated into are
/// user data: interpolate them with `privacy: .private`.
nonisolated enum Log {
    private static let subsystem = "ghuman.VoiceYak"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let recording = Logger(subsystem: subsystem, category: "recording")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let transcription = Logger(subsystem: subsystem, category: "transcription")
    static let models = Logger(subsystem: subsystem, category: "models")
    static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
}
