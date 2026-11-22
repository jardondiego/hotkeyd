import Foundation

/// Detects "tap this modifier twice, quickly" without ever consuming modifier events.
///
/// The gesture is recognised on the **second release**, not the second press. Firing on press
/// would turn a fast `cmd, cmd+K` into a launcher; firing on release means the second press must
/// be a complete, clean tap, and any key or mouse event in between disqualifies it.
///
/// The detector is pure: it takes timestamps and returns at most one fired modifier, so the whole
/// state machine is unit-testable without touching the event tap or Accessibility permissions.
public struct DoubleTapDetector: Sendable {
    public struct Timing: Sendable, Equatable {
        /// A modifier held longer than this is a hold, not a tap.
        public var tapMax: Double
        /// Default maximum gap between the first release and the second press.
        ///
        /// 400 ms matches the macOS double-click feel; 300 ms proved too tight in practice.
        public var window: Double
        /// After firing, ignore the same modifier for this long (a triple-tap fires once).
        public var cooldown: Double

        public init(tapMax: Double = 0.25, window: Double = 0.40, cooldown: Double = 0.40) {
            self.tapMax = tapMax
            self.window = window
            self.cooldown = cooldown
        }
    }

    public enum Event: Sendable, Equatable {
        /// The set of modifiers currently held, after a flags change.
        case modifiers(Set<Modifier>, at: Double)
        /// Any non-modifier key went down or up.
        case key(code: UInt16, at: Double)
        /// Any mouse button or scroll wheel activity.
        case mouse(at: Double)
    }

    private enum Phase: Equatable {
        case idle
        case pressed(Modifier, since: Double)
        case tapped(Modifier, releasedAt: Double)
        case secondPress(Modifier, since: Double)
    }

    public var timing: Timing
    /// Per-modifier delay overrides, so a shortcut's `maxDoubleTapDelayMs` can tighten or loosen the gap.
    public var windowOverrides: [Modifier: Double]

    private var phase: Phase = .idle
    private var lastFired: [Modifier: Double] = [:]
    /// Set while a chord (two or more modifiers) is held. Releasing a chord one key at a time
    /// must never look like a tap of the last remaining modifier.
    private var chordLatched = false

    public init(timing: Timing = Timing(), windowOverrides: [Modifier: Double] = [:]) {
        self.timing = timing
        self.windowOverrides = windowOverrides
    }

    /// Feeds one input event to the machine. Returns the modifier to fire, if any.
    @discardableResult
    public mutating func handle(_ event: Event) -> Modifier? {
        switch event {
        case .modifiers(let held, let now):
            return handleModifiers(held, at: now)
        case .key(let code, _):
            // The fn/Globe key emits a synthetic keyDown/keyUp of keyCode 179 after every tap.
            // It is part of the modifier gesture, not a real intervening key.
            guard !Self.isModifierArtifact(code) else { return nil }
            phase = .idle
            return nil
        case .mouse:
            phase = .idle
            return nil
        }
    }

    /// Key codes macOS emits as part of a modifier press rather than as a distinct keystroke.
    ///
    /// The physical fn key is the important one: after each press it sends a Globe key event
    /// (keyCode 179), and counting that as "the user typed something" would make double-tap:fn
    /// impossible.
    public static func isModifierArtifact(_ keyCode: UInt16) -> Bool {
        Modifier.forKeyCode(keyCode) != nil || keyCode == 179
    }

    public mutating func reset() {
        phase = .idle
        lastFired.removeAll()
        chordLatched = false
    }

    private mutating func handleModifiers(_ held: Set<Modifier>, at now: Double) -> Modifier? {
        if chordLatched {
            if held.isEmpty { chordLatched = false }
            return nil
        }
        if held.count > 1 {
            chordLatched = true
            phase = .idle
            return nil
        }

        switch phase {
        case .idle:
            beginIfSingle(held, at: now)
            return nil

        case .pressed(let mod, let since):
            if held == [mod] { return nil }
            if held.isEmpty {
                phase = (now - since <= timing.tapMax) ? .tapped(mod, releasedAt: now) : .idle
                return nil
            }
            // A second modifier joined: this was a chord, not a tap.
            phase = .idle
            beginIfSingle(held, at: now)
            return nil

        case .tapped(let mod, let releasedAt):
            let window = windowOverrides[mod] ?? windowOverrides[mod.familyOnly] ?? timing.window
            if now - releasedAt > window {
                phase = .idle
                beginIfSingle(held, at: now)
                return nil
            }
            if held == [mod] {
                phase = .secondPress(mod, since: now)
            } else if !held.isEmpty {
                phase = .idle
                beginIfSingle(held, at: now)
            }
            return nil

        case .secondPress(let mod, let since):
            if held == [mod] { return nil }
            guard held.isEmpty else {
                phase = .idle
                beginIfSingle(held, at: now)
                return nil
            }
            let wasTap = now - since <= timing.tapMax
            let cooled = lastFired[mod].map { now - $0 >= timing.cooldown } ?? true
            phase = .idle
            guard wasTap, cooled else { return nil }
            lastFired[mod] = now
            return mod
        }
    }

    private mutating func beginIfSingle(_ held: Set<Modifier>, at now: Double) {
        if held.count == 1, let mod = held.first {
            phase = .pressed(mod, since: now)
        }
    }
}
