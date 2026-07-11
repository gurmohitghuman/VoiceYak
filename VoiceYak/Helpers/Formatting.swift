import Foundation

nonisolated extension TimeInterval {
    /// "1:07.3" / "7.3s"-style dictation duration, shared by the recording
    /// pill and the menu popover.
    var dictationDurationLabel: String {
        let totalSeconds = Int(self)
        let tenths = Int(self * 10) % 10
        if totalSeconds >= 60 {
            let minutes = totalSeconds / 60
            let seconds = totalSeconds % 60
            return String(format: "%d:%02d.%ds", minutes, seconds, tenths)
        }
        return String(format: "%d.%ds", totalSeconds, tenths)
    }
}
