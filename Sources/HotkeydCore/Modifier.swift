import CoreGraphics
import Foundation

/// A modifier requirement.
///
/// `Modifier.command` means "either Command key"; `Modifier.leftCommand` means the left one
/// specifically. The same type is used for gestures and for key combos, so a binding can be as
/// precise or as permissive as the user wants.
public struct Modifier: Hashable, Sendable {
    public enum Family: String, Codable, CaseIterable, Sendable {
        case command
        case option
        case control
        case shift
        case fn
        case capsLock
    }

    public enum Side: String, Codable, Sendable {
        case left
        case right
    }

    public let family: Family
    public let side: Side?

    public init(_ family: Family, _ side: Side? = nil) {
        self.family = family
        self.side = side
    }

    public static let command = Modifier(.command)
    public static let leftCommand = Modifier(.command, .left)
    public static let rightCommand = Modifier(.command, .right)
    public static let option = Modifier(.option)
    public static let leftOption = Modifier(.option, .left)
    public static let rightOption = Modifier(.option, .right)
    public static let control = Modifier(.control)
    public static let leftControl = Modifier(.control, .left)
    public static let rightControl = Modifier(.control, .right)
    public static let shift = Modifier(.shift)
    public static let leftShift = Modifier(.shift, .left)
    public static let rightShift = Modifier(.shift, .right)
    public static let fn = Modifier(.fn)
    public static let capsLock = Modifier(.capsLock)

    /// The side-agnostic form of this modifier, e.g. `lcmd` -> `cmd`.
    public var familyOnly: Modifier { Modifier(family) }

    public var isSideSpecific: Bool { side != nil }

    public var cgFlag: CGEventFlags {
        switch family {
        case .command: return .maskCommand
        case .option: return .maskAlternate
        case .control: return .maskControl
        case .shift: return .maskShift
        case .fn: return .maskSecondaryFn
        case .capsLock: return []
        }
    }

    /// Canonical token used in config, keys strings and trigger displays.
    public var token: String {
        switch family {
        case .command:
            switch side {
            case .left: return "lcmd"
            case .right: return "rcmd"
            case nil: return "cmd"
            }
        case .option:
            switch side {
            case .left: return "lopt"
            case .right: return "ropt"
            case nil: return "opt"
            }
        case .control:
            switch side {
            case .left: return "lctrl"
            case .right: return "rctrl"
            case nil: return "ctrl"
            }
        case .shift:
            switch side {
            case .left: return "lshift"
            case .right: return "rshift"
            case nil: return "shift"
            }
        case .fn: return "fn"
        case .capsLock: return "capsLock"
        }
    }

    public var glyph: String {
        switch family {
        case .command: return "⌘"
        case .option: return "⌥"
        case .control: return "⌃"
        case .shift: return "⇧"
        case .fn: return "fn"
        case .capsLock: return "⇪"
        }
    }

    /// Accepts the names a human or an agent is likely to type, including side-specific forms.
    public static func parse(_ raw: String) -> Modifier? {
        let compact = raw
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")

        switch compact {
        case "cmd", "command", "super", "⌘": return .command
        case "lcmd", "leftcmd", "leftcommand", "lsuper": return .leftCommand
        case "rcmd", "rightcmd", "rightcommand", "rsuper": return .rightCommand

        case "opt", "option", "alt", "⌥": return .option
        case "lopt", "leftopt", "leftoption", "leftalt", "lalt": return .leftOption
        case "ropt", "rightopt", "rightoption", "rightalt", "ralt": return .rightOption

        case "ctrl", "control", "ctl", "⌃": return .control
        case "lctrl", "leftctrl", "leftcontrol": return .leftControl
        case "rctrl", "rightctrl", "rightcontrol": return .rightControl

        case "shift", "⇧": return .shift
        case "lshift", "leftshift": return .leftShift
        case "rshift", "rightshift": return .rightShift

        case "fn", "function", "globe", "🌐": return .fn
        case "caps", "capslock", "⇪": return .capsLock

        default: return nil
        }
    }

    /// Maps a `flagsChanged` key code to the physical modifier it represents.
    ///
    /// This is what makes `lcmd` and `rcmd` distinguishable: `CGEventFlags` only says that
    /// *some* Command key is down, while the event's key code says which one changed.
    public static func forKeyCode(_ code: UInt16) -> Modifier? {
        switch code {
        case 55: return .leftCommand
        case 54: return .rightCommand
        case 56: return .leftShift
        case 60: return .rightShift
        case 58: return .leftOption
        case 61: return .rightOption
        case 59: return .leftControl
        case 62: return .rightControl
        case 63: return .fn
        default: return nil
        }
    }

    /// Side-agnostic families held according to event flags. Prefer `HeldModifiers` when the
    /// event stream is available, since it preserves sides.
    public static func families(from flags: CGEventFlags) -> Set<Modifier> {
        var result: Set<Modifier> = []
        for modifier in [Modifier.command, .option, .control, .shift, .fn]
        where flags.contains(modifier.cgFlag) {
            result.insert(modifier)
        }
        return result
    }
}
