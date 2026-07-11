import CoreGraphics

/// Modifier keys the user can hold to dictate.
///
/// Only modifier keys are offered: the event tap listens to `flagsChanged`
/// exclusively, so holding one never types characters into the focused app.
/// Raw values are macOS virtual key codes.
/// nonisolated: read from the event-tap C callback.
nonisolated enum HotkeyKey: Int64, CaseIterable, Identifiable {
    case rightOption = 61
    case leftOption = 58
    case rightCommand = 54
    case rightControl = 62
    case rightShift = 60
    case fn = 63

    static let `default`: HotkeyKey = .rightOption

    var id: Int64 { rawValue }

    /// Short name for hints like "Hold Right Option to dictate".
    var name: String {
        switch self {
        case .rightOption: return "Right Option"
        case .leftOption: return "Left Option"
        case .rightCommand: return "Right Command"
        case .rightControl: return "Right Control"
        case .rightShift: return "Right Shift"
        case .fn: return "Fn / Globe"
        }
    }

    /// Full label for the settings picker.
    var displayName: String {
        switch self {
        case .rightOption: return "Right Option (\u{2325})"
        case .leftOption: return "Left Option (\u{2325})"
        case .rightCommand: return "Right Command (\u{2318})"
        case .rightControl: return "Right Control (\u{2303})"
        case .rightShift: return "Right Shift (\u{21E7})"
        case .fn: return "Fn / Globe"
        }
    }

    /// The flag bit that indicates this key is held in a `flagsChanged` event.
    var flagMask: CGEventFlags {
        switch self {
        case .rightOption, .leftOption: return .maskAlternate
        case .rightCommand: return .maskCommand
        case .rightControl: return .maskControl
        case .rightShift: return .maskShift
        case .fn: return .maskSecondaryFn
        }
    }

    /// Device-specific NX_DEVICE… bit distinguishing the left/right
    /// instance of a paired modifier, or nil for unpaired keys (Fn).
    /// The aggregate `flagMask` stays set while EITHER side is held, so
    /// release detection through it misses "hold Right Option, also
    /// press+release Left Option" sequences. Stable bits since 10.0.
    var deviceFlagMask: UInt64? {
        switch self {
        case .rightOption:  return 0x0000_0040   // NX_DEVICERALTKEYMASK
        case .leftOption:   return 0x0000_0020   // NX_DEVICELALTKEYMASK
        case .rightCommand: return 0x0000_0010   // NX_DEVICERCMDKEYMASK
        case .rightControl: return 0x0000_2000   // NX_DEVICERCTLKEYMASK
        case .rightShift:   return 0x0000_0004   // NX_DEVICERSHIFTKEYMASK
        case .fn:           return nil
        }
    }
}
