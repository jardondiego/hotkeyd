import CoreGraphics

/// Tracks which physical modifier keys are currently held, including left/right.
///
/// `flagsChanged` carries two pieces of information: the key code of the modifier that changed,
/// and the flags after the change. Toggling on key-code membership handles the awkward case of
/// both sides being held (release left while right is still down leaves the Command flag set).
public struct HeldModifiers: Equatable, Sendable {
    public private(set) var keys: Set<Modifier>

    public init(_ keys: Set<Modifier> = []) {
        self.keys = keys
    }

    public var isEmpty: Bool { keys.isEmpty }

    public mutating func reset() {
        keys.removeAll()
    }

    public mutating func setCapsLock(_ down: Bool) {
        if down {
            keys.insert(.capsLock)
        } else {
            keys.remove(.capsLock)
        }
    }

    public mutating func update(keyCode: UInt16, flags: CGEventFlags, physicalFnDown: Bool? = nil) {
        if let modifier = Modifier.forKeyCode(keyCode) {
            if modifier == .fn {
                // Fn has no left/right pair, so `.maskSecondaryFn` directly tells us whether it is
                // down instead of toggling (which can invert if a flagsChanged event was dropped).
                if flags.contains(.maskSecondaryFn) {
                    keys.insert(.fn)
                } else {
                    keys.remove(.fn)
                }
            } else if keys.contains(modifier) {
                keys.remove(modifier)
            } else if flags.contains(modifier.cgFlag) {
                keys.insert(modifier)
            }
        }
        reconcile(with: flags, physicalFnDown: physicalFnDown)
    }

    /// Reconciles tracked modifier state against the authoritative `CGEventFlags` bitmask on any
    /// incoming event, clearing phantom stuck modifiers whose release `.flagsChanged` event was
    /// withheld during macOS Secure Event Input.
    ///
    /// When `physicalFnDown` is provided (from `CGEventSource.keyState(.hidSystemState, key: 63)`),
    /// a physically held Fn key survives synthetic CGEvents whose flags omit `.maskSecondaryFn`.
    public mutating func reconcile(
        with flags: CGEventFlags,
        physicalFnDown: Bool? = nil
    ) {
        keys = keys.filter { modifier in
            if modifier == .fn {
                return flags.contains(.maskSecondaryFn) || (physicalFnDown == true)
            }
            let flag = modifier.cgFlag
            return flag.isEmpty || flags.contains(flag)
        }
        if physicalFnDown == true {
            keys.insert(.fn)
        }

        let raw = flags.rawValue
        reconcileDeviceSides(
            rawFlags: raw,
            familyFlag: .maskCommand,
            flags: flags,
            leftMask: 0x0000_0008,
            rightMask: 0x0000_0010,
            leftModifier: .leftCommand,
            rightModifier: .rightCommand
        )
        reconcileDeviceSides(
            rawFlags: raw,
            familyFlag: .maskShift,
            flags: flags,
            leftMask: 0x0000_0002,
            rightMask: 0x0000_0004,
            leftModifier: .leftShift,
            rightModifier: .rightShift
        )
        reconcileDeviceSides(
            rawFlags: raw,
            familyFlag: .maskAlternate,
            flags: flags,
            leftMask: 0x0000_0020,
            rightMask: 0x0000_0040,
            leftModifier: .leftOption,
            rightModifier: .rightOption
        )
        reconcileDeviceSides(
            rawFlags: raw,
            familyFlag: .maskControl,
            flags: flags,
            leftMask: 0x0000_0001,
            rightMask: 0x0000_2000,
            leftModifier: .leftControl,
            rightModifier: .rightControl
        )
    }

    private mutating func reconcileDeviceSides(
        rawFlags: UInt64,
        familyFlag: CGEventFlags,
        flags: CGEventFlags,
        leftMask: UInt64,
        rightMask: UInt64,
        leftModifier: Modifier,
        rightModifier: Modifier
    ) {
        guard flags.contains(familyFlag) else { return }
        let deviceBits = rawFlags & (leftMask | rightMask)
        guard deviceBits != 0 else { return }

        if (deviceBits & leftMask) != 0 {
            keys.insert(leftModifier)
        } else {
            keys.remove(leftModifier)
        }
        if (deviceBits & rightMask) != 0 {
            keys.insert(rightModifier)
        } else {
            keys.remove(rightModifier)
        }
    }

    /// The same modifiers with sides collapsed, for matching side-agnostic combos.
    public var familySet: Set<Modifier> {
        Set(keys.map(\.familyOnly))
    }

    /// Exact match: the held modifier families must equal the required families, and any
    /// side-specific requirement must be the only side held for that family.
    public func matches(_ requirement: Set<Modifier>) -> Bool {
        guard Set(keys.map(\.family)) == Set(requirement.map(\.family)) else {
            return false
        }
        for modifier in requirement {
            let sameFamily = keys.filter { $0.family == modifier.family }
            if let side = modifier.side {
                guard sameFamily == [Modifier(modifier.family, side)] else { return false }
            } else if sameFamily.isEmpty {
                return false
            }
        }
        return true
    }
}
