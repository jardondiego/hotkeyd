import Foundation

/// The runtime lookup table for enabled shortcuts.
///
/// Two precedence rules make side-specific bindings useful without forcing every binding to
/// choose a side:
///
/// * a gesture bound to `lcmd` wins over one bound to `cmd` for the left key;
/// * a key combo bound to `lcmd+shift+c` wins over `cmd+shift+c` when the left Command is held;
/// * a sequence bound to `rctrl > q` wins over `ctrl > q` when right Control was tapped.
///
/// The side-agnostic binding remains the fallback for the other side.
public struct BindingIndex: Sendable {
    public private(set) var gestures: [Modifier: Shortcut] = [:]
    public private(set) var combos: [KeyCombo: Shortcut] = [:]
    public private(set) var doubleTapCombos: [KeyCombo: Shortcut] = [:]
    public private(set) var sequences: [KeySequence: Shortcut] = [:]
    private var combosByKeyCode: [UInt16: [(combo: KeyCombo, shortcut: Shortcut)]] = [:]
    private var doubleTapCombosByKeyCode: [UInt16: [(combo: KeyCombo, shortcut: Shortcut)]] = [:]

    public init(shortcuts: [Shortcut] = []) {
        for shortcut in shortcuts where shortcut.enabled {
            switch shortcut.keys {
            case .modifier(let modifier):
                guard shortcut.doubleTap != nil else { continue }
                var slice = shortcut
                slice.tap = nil
                gestures[modifier] = slice

            case .combo(let combo):
                if shortcut.tap != nil {
                    var slice = shortcut
                    slice.doubleTap = nil
                    combos[combo] = slice
                    combosByKeyCode[combo.keyCode, default: []].append((combo, slice))
                }
                if shortcut.doubleTap != nil {
                    var slice = shortcut
                    slice.tap = nil
                    doubleTapCombos[combo] = slice
                    doubleTapCombosByKeyCode[combo.keyCode, default: []].append((combo, slice))
                }

            case .sequence(let sequence):
                guard shortcut.tap != nil else { continue }
                var slice = shortcut
                slice.doubleTap = nil
                sequences[sequence] = slice
            }
        }
        for keyCode in combosByKeyCode.keys {
            combosByKeyCode[keyCode]?.sort { lhs, rhs in
                if lhs.combo.sideSpecificity != rhs.combo.sideSpecificity {
                    return lhs.combo.sideSpecificity > rhs.combo.sideSpecificity
                }
                return lhs.combo.canonical < rhs.combo.canonical
            }
        }
        for keyCode in doubleTapCombosByKeyCode.keys {
            doubleTapCombosByKeyCode[keyCode]?.sort { lhs, rhs in
                if lhs.combo.sideSpecificity != rhs.combo.sideSpecificity {
                    return lhs.combo.sideSpecificity > rhs.combo.sideSpecificity
                }
                return lhs.combo.canonical < rhs.combo.canonical
            }
        }
    }

    public var count: Int { gestures.count + combos.count + doubleTapCombos.count + sequences.count }

    public func shortcut(forGesture modifier: Modifier) -> Shortcut? {
        gestures[modifier] ?? gestures[modifier.familyOnly]
    }

    public func shortcut(keyCode: UInt16, held: HeldModifiers) -> Shortcut? {
        guard let candidates = combosByKeyCode[keyCode] else { return nil }
        return candidates.first(where: { $0.combo.matches(keyCode: keyCode, held: held) })?.shortcut
    }

    /// A double-tap binding for a held key, using the same side-specificity precedence as combos.
    public func doubleTapShortcut(keyCode: UInt16, held: HeldModifiers) -> Shortcut? {
        guard let candidates = doubleTapCombosByKeyCode[keyCode] else { return nil }
        return candidates.first(where: { $0.combo.matches(keyCode: keyCode, held: held) })?.shortcut
    }

    /// A two-step sequence binding for an armed modifier leader + step-2 key code, preferring
    /// side-specific leaders over side-agnostic family leaders.
    public func sequenceShortcut(leader: Modifier, keyCode: UInt16) -> Shortcut? {
        sequences[KeySequence(leader: leader, keyCode: keyCode)]
            ?? sequences[KeySequence(leader: leader.familyOnly, keyCode: keyCode)]
    }
}
