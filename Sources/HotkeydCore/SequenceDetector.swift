import Foundation

/// Detects two-step `<modifier> > <key>` sequences without ever consuming modifier events.
///
/// Step 1 is a clean, single-modifier tap lasting at most `tapMax` seconds (250 ms by default).
/// Releasing that modifier arms it as the sequence leader for `defaultMaxDelay` seconds (250 ms
/// by default, overridden per shortcut by `maxSequenceDelayMs`). Any non-artifact key press,
/// mouse activity, multi-modifier chord, or firing bare-modifier `doubleTap` disarms the leader
/// immediately; unbound step-2 keys pass through untouched.
public struct SequenceDetector: Sendable {
    public struct Candidate: Sendable, Equatable {
        public let leader: Modifier
        public let elapsed: Double

        public init(leader: Modifier, elapsed: Double) {
            self.leader = leader
            self.elapsed = elapsed
        }
    }

    /// A modifier press longer than this is a hold, not a tap.
    public var tapMax: Double
    /// Default maximum gap between releasing step 1 and pressing step 2.
    public var defaultMaxDelay: Double

    private var pressing: (modifier: Modifier, since: Double)?
    private var armed: (modifier: Modifier, releasedAt: Double)?
    private var chordLatched = false

    public init(tapMax: Double = 0.25, defaultMaxDelay: Double = 0.25) {
        self.tapMax = tapMax
        self.defaultMaxDelay = defaultMaxDelay
    }

    public var armedLeader: Modifier? {
        armed?.modifier
    }

    /// Feeds the current set of held modifiers after a `.flagsChanged` or F18 Caps Lock event.
    public mutating func onModifiers(_ held: Set<Modifier>, at now: Double, doubleTapFired: Bool) {
        if doubleTapFired {
            pressing = nil
            armed = nil
            return
        }
        if chordLatched {
            if held.isEmpty { chordLatched = false }
            pressing = nil
            armed = nil
            return
        }
        if held.count > 1 {
            chordLatched = true
            pressing = nil
            armed = nil
            return
        }
        if held.count == 1, let mod = held.first {
            if pressing?.modifier != mod {
                // Disarm any previous leader as soon as a new modifier press starts so pressing a
                // key while holding another modifier cannot accidentally match a prior leader.
                armed = nil
                pressing = (mod, now)
            }
            return
        }
        if let p = pressing {
            pressing = nil
            armed = (now - p.since <= tapMax) ? (p.modifier, now) : nil
        }
    }

    /// Consumes an armed leader on a non-artifact `.keyDown` and returns a candidate if step 2 is a
    /// fresh key press with zero modifiers held.
    public mutating func consumeKeyDown(
        keyCode: UInt16,
        held: HeldModifiers,
        isRepeat: Bool = false,
        at now: Double
    ) -> Candidate? {
        guard !DoubleTapDetector.isModifierArtifact(keyCode) else { return nil }
        pressing = nil
        guard let current = armed else { return nil }
        armed = nil
        guard !isRepeat, held.isEmpty else { return nil }
        return Candidate(leader: current.modifier, elapsed: max(0, now - current.releasedAt))
    }

    public mutating func onMouse() {
        pressing = nil
        armed = nil
    }

    public mutating func cancel() {
        pressing = nil
        armed = nil
    }

    public mutating func reset() {
        pressing = nil
        armed = nil
        chordLatched = false
    }
}
