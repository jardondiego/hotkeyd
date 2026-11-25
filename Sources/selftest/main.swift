import CoreGraphics
import Darwin
import Foundation
import HotkeydCore

// MARK: - Tiny harness
//
// CLT-only machines have no XCTest and no swift-testing module, so the suite is an executable.
// It exits non-zero on the first non-zero failure count, which is all CI or a human needs.

var checks = 0
var failures = 0

func expect(_ condition: Bool, _ label: String) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL  \(label)")
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    checks += 1
    if actual != expected {
        failures += 1
        print("FAIL  \(label)")
        print("      expected: \(expected)")
        print("      actual:   \(actual)")
    }
}

func expectThrows<T>(_ label: String, _ body: () throws -> T) {
    checks += 1
    do {
        _ = try body()
        failures += 1
        print("FAIL  \(label): expected an error")
    } catch {
    }
}

func expectNil<T>(_ value: T?, _ label: String) {
    expect(value == nil, label)
}

// MARK: - Detector helpers

func doubleTap(
    _ detector: inout DoubleTapDetector,
    _ modifier: Modifier,
    firstDown: Double = 0.00,
    firstUp: Double = 0.08,
    secondDown: Double = 0.20,
    secondUp: Double = 0.28
) -> Modifier? {
    detector.handle(.modifiers([modifier], at: firstDown))
    detector.handle(.modifiers([], at: firstUp))
    detector.handle(.modifiers([modifier], at: secondDown))
    return detector.handle(.modifiers([], at: secondUp))
}

// MARK: - Detector

func testDetector() {
    do {
        var detector = DoubleTapDetector()
        expectEqual(doubleTap(&detector, .command, secondUp: 0.27), .command,
                    "basic double-tap fires on the second release")
    }
    do {
        var detector = DoubleTapDetector()
        detector.handle(.modifiers([.command], at: 0.0))
        expectNil(detector.handle(.modifiers([], at: 0.08)), "one release is not enough")
    }
    do {
        var detector = DoubleTapDetector()
        detector.handle(.modifiers([.command], at: 0.00))
        detector.handle(.modifiers([], at: 0.08))
        detector.handle(.modifiers([.command], at: 0.50))
        expectNil(detector.handle(.modifiers([], at: 0.58)), "gap longer than window does not fire")
    }
    do {
        var detector = DoubleTapDetector()
        detector.handle(.modifiers([.command], at: 0.00))
        detector.handle(.modifiers([], at: 0.40))
        detector.handle(.modifiers([.command], at: 0.45))
        expectNil(detector.handle(.modifiers([], at: 0.50)), "a hold is not a tap")
    }
    do {
        var detector = DoubleTapDetector()
        detector.handle(.modifiers([.command], at: 0.00))
        detector.handle(.modifiers([], at: 0.08))
        detector.handle(.key(code: 49, at: 0.10))
        detector.handle(.modifiers([.command], at: 0.15))
        expectNil(detector.handle(.modifiers([], at: 0.22)), "a key between taps cancels")
    }
    do {
        var detector = DoubleTapDetector()
        detector.handle(.modifiers([.fn], at: 0.00))
        detector.handle(.modifiers([], at: 0.08))
        detector.handle(.key(code: 179, at: 0.09)) // Globe key emitted by the fn key itself
        detector.handle(.modifiers([.fn], at: 0.20))
        expectEqual(detector.handle(.modifiers([], at: 0.26)), .fn,
                    "the Globe key artifact does not cancel double-tap fn")
    }
    expectTrue(DoubleTapDetector.isModifierArtifact(179), "Globe key is a modifier artifact")
    expectTrue(DoubleTapDetector.isModifierArtifact(63), "fn key code is a modifier artifact")
    expect(!DoubleTapDetector.isModifierArtifact(49), "space is a real key")
    do {
        var detector = DoubleTapDetector()
        detector.handle(.modifiers([.command], at: 0.00))
        detector.handle(.modifiers([], at: 0.08))
        detector.handle(.modifiers([.command], at: 0.15))
        detector.handle(.key(code: 40, at: 0.18)) // the K in `cmd, cmd+K`
        expectNil(detector.handle(.modifiers([], at: 0.22)),
                  "a key during the second press cancels (cmd, cmd+K)")
    }
    do {
        var detector = DoubleTapDetector()
        detector.handle(.modifiers([.command], at: 0.00))
        detector.handle(.modifiers([], at: 0.08))
        detector.handle(.mouse(at: 0.12))
        detector.handle(.modifiers([.command], at: 0.18))
        expectNil(detector.handle(.modifiers([], at: 0.24)), "mouse activity cancels")
    }
    do {
        var detector = DoubleTapDetector()
        detector.handle(.modifiers([.command, .shift], at: 0.00))
        detector.handle(.modifiers([], at: 0.08))
        detector.handle(.modifiers([.command], at: 0.20))
        expectNil(detector.handle(.modifiers([], at: 0.28)), "a chord is ignored")
    }
    do {
        var detector = DoubleTapDetector()
        detector.handle(.modifiers([.command, .shift], at: 0.00))
        detector.handle(.modifiers([.shift], at: 0.05))
        detector.handle(.modifiers([], at: 0.10))
        detector.handle(.modifiers([.shift], at: 0.15))
        expectNil(detector.handle(.modifiers([], at: 0.20)),
                  "releasing a chord key by key does not arm a gesture")
    }
    do {
        var detector = DoubleTapDetector()
        detector.handle(.modifiers([.command], at: 0.00))
        detector.handle(.modifiers([], at: 0.08))
        detector.handle(.modifiers([.command], at: 0.15))
        detector.handle(.modifiers([.command, .option], at: 0.17))
        detector.handle(.modifiers([], at: 0.20))
        expectNil(detector.handle(.modifiers([], at: 0.24)),
                  "an extra modifier during the second press cancels")
    }
    do {
        var detector = DoubleTapDetector()
        expectEqual(doubleTap(&detector, .command, secondUp: 0.23), .command,
                    "triple-tap: first gesture fires")
        detector.handle(.modifiers([.command], at: 0.30))
        detector.handle(.modifiers([], at: 0.38))
        detector.handle(.modifiers([.command], at: 0.45))
        expectNil(detector.handle(.modifiers([], at: 0.53)), "triple-tap fires only once")
    }
    do {
        var detector = DoubleTapDetector()
        expectEqual(doubleTap(&detector, .command, secondUp: 0.23), .command,
                    "cooldown: first gesture fires")
        expectEqual(
            doubleTap(&detector, .command, firstDown: 0.80, firstUp: 0.88,
                      secondDown: 1.00, secondUp: 1.08),
            .command,
            "cooldown: a later gesture is accepted"
        )
    }
    do {
        var detector = DoubleTapDetector()
        expectEqual(doubleTap(&detector, .command, secondUp: 0.23), .command,
                    "independent modifiers: command fires")
        expectEqual(
            doubleTap(&detector, .option, firstDown: 0.30, firstUp: 0.38,
                      secondDown: 0.50, secondUp: 0.58),
            .option,
            "independent modifiers: option fires"
        )
    }
    do {
        var detector = DoubleTapDetector(windowOverrides: [.command: 0.10])
        detector.handle(.modifiers([.command], at: 0.00))
        detector.handle(.modifiers([], at: 0.05))
        detector.handle(.modifiers([.command], at: 0.20))
        expectNil(detector.handle(.modifiers([], at: 0.25)),
                  "per-modifier window override is honoured")
    }
    do {
        // A window override set on the side-agnostic `cmd` binding must also cover lcmd/rcmd.
        var detector = DoubleTapDetector(windowOverrides: [.command: 0.10])
        detector.handle(.modifiers([.leftCommand], at: 0.00))
        detector.handle(.modifiers([], at: 0.05))
        detector.handle(.modifiers([.leftCommand], at: 0.20))
        expectNil(detector.handle(.modifiers([], at: 0.25)),
                  "family window override applies to a side-specific tap")
    }
    do {
        var detector = DoubleTapDetector()
        detector.handle(.modifiers([.command], at: 0.00))
        detector.handle(.modifiers([], at: 0.08))
        detector.reset()
        detector.handle(.modifiers([.command], at: 0.20))
        expectNil(detector.handle(.modifiers([], at: 0.28)), "reset clears state")
    }
}

// MARK: - Modifiers

func testModifiers() {
    expectEqual(Modifier.parse("cmd"), .command, "alias cmd")
    expectEqual(Modifier.parse("⌘"), .command, "alias ⌘")
    expectEqual(Modifier.parse("Command"), .command, "alias is case-insensitive")
    expectEqual(Modifier.parse("alt"), .option, "alias alt")
    expectEqual(Modifier.parse("ctl"), .control, "alias ctl")
    expectEqual(Modifier.parse("⇧"), .shift, "alias ⇧")
    expectEqual(Modifier.parse("function"), .fn, "alias function")
    expectNil(Modifier.parse("hyper"), "unknown modifier is rejected")

    expectEqual(Modifier.families(from: .maskCommand), [.command], "families: command")
    expectEqual(Modifier.families(from: [.maskCommand, .maskAlternate]), [.command, .option],
                "families: command+option")
    expectEqual(Modifier.families(from: .maskSecondaryFn), [.fn], "families: fn")
    expectTrue(Modifier.families(from: .maskAlphaShift).isEmpty,
               "families: Caps Lock is excluded")
}

// MARK: - Config

func sampleConfig() -> Config {
    Config(shortcuts: [
        Shortcut(
            id: "abc123",
            name: "launcher",
            trigger: .doubleTap(modifier: .command, windowMilliseconds: 300),
            action: .shell(command: "open -a Terminal", cwd: nil, timeoutMilliseconds: nil)
        ),
        Shortcut(
            id: "def456",
            name: "screenshot",
            trigger: .doubleTap(modifier: .option, windowMilliseconds: nil),
            action: .shell(command: "screencapture -i ~/Desktop/shot.png", cwd: "~",
                           timeoutMilliseconds: 5000)
        )
    ])
}

func testConfig() {
    do {
        let config = sampleConfig()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(config)
        let decoded = try JSONDecoder().decode(Config.self, from: data)
        expectEqual(decoded, config, "config encodes and decodes without loss")
    } catch {
        expect(false, "config round trip threw: \(error)")
    }

    do {
        let json = """
        {
          "version": 1,
          "shortcuts": [
            {
              "id": "01J9Z6K3Q8",
              "name": "launcher",
              "enabled": true,
              "trigger": { "type": "doubleTap", "modifier": "cmd", "windowMs": 300 },
              "action": { "type": "shell", "command": "open -a Terminal" }
            }
          ]
        }
        """
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        expectEqual(config.shortcuts.count, 1, "documented shape decodes")
        expectEqual(config.shortcuts[0].trigger.modifier, .command, "documented modifier decodes")
        expectEqual(config.shortcuts[0].trigger.display, "doubleTap:cmd",
                    "canonical display form")
        expectEqual(config.shortcuts[0].trigger.windowSeconds, 0.3, "window converts to seconds")
    } catch {
        expect(false, "documented shape threw: \(error)")
    }

    expectThrows("unknown modifier is rejected") {
        let json = """
        {"version":1,"shortcuts":[{"id":"x","name":"n","enabled":true,
         "trigger":{"type":"doubleTap","modifier":"hyper"},
         "action":{"type":"shell","command":"true"}}]}
        """
        return try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    }

    expectThrows("unknown action type is rejected") {
        let json = """
        {"version":1,"shortcuts":[{"id":"x","name":"n","enabled":true,
         "trigger":{"type":"doubleTap","modifier":"cmd"},
         "action":{"type":"launchApp","bundleID":"com.apple.Terminal"}}]}
        """
        return try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    }

    expectThrows("duplicate names are rejected") {
        var config = sampleConfig()
        config.shortcuts.append(
            Shortcut(
                id: "ghi789",
                name: "LAUNCHER",
                trigger: .doubleTap(modifier: .control, windowMilliseconds: nil),
                action: .shell(command: "true", cwd: nil, timeoutMilliseconds: nil)
            )
        )
        try config.validate()
    }

    expectThrows("duplicate enabled triggers are rejected") {
        var config = sampleConfig()
        config.shortcuts.append(
            Shortcut(
                id: "ghi789",
                name: "second command",
                trigger: .doubleTap(modifier: .command, windowMilliseconds: nil),
                action: .shell(command: "true", cwd: nil, timeoutMilliseconds: nil)
            )
        )
        try config.validate()
    }

    do {
        var config = sampleConfig()
        config.shortcuts.append(
            Shortcut(
                id: "ghi789",
                name: "second command",
                enabled: false,
                trigger: .doubleTap(modifier: .command, windowMilliseconds: nil),
                action: .shell(command: "true", cwd: nil, timeoutMilliseconds: nil)
            )
        )
        try config.validate()
        expect(true, "a disabled duplicate trigger is allowed")
    } catch {
        expect(false, "disabled duplicate trigger should be allowed: \(error)")
    }

    expectThrows("empty shell command is rejected") {
        let config = Config(shortcuts: [
            Shortcut(
                id: "x",
                name: "empty",
                trigger: .doubleTap(modifier: .command, windowMilliseconds: nil),
                action: .shell(command: "   ", cwd: nil, timeoutMilliseconds: nil)
            )
        ])
        try config.validate()
    }

    expectThrows("out-of-range window is rejected") {
        let config = Config(shortcuts: [
            Shortcut(
                id: "x",
                name: "narrow",
                trigger: .doubleTap(modifier: .command, windowMilliseconds: 50),
                action: .shell(command: "true", cwd: nil, timeoutMilliseconds: nil)
            )
        ])
        try config.validate()
    }

    do {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hotkeyd-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(".hotkeyd")
        let config = sampleConfig()
        try config.save(to: url)
        let loaded = try Config.load(from: url)
        expectEqual(loaded, config, "config round trips through disk")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = attributes[.posixPermissions] as? NSNumber
        expectEqual(permissions?.intValue, 0o600, "config file is 0600")
    } catch {
        expect(false, "disk round trip threw: \(error)")
    }

    expectThrows("missing config is reported") {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hotkeyd-missing-\(UUID().uuidString).json")
        return try Config.load(from: url)
    }
}

func expectTrue(_ condition: Bool, _ label: String) {
    expect(condition, label)
}

// MARK: - Key combos

func testKeyCombos() {
    do {
        let combo = try KeyCombo.parse("cmd+shift+c")
        expectEqual(combo.canonical, "cmd+shift+c", "canonical modifier order and lowercase key")
        expectEqual(combo.modifiers, [.command, .shift], "modifiers parsed")
        expectEqual(combo.keyName, "c", "key name")
    } catch {
        expect(false, "cmd+shift+c failed to parse: \(error)")
    }

    do {
        let a = try KeyCombo.parse("Shift+Cmd+C")
        let b = try KeyCombo.parse("cmd+shift+c")
        expectEqual(a, b, "parse is order-insensitive and case-insensitive")
    } catch {
        expect(false, "order-insensitive parse threw: \(error)")
    }

    do {
        expectEqual(try KeyCombo.parse("F13").canonical, "f13", "bare f13 is allowed")
        expectEqual(try KeyCombo.parse("fn+F1").canonical, "fn+f1", "fn composes with f keys")
        expectEqual(try KeyCombo.parse("cmd+forwardDelete").canonical, "cmd+forwarddelete", "forwarddelete canonicalizes lowercase")
    } catch {
        expect(false, "function-key parse threw: \(error)")
    }

    expectThrows("bare letter is rejected") { try KeyCombo.parse("c") }
    expectThrows("modifier-only is rejected") { try KeyCombo.parse("cmd") }
    expectThrows("unknown key is rejected") { try KeyCombo.parse("cmd+nope") }
    expectThrows("cmd+q is reserved") { try KeyCombo.parse("cmd+q") }
    expectThrows("cmd+space is reserved") { try KeyCombo.parse("cmd+space") }
    do {
        expectEqual(try KeyCombo.parse("rcmd+space").canonical, "rcmd+space", "rcmd+space is allowed (left cmd keeps Spotlight)")
        expectEqual(try KeyCombo.parse("lcmd+space").canonical, "lcmd+space", "lcmd+space is allowed (right cmd keeps Spotlight)")
    } catch {
        expect(false, "sided cmd+space parse threw: \(error)")
    }
    expectThrows("rcmd+q is still reserved") { try KeyCombo.parse("rcmd+q") }
    expectThrows("rcmd+tab is still reserved") { try KeyCombo.parse("rcmd+tab") }
    expectThrows("ctrl+f3 is reserved") { try KeyCombo.parse("ctrl+F3") }
    expectThrows("ctrl+cmd+q (Lock Screen) is reserved") { try KeyCombo.parse("ctrl+cmd+q") }
    expectThrows("lctrl+rcmd+q (sided Lock Screen) is reserved") { try KeyCombo.parse("lctrl+rcmd+q") }
    expectThrows("cmd+shift+q (Log Out) is reserved") { try KeyCombo.parse("cmd+shift+q") }
    expectThrows("cmd+shift+opt+q (Log Out) is reserved") { try KeyCombo.parse("cmd+shift+opt+q") }
    expectThrows("shift+a is rejected (shift-only printable key)") { try KeyCombo.parse("shift+a") }
    expectThrows("lshift+space is rejected (shift-only printable key)") { try KeyCombo.parse("lshift+space") }

    do {
        expectEqual(try KeyCombo.parse("caps+space").canonical, "capsLock+space", "capsLock joins key combos")
        expectEqual(try KeyCombo.parse("lcmd+capsLock+m").canonical, "lcmd+capsLock+m", "capsLock composes with other modifiers")
    } catch {
        expect(false, "capsLock combo parse threw: \(error)")
    }

    do {
        expectEqual(try KeyCombo.parse("shift+f5").canonical, "shift+f5", "shift+f5 is allowed")
        expectEqual(try KeyCombo.parse("cmd+shift+a").canonical, "cmd+shift+a", "cmd+shift+a is allowed")
    } catch {
        expect(false, "shift+f5 / cmd+shift+a parse threw: \(error)")
    }

    do {
        expectEqual(try KeyCombo.parse("cmd+shift+;").canonical, "cmd+shift+semicolon",
                    "punctuation alias renders canonically")
        expectEqual(try KeyCombo.parse("cmd+,").canonical, "cmd+comma",
                    "single-character punctuation alias")
    } catch {
        expect(false, "punctuation parse threw: \(error)")
    }

    do {
        let chrome = try KeyCombo.parse("cmd+shift+c")
        expect(chrome.matches(keyCode: 8, held: HeldModifiers([.command, .shift])),
               "matches exact key and modifiers")
        expect(!chrome.matches(keyCode: 8, held: HeldModifiers([.command])),
               "does not match when a modifier is missing")
        expect(!chrome.matches(keyCode: 9, held: HeldModifiers([.command, .shift])),
               "does not match another key")
    } catch {
        expect(false, "matching setup threw: \(error)")
    }
}

// MARK: - Caps Lock

func testCapsLock() {
    expectEqual(Modifier.parse("caps"), .capsLock, "caps alias")
    expectEqual(Modifier.parse("capsLock"), .capsLock, "capsLock alias")
    expectEqual(Modifier.parse("⇪"), .capsLock, "caps glyph")
    expect(Modifier.families(from: .maskAlphaShift).isEmpty, "caps flag never arms a gesture")

    let payload = CapsLock.payload
    expect(payload.contains("30064771129"), "payload contains caps usage (0x700000039)")
    expect(payload.contains("30064771181"), "payload contains F18 usage (0x70000006D)")
    expectEqual(CapsLock.targetKeyCode, 79, "F18 virtual key code")

    var detector = DoubleTapDetector()
    expectEqual(doubleTap(&detector, .capsLock, secondUp: 0.27), .capsLock,
                "the detector treats capsLock like any other modifier")

    switch CapsLock.readCapsLockState() {
    case .success:
        expect(true, "CapsLock.readCapsLockState() succeeds in pure Swift via IOKit")
    case .failure(let kr):
        expect(false, "CapsLock.readCapsLockState() failed with kern_return_t \(kr)")
    }

    expectEqual(
        CapsLock.parseMappingOutput("(null)"),
        .off,
        "parseMappingOutput treats (null) as off"
    )
    expectEqual(
        CapsLock.parseMappingOutput("(\n    {\n        HIDKeyboardModifierMappingDst = \"0x70000006D\";\n        HIDKeyboardModifierMappingSrc = \"0x700000039\";\n    }\n)"),
        .enabled,
        "parseMappingOutput recognizes quoted hex CapsLock->F18 mapping"
    )
    expectEqual(
        CapsLock.parseMappingOutput("(\n    {\n        HIDKeyboardModifierMappingDst = 30064771129;\n        HIDKeyboardModifierMappingSrc = 30064771296;\n    }\n)"),
        .foreign("0x7000000e0 -> 0x700000039"),
        "parseMappingOutput detects foreign mapping"
    )
    if case .foreign = CapsLock.parseMappingOutput("unexpected garbage output") {
        expect(true, "parseMappingOutput fails closed to .foreign on unparseable output")
    } else {
        expect(false, "parseMappingOutput must fail closed to .foreign on unparseable output")
    }

    // Held Caps Lock combos (`capsLock+space`, `capsLock+m`)
    do {
        var held = HeldModifiers([.fn])
        held.setCapsLock(true)
        held.reconcile(with: [])
        expectEqual(held.keys, [.capsLock], "reconcile preserves .capsLock while clearing flag-backed modifiers")

        let capsSpace = try KeyCombo.parse("capsLock+space")
        expect(capsSpace.matches(keyCode: 49, held: held), "capsLock+space matches when capsLock is held")
        expect(!capsSpace.matches(keyCode: 49, held: HeldModifiers()), "capsLock+space does not match when capsLock is up")

        held.setCapsLock(false)
        expect(held.isEmpty, "setCapsLock(false) releases .capsLock")

        let comboConfig = Config(shortcuts: [
            Shortcut(keys: .combo(capsSpace), tap: "echo lens"),
            Shortcut(keys: .combo(try KeyCombo.parse("capsLock+m")), doubleTap: "echo meet"),
            Shortcut(keys: .modifier(.capsLock), doubleTap: "echo canary"),
            Shortcut(keys: .sequence(try KeySequence.parse("capsLock > o")), tap: "echo ocr")
        ])
        try comboConfig.validate()
        let idx = BindingIndex(shortcuts: comboConfig.shortcuts)
        expectEqual(idx.count, 4, "capsLock doubleTap, sequence, combo tap, and combo doubleTap all coexist")
        expectEqual(idx.shortcut(keyCode: 49, held: HeldModifiers([.capsLock]))?.tap, "echo lens", "capsLock+space lookup")
        expectEqual(idx.doubleTapShortcut(keyCode: 46, held: HeldModifiers([.capsLock]))?.doubleTap, "echo meet", "capsLock+m doubleTap lookup")
        expectEqual(idx.sequenceShortcut(leader: .capsLock, keyCode: 31)?.tap, "echo ocr", "capsLock > o sequence lookup")
        expectEqual(idx.shortcut(forGesture: .capsLock)?.doubleTap, "echo canary", "capsLock doubleTap lookup")

        expectThrows("f18 conflicts with enabled capsLock+space combo") {
            let bad = Config(shortcuts: [
                Shortcut(keys: .combo(capsSpace), tap: "true"),
                Shortcut(keys: .combo(try KeyCombo.parse("f18")), tap: "true")
            ])
            try bad.validate()
        }
        expectThrows("capsLock+f18 conflicts with itself") {
            let bad = Config(shortcuts: [
                Shortcut(keys: .combo(try KeyCombo.parse("capsLock+f18")), tap: "true")
            ])
            try bad.validate()
        }
    } catch {
        expect(false, "capsLock combo tests threw: \(error)")
    }
}

// MARK: - Side-specific modifiers

func testSideSpecificModifiers() {
    expectEqual(Modifier.parse("lcmd"), .leftCommand, "lcmd parses")
    expectEqual(Modifier.parse("rcmd"), .rightCommand, "rcmd parses")
    expectEqual(Modifier.parse("left command"), .leftCommand, "spaced alias parses")
    expectEqual(Modifier.parse("lopt"), .leftOption, "lopt parses")
    expectEqual(Modifier.parse("rshift"), .rightShift, "rshift parses")
    expectEqual(Modifier.leftCommand.token, "lcmd", "lcmd token")
    expectEqual(Modifier.command.token, "cmd", "family token")
    expectEqual(Modifier.forKeyCode(55), .leftCommand, "keycode 55 is left cmd")
    expectEqual(Modifier.forKeyCode(54), .rightCommand, "keycode 54 is right cmd")
    expectEqual(Modifier.forKeyCode(56), .leftShift, "keycode 56 is left shift")
    expectEqual(Modifier.forKeyCode(60), .rightShift, "keycode 60 is right shift")

    var held = HeldModifiers()
    held.update(keyCode: 55, flags: .maskCommand)
    expectEqual(held.keys, [.leftCommand], "held: left cmd down")
    held.update(keyCode: 54, flags: .maskCommand)
    expectEqual(held.keys, [.leftCommand, .rightCommand], "held: both cmd down")
    held.update(keyCode: 55, flags: .maskCommand)
    expectEqual(held.keys, [.rightCommand], "held: left release while right is held")
    held.update(keyCode: 54, flags: [])
    expect(held.isEmpty, "held: all released")

    // V-07: Secure Event Input phantom modifier reconciliation
    var stuckHeld = HeldModifiers()
    stuckHeld.update(keyCode: 55, flags: .maskCommand)
    expectEqual(stuckHeld.keys, [.leftCommand], "stuckHeld initially holds lcmd")
    // Release flagsChanged was withheld during Secure Event Input; next plain keyDown has flags == []
    stuckHeld.reconcile(with: [])
    expect(stuckHeld.isEmpty, "reconcile(with: []) clears phantom stuck lcmd after Secure Event Input")

    // Device-dependent side reconciliation (NX_DEVICELCMDKEYMASK = 0x08, NX_DEVICERCMDKEYMASK = 0x10)
    var sideHeld = HeldModifiers([.leftCommand])
    let rightCmdDeviceFlags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x0000_0010)
    sideHeld.reconcile(with: rightCmdDeviceFlags)
    expectEqual(
        sideHeld.keys,
        [.rightCommand],
        "reconcile(with:) replaces stale lcmd with rcmd when NX_DEVICERCMDKEYMASK is set"
    )

    let leftShiftCmd = HeldModifiers([.leftShift, .leftCommand])
    expect(leftShiftCmd.matches([.leftCommand, .leftShift]), "match: exact sides")
    expect(!leftShiftCmd.matches([.rightCommand, .leftShift]), "match: wrong side rejected")
    expect(leftShiftCmd.matches([.command, .shift]), "match: side-agnostic accepts either side")

    do {
        let combo = try KeyCombo.parse("lshift+lcmd+escape")
        expectEqual(combo.canonical, "lcmd+lshift+escape", "combo: side tokens canonical")
        expect(combo.matches(keyCode: 53, held: HeldModifiers([.leftCommand, .leftShift])),
               "combo: left chord matches")
        expect(!combo.matches(keyCode: 53, held: HeldModifiers([.rightCommand, .leftShift])),
               "combo: right chord does not match")
    } catch {
        expect(false, "side combo parse threw: \(error)")
    }

    let leftGesture = Shortcut(
        id: "a", name: "left",
        trigger: .doubleTap(modifier: .leftCommand, windowMilliseconds: nil),
        action: .shell(command: "true", cwd: nil, timeoutMilliseconds: nil)
    )
    let anyGesture = Shortcut(
        id: "b", name: "any",
        trigger: .doubleTap(modifier: .command, windowMilliseconds: nil),
        action: .shell(command: "true", cwd: nil, timeoutMilliseconds: nil)
    )
    let gestureIndex = BindingIndex(shortcuts: [leftGesture, anyGesture])
    expectEqual(gestureIndex.shortcut(forGesture: .leftCommand)?.name, "left",
                "index: exact side wins")
    expectEqual(gestureIndex.shortcut(forGesture: .rightCommand)?.name, "any",
                "index: family fallback")

    do {
        let sideShortcut = Shortcut(
            id: "c", name: "side",
            trigger: .keys(try KeyCombo.parse("lcmd+lshift+c")),
            action: .shell(command: "true", cwd: nil, timeoutMilliseconds: nil)
        )
        let mixedShortcut = Shortcut(
            id: "m", name: "mixed",
            trigger: .keys(try KeyCombo.parse("lcmd+shift+c")),
            action: .shell(command: "true", cwd: nil, timeoutMilliseconds: nil)
        )
        let familyShortcut = Shortcut(
            id: "d", name: "family",
            trigger: .keys(try KeyCombo.parse("cmd+shift+c")),
            action: .shell(command: "true", cwd: nil, timeoutMilliseconds: nil)
        )
        let comboIndex = BindingIndex(shortcuts: [familyShortcut, mixedShortcut, sideShortcut])
        expectEqual(
            comboIndex.shortcut(keyCode: 8, held: HeldModifiers([.leftCommand, .leftShift]))?.name,
            "side",
            "index: lcmd+lshift+C (specificity 2) wins over lcmd+shift+C and cmd+shift+C"
        )
        expectEqual(
            comboIndex.shortcut(keyCode: 8, held: HeldModifiers([.leftCommand, .rightShift]))?.name,
            "mixed",
            "index: mixed-side lcmd+shift+C (specificity 1) wins over cmd+shift+C when lcmd+rshift held"
        )
        expectEqual(
            comboIndex.shortcut(keyCode: 8, held: HeldModifiers([.rightCommand, .leftShift]))?.name,
            "family",
            "index: family combo handles the other side"
        )

        // V-08: Ambiguous partial-side ties rejected by Config.validate()
        let tieConfig = Config(shortcuts: [
            Shortcut(
                id: "t1", name: "left-cmd-any-opt",
                trigger: .keys(try KeyCombo.parse("lcmd+opt+c")),
                action: .shell(command: "true", cwd: nil, timeoutMilliseconds: nil)
            ),
            Shortcut(
                id: "t2", name: "any-cmd-left-opt",
                trigger: .keys(try KeyCombo.parse("cmd+lopt+c")),
                action: .shell(command: "true", cwd: nil, timeoutMilliseconds: nil)
            )
        ])
        expectThrows("Config.validate() rejects ambiguous partial-side ties (lcmd+opt+C vs cmd+lopt+C)") {
            try tieConfig.validate()
        }

        // V-08: Conflicting F18 + doubleTap:capsLock rejected by Config.validate()
        let f18ConflictConfig = Config(shortcuts: [
            Shortcut(
                id: "c1", name: "caps-gesture",
                trigger: .doubleTap(modifier: .capsLock, windowMilliseconds: nil),
                action: .shell(command: "true", cwd: nil, timeoutMilliseconds: nil)
            ),
            Shortcut(
                id: "c2", name: "f18-key",
                trigger: .keys(try KeyCombo.parse("F18")),
                action: .shell(command: "true", cwd: nil, timeoutMilliseconds: nil)
            )
        ])
        expectThrows("Config.validate() rejects binding F18 while doubleTap:capsLock is enabled") {
            try f18ConflictConfig.validate()
        }
    } catch {
        expect(false, "combo index setup threw: \(error)")
    }
}

// MARK: - Config with combos

func testComboConfig() {
    do {
        let trigger = Trigger.keys(try KeyCombo.parse("cmd+shift+c"))
        let encoded = try JSONEncoder().encode(trigger)
        let decoded = try JSONDecoder().decode(Trigger.self, from: encoded)
        expectEqual(decoded, trigger, "keys trigger round-trips")
        expectEqual(decoded.display, "cmd+shift+c", "keys trigger displays canonically")
    } catch {
        expect(false, "keys trigger round trip threw: \(error)")
    }

    do {
        let json = """
        {"version":1,"shortcuts":[{"id":"x","name":"left cmd","enabled":true,
         "trigger":{"type":"doubleTap","modifier":"lcmd"},
         "action":{"type":"shell","command":"true"}}]}
        """
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        expectEqual(config.shortcuts[0].trigger.display, "doubleTap:lcmd",
                    "config decodes a side-specific modifier")
    } catch {
        expect(false, "side modifier config threw: \(error)")
    }

    do {
        let json = """
        {"version":1,"shortcuts":[{"id":"x","name":"chrome","enabled":true,
         "trigger":{"type":"keys","keys":"cmd+shift+c"},
         "action":{"type":"shell","command":"open https://example.com"}}]}
        """
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        expectEqual(config.shortcuts[0].trigger.identity, "cmd+shift+c", "combo identity")
        expectEqual(config.shortcuts[0].passThrough, false, "passThrough defaults to false")
        try config.validate()
        expect(true, "a valid combo config validates")
    } catch {
        expect(false, "combo config threw: \(error)")
    }

    do {
        let combo = try KeyCombo.parse("cmd+shift+c")
        let config = Config(shortcuts: [
            Shortcut(id: "a", name: "one", trigger: .keys(combo),
                     action: .shell(command: "true", cwd: nil, timeoutMilliseconds: nil)),
            Shortcut(id: "b", name: "two", trigger: .keys(combo),
                     action: .shell(command: "true", cwd: nil, timeoutMilliseconds: nil))
        ])
        do {
            try config.validate()
            expect(false, "duplicate combos should fail validation")
        } catch {
            expect(true, "duplicate combos fail validation")
        }
    } catch {
        expect(false, "combo setup threw: \(error)")
    }

    expectThrows("passThrough on a gesture is rejected") {
        let config = Config(shortcuts: [
            Shortcut(id: "a", name: "gesture",
                     trigger: .doubleTap(modifier: .command, windowMilliseconds: nil),
                     action: .shell(command: "true", cwd: nil, timeoutMilliseconds: nil),
                     passThrough: true)
        ])
        try config.validate()
    }
}

// MARK: - Double-tap keys

func testDoubleTapKeys() {
    do {
        let json = """
        {"version":1,"shortcuts":[{"id":"x","name":"volume-max","enabled":true,
         "trigger":{"type":"doubleTapKeys","keys":"fn+escape","windowMs":300},
         "action":{"type":"shell","command":"true"}}]}
        """
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        expectEqual(config.shortcuts[0].trigger.display, "doubleTapKeys:fn+escape",
                    "doubleTapKeys decodes")
        expectEqual(config.shortcuts[0].trigger.windowMilliseconds, 300,
                    "doubleTapKeys window decodes")
        let encoded = try JSONEncoder().encode(config)
        let round = try JSONDecoder().decode(Config.self, from: encoded)
        expectEqual(round, config, "doubleTapKeys round trips through JSON")
    } catch {
        expect(false, "doubleTapKeys config threw: \(error)")
    }

    do {
        let combo = try KeyCombo.parse("fn+escape")
        let config = Config(shortcuts: [
            Shortcut(
                id: "a", name: "mute",
                trigger: .keys(combo),
                action: .shell(command: "true", cwd: nil, timeoutMilliseconds: nil)
            ),
            Shortcut(
                id: "b", name: "max",
                trigger: .doubleTapKeys(combo, windowMilliseconds: nil),
                action: .shell(command: "true", cwd: nil, timeoutMilliseconds: nil)
            )
        ])
        try config.validate()
        expect(true, "single and double bindings for one combo coexist")

        let index = BindingIndex(shortcuts: config.shortcuts)
        expectEqual(index.count, 2, "doubleTapKeys counts as a binding")
        expectEqual(index.shortcut(keyCode: 53, held: HeldModifiers([.fn]))?.name, "mute",
                    "single combo lookup still works")
        expectEqual(index.doubleTapShortcut(keyCode: 53, held: HeldModifiers([.fn]))?.name, "max",
                    "double-tap combo lookup works")
        expectNil(index.doubleTapShortcut(keyCode: 53, held: HeldModifiers([])),
                  "double-tap combo requires fn")
    } catch {
        expect(false, "doubleTapKeys index threw: \(error)")
    }
}

// MARK: - V-01 Security controls (Config integrity, TCC disclaim, scrubbed env, native actions)

func testV01SecurityControls() {
    // 1. Config.load rejects 0644 permissions, symlinks (ELOOP), FIFOs (mkfifo), and group-writable parent dirs
    do {
        let baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hotkeyd-v01-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: baseDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: baseDir) }

        let configURL = baseDir.appendingPathComponent(".hotkeyd")
        let config = sampleConfig()
        try config.save(to: configURL)
        expectEqual(try Config.load(from: configURL), config, "0600 regular config loads cleanly")

        // Loosen permissions to 0644 -> must be rejected by Config.load
        _ = chmod(configURL.path, 0o644)
        expectThrows("0644 config is rejected by Config.load") {
            try Config.load(from: configURL)
        }

        // Config.save must restore 0600 via rename (not preserve 0644 like replaceItemAt)
        try config.save(to: configURL)
        var repairedStat = stat()
        expectEqual(lstat(configURL.path, &repairedStat), 0, "lstat after save succeeds")
        expectEqual(repairedStat.st_mode & 0o777, 0o600, "Config.save tightens 0644 target back to 0600")
        expectEqual(try Config.load(from: configURL), config, "re-saved 0600 config loads again")

        // Symlink config -> must be rejected via O_NOFOLLOW (ELOOP)
        let symlinkURL = baseDir.appendingPathComponent("symlink-.hotkeyd")
        expectEqual(symlink(configURL.path, symlinkURL.path), 0, "create config symlink")
        expectThrows("symlink config (ELOOP) is rejected by Config.load") {
            try Config.load(from: symlinkURL)
        }

        // FIFO config -> must be rejected without blocking via O_NONBLOCK + S_ISREG
        let fifoURL = baseDir.appendingPathComponent("fifo-.hotkeyd")
        expectEqual(mkfifo(fifoURL.path, 0o600), 0, "create FIFO config")
        expectThrows("FIFO (mkfifo) config is rejected by Config.load without blocking") {
            try Config.load(from: fifoURL)
        }

        // Group-writable parent directory -> must be rejected
        let looseDir = baseDir.appendingPathComponent("loose-dir")
        try FileManager.default.createDirectory(
            at: looseDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let looseConfigURL = looseDir.appendingPathComponent(".hotkeyd")
        try config.save(to: looseConfigURL)
        _ = chmod(looseDir.path, 0o770)
        expectThrows("config inside group-writable parent directory is rejected") {
            try Config.load(from: looseConfigURL)
        }
        _ = chmod(looseDir.path, 0o700)
    } catch {
        expect(false, "V-01 config integrity test setup threw: \(error)")
    }

    // 2. Paths.realHomeDirectory ignores tampered $HOME, and ignoreEnvironmentOverride ignores HOTKEYD_HOME
    do {
        let originalHome = getenv("HOME").map { String(cString: $0) }
        let originalHotkeydHome = getenv("HOTKEYD_HOME").map { String(cString: $0) }
        defer {
            if let originalHome {
                setenv("HOME", originalHome, 1)
            } else {
                unsetenv("HOME")
            }
            if let originalHotkeydHome {
                setenv("HOTKEYD_HOME", originalHotkeydHome, 1)
            } else {
                unsetenv("HOTKEYD_HOME")
            }
            Paths.ignoreEnvironmentOverride = false
        }

        let expectedHome = Paths.realHomeDirectory.path
        setenv("HOME", "/tmp/evil-home-override", 1)
        expectEqual(
            Paths.realHomeDirectory.path,
            expectedHome,
            "Paths.realHomeDirectory uses getpwuid(getuid()) rather than $HOME"
        )
        expectEqual(
            Paths.expandTilde("~/Documents"),
            "\(expectedHome)/Documents",
            "Paths.expandTilde expands against pw_dir rather than $HOME"
        )

        setenv("HOTKEYD_HOME", "/tmp/evil-hotkeyd-home", 1)
        Paths.ignoreEnvironmentOverride = true
        expectEqual(
            Paths.config.path,
            "\(expectedHome)/.hotkeyd",
            "daemon mode ignores HOTKEYD_HOME environment variable"
        )
    }

    // 3. Kernel-level TCC responsibility disclaim: ShellRunner.responsiblePID(for: childPid) == childPid
    do {
        let outcome = ShellRunner.spawnProcess(
            executablePath: "/bin/sleep",
            arguments: ["/bin/sleep", "2"],
            environment: ["PATH=/usr/bin:/bin"],
            workingDirectory: "/tmp",
            stdinFD: -1,
            stdoutFD: -1,
            stderrFD: -1,
            disclaimResponsibility: true
        )
        switch outcome {
        case .success(let childPid):
            expect(childPid > 0, "spawned child pid is positive")
            let responsible = ShellRunner.responsiblePID(for: childPid)
            expectEqual(
                responsible,
                childPid,
                "ShellRunner.responsiblePID(for: childPid) == childPid when allowAccessibility == false"
            )
            _ = kill(childPid, SIGKILL)
            var status: Int32 = 0
            _ = waitpid(childPid, &status, 0)
        case .failure(let err):
            expect(false, "ShellRunner.spawnProcess failed with errno \(err.errnoCode)")
        }
    }

    // 4. Scrubbed /bin/zsh -fc environment & ZDOTDIR/.zshenv canary isolation
    do {
        let zdotdir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hotkeyd-zdotdir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: zdotdir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: zdotdir) }

        let zshenv = zdotdir.appendingPathComponent(".zshenv")
        try Data("export ZSHENV_CANARY=compromised\n".utf8).write(to: zshenv)

        let prevZdotdir = getenv("ZDOTDIR").map { String(cString: $0) }
        let prevHotkeydHome = getenv("HOTKEYD_HOME").map { String(cString: $0) }
        let prevSshAuthSock = getenv("SSH_AUTH_SOCK").map { String(cString: $0) }
        defer {
            if let prevZdotdir { setenv("ZDOTDIR", prevZdotdir, 1) } else { unsetenv("ZDOTDIR") }
            if let prevHotkeydHome { setenv("HOTKEYD_HOME", prevHotkeydHome, 1) } else { unsetenv("HOTKEYD_HOME") }
            if let prevSshAuthSock { setenv("SSH_AUTH_SOCK", prevSshAuthSock, 1) } else { unsetenv("SSH_AUTH_SOCK") }
        }

        setenv("ZDOTDIR", zdotdir.path, 1)
        setenv("HOTKEYD_HOME", "/tmp/leaked-hotkeyd-home", 1)
        setenv("SSH_AUTH_SOCK", "/tmp/leaked-ssh-agent.sock", 1)

        let result = ShellRunner.run(
            command: "printf 'CANARY=%s|KH=%s|SSH=%s|ZDOT=%s|KS=%s|PWD=%s|PATH=%s' \"${ZSHENV_CANARY:-none}\" \"${HOTKEYD_HOME:-none}\" \"${SSH_AUTH_SOCK:-none}\" \"${ZDOTDIR:-none}\" \"${HOTKEYD:-none}\" \"$PWD\" \"$PATH\"",
            cwd: nil,
            timeoutMilliseconds: 5_000,
            allowAccessibility: false
        )
        expectEqual(result.exitCode, 0, "scrubbed /bin/zsh -fc command exits 0")
        let expectedOutput = "CANARY=none|KH=none|SSH=none|ZDOT=none|KS=1|PWD=\(Paths.realHomeDirectory.path)|PATH=\(ShellRunner.standardPath)"
        expectEqual(
            result.stdout,
            expectedOutput,
            "ZDOTDIR/.zshenv canary and inherited HOTKEYD_HOME / SSH_AUTH_SOCK do not leak into /bin/zsh -fc"
        )

        let privResult = ShellRunner.run(
            command: "printf '%s' \"$PATH\"",
            cwd: nil,
            timeoutMilliseconds: 5_000,
            allowAccessibility: true
        )
        expectEqual(
            privResult.stdout,
            ShellRunner.privilegedPath,
            "allowAccessibility == true restricts PATH to root-owned system directories"
        )
    } catch {
        expect(false, "ZDOTDIR isolation test threw: \(error)")
    }

    // 5. Relative cwd rejection and native .app / .url serialization + unsafe scheme rejection
    expectThrows("relative cwd is rejected by Config.validate") {
        let config = Config(shortcuts: [
            Shortcut(
                id: "rel1",
                name: "relative-cwd",
                trigger: .doubleTap(modifier: .command, windowMilliseconds: nil),
                action: .shell(command: "pwd", cwd: "relative/subdir", timeoutMilliseconds: nil)
            )
        ])
        try config.validate()
    }

    do {
        let appShortcut = Shortcut(
            id: "app1",
            name: "chrome",
            trigger: .doubleTap(modifier: .leftCommand, windowMilliseconds: nil),
            action: .app(target: "Google Chrome", arguments: ["--new-window"])
        )
        let urlShortcut = Shortcut(
            id: "url1",
            name: "docs",
            trigger: .doubleTap(modifier: .rightCommand, windowMilliseconds: nil),
            action: .url("https://example.com/docs")
        )
        let config = Config(shortcuts: [appShortcut, urlShortcut])
        try config.validate()
        let encoded = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(Config.self, from: encoded)
        expectEqual(decoded, config, ".app and .url actions round-trip through JSON")
    } catch {
        expect(false, ".app / .url serialization threw: \(error)")
    }

        for unsafeURL in ["file:///etc/passwd", "javascript:alert(1)", "ssh://user@example.com", "https://"] {
        expect(!Action.isValidWebURL(unsafeURL), "Action.isValidWebURL rejects '\(unsafeURL)'")
        expectThrows("JSONDecoder rejects unsafe URL '\(unsafeURL)'") {
            let json = """
            {"version":1,"shortcuts":[{"id":"u","name":"bad","enabled":true,
             "trigger":{"type":"doubleTap","modifier":"cmd"},
             "action":{"type":"url","url":"\(unsafeURL)"}}]}
            """
            return try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        }
        expectNil(
            Action.migratedFromShellCommand("open \(unsafeURL)"),
            "Action.migratedFromShellCommand never fast-paths unsafe URL '\(unsafeURL)'"
        )
    }

    expectThrows("tap on a modifier-only target is rejected") {
        let config = Config(shortcuts: [
            Shortcut(
                keys: .modifier(.command),
                tap: "open -a Terminal"
            )
        ])
        try config.validate()
    }

    // 6. Action.migratedFromShellCommand upgrades simple open -a / open https://... / open <dir> commands
    expectEqual(
        Action.migratedFromShellCommand("open -a \"Google Chrome\""),
        .app(target: "Google Chrome", arguments: []),
        "migrate open -a with quotes"
    )
    expectEqual(
        Action.migratedFromShellCommand("open -a Visual\\ Studio\\ Code --args --new-window"),
        .app(target: "Visual Studio Code", arguments: ["--new-window"]),
        "migrate open -a with --args"
    )
    expectEqual(
        Action.migratedFromShellCommand("open https://github.com/jardondiego/hotkeyd"),
        .url("https://github.com/jardondiego/hotkeyd"),
        "migrate open https://..."
    )
    expectNil(
        Action.migratedFromShellCommand("open -a Terminal; rm -rf /"),
        "compound shell command is not migrated"
    )
    expectEqual(
        Action.migratedFromShellCommand("open ~/Downloads"),
        .openPath("~/Downloads"),
        "tilde directory open is recognized as .openPath"
    )
    expectEqual(
        Action.migratedFromShellCommand("open ~"),
        .openPath("~"),
        "bare tilde open is recognized as .openPath"
    )
    expectNil(
        ShellRunner.runOpenDirectory("/usr/bin/true"),
        "runOpenDirectory refuses regular executable files (only opens existing directories)"
    )
}

func testUnifiedSchemaAndFormatting() {
    do {
        let json = """
        {
          "shortcuts": [
            { "keys": "fn+space", "tap": "open -a Gemini" },
            { "keys": "lcmd", "doubleTap": "open -a \\"Google Chrome\\"" },
            { "keys": "fn+escape", "tap": "osascript -e 'set volume output muted true'", "doubleTap": "osascript -e 'set volume output volume 100'" }
          ]
        }
        """
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        try config.validate()
        expectEqual(config.shortcuts.count, 3, "unified schema decodes 3 entries")
        expectEqual(config.shortcuts[0].keys, .combo(try KeyCombo.parse("fn+space")), "fn+space combo target")
        expectEqual(config.shortcuts[0].tap, "open -a Gemini", "fn+space tap command")
        expectNil(config.shortcuts[0].doubleTap, "fn+space doubleTap is nil")
        expectEqual(config.shortcuts[1].keys, .modifier(.leftCommand), "lcmd modifier target")
        expectNil(config.shortcuts[1].tap, "lcmd tap is nil")
        expectEqual(config.shortcuts[1].doubleTap, "open -a \"Google Chrome\"", "lcmd doubleTap command")

        let index = BindingIndex(shortcuts: config.shortcuts)
        expectEqual(index.count, 4, "3 entries with 1 paired fn+escape produce 4 active bindings in BindingIndex")
        expectEqual(
            index.shortcut(keyCode: 53, held: HeldModifiers([.fn]))?.activeCommand,
            "osascript -e 'set volume output muted true'",
            "paired fn+escape single-tap slice carries only tap command"
        )
        expectEqual(
            index.doubleTapShortcut(keyCode: 53, held: HeldModifiers([.fn]))?.activeCommand,
            "osascript -e 'set volume output volume 100'",
            "paired fn+escape double-tap slice carries only doubleTap command"
        )

        let formattedData = try config.formattedJSON()
        let formattedText = String(data: formattedData, encoding: .utf8) ?? ""
        let lines = formattedText.split(separator: "\n", omittingEmptySubsequences: false)
        expectEqual(lines.count, 8, "3 shortcuts format into 7 lines + trailing newline")
        let roundTrip = try JSONDecoder().decode(Config.self, from: formattedData)
        expectEqual(roundTrip, config, "formatted 1-line-per-shortcut JSON round-trips losslessly")
    } catch {
        expect(false, "unified schema test threw: \(error)")
    }

    // Legacy v1 paired keys + doubleTapKeys coalesce into a single unified entry on decode
    do {
        let legacyJSON = """
        {
          "version": 1,
          "shortcuts": [
            {
              "id": "1",
              "name": "keys-fn+escape",
              "enabled": true,
              "trigger": { "type": "keys", "keys": "fn+escape" },
              "action": { "type": "shell", "command": "mute" }
            },
            {
              "id": "2",
              "name": "doubletap-fn+escape",
              "enabled": true,
              "trigger": { "type": "doubleTapKeys", "keys": "fn+escape" },
              "action": { "type": "shell", "command": "unmute" }
            }
          ]
        }
        """
        let decoded = try JSONDecoder().decode(Config.self, from: Data(legacyJSON.utf8))
        expectEqual(decoded.shortcuts.count, 1, "legacy paired keys + doubleTapKeys coalesce into 1 entry")
        expectEqual(decoded.shortcuts[0].tap, "mute", "coalesced entry preserves tap command")
        expectEqual(decoded.shortcuts[0].doubleTap, "unmute", "coalesced entry preserves doubleTap command")
        expectNil(decoded.shortcuts[0].name, "auto-generated legacy default names are stripped on migration")
    } catch {
        expect(false, "legacy coalescing test threw: \(error)")
    }

    expectThrows("unknown key in unified shortcut object is rejected") {
        let badJSON = """
        { "shortcuts": [ { "keys": "lcmd", "doubleTap": "true", "typoField": 123 } ] }
        """
        return try JSONDecoder().decode(Config.self, from: Data(badJSON.utf8))
    }
}

// MARK: - V-02, V-03 & V-05 CodeTrust controls

func testCodeTrustControls() {
    // 1. Running debug test binary under /.build/ carrying get-task-allow is unconditionally rejected
    var size: UInt32 = 0
    _NSGetExecutablePath(nil, &size)
    var buf = [CChar](repeating: 0, count: Int(size))
    _NSGetExecutablePath(&buf, &size)
    let selfPath = URL(fileURLWithPath: String(cString: buf)).resolvingSymlinksInPath().path

    do {
        _ = try CodeTrust.verify(binaryPath: selfPath, allowAdhoc: true)
        expect(false, "debug selftest binary must be rejected by CodeTrust.verify")
    } catch let error as CodeTrust.TrustError {
        let msg = error.localizedDescription
        expect(
            msg.contains("get-task-allow") || msg.contains(".build"),
            "debug binary rejection cites get-task-allow or .build directory"
        )
    } catch {
        expect(false, "unexpected error type from CodeTrust.verify: \(error)")
    }

    // 2. Test binaries outside /.build/ and /tmp/ (inside /var/folders temp directory)
    do {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hotkeyd-codetrust-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: workDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: workDir) }

        let binURL = workDir.appendingPathComponent("dummy-hotkeyd")
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: binURL.path)

        // (a) Signed ad-hoc WITHOUT --options runtime -> rejected for missing Hardened Runtime
        let signNoRuntime = ShellRunner.run(
            command: "/usr/bin/codesign --force --sign - --identifier io.github.jardondiego.hotkeyd --requirements '=designated => identifier \"io.github.jardondiego.hotkeyd\"' '\(binURL.path)'",
            cwd: workDir.path,
            timeoutMilliseconds: 10_000
        )
        expectEqual(signNoRuntime.exitCode, 0, "codesign without --options runtime succeeds")
        do {
            _ = try CodeTrust.verify(binaryPath: binURL.path, allowAdhoc: true)
            expect(false, "binary without --options runtime must be rejected")
        } catch let error as CodeTrust.TrustError {
            expectEqual(
                error,
                .missingHardenedRuntime(binURL.path),
                "CodeTrust.verify rejects binary lacking Hardened Runtime (--options runtime)"
            )
        } catch {
            expect(false, "unexpected error: \(error)")
        }

        // (b) Signed ad-hoc WITH --options runtime -> rejected by default (allowAdhoc == false),
        //     accepted only when allowAdhoc == true
        let signAdhocRuntime = ShellRunner.run(
            command: "/usr/bin/codesign --force --sign - --options runtime --identifier io.github.jardondiego.hotkeyd --requirements '=designated => identifier \"io.github.jardondiego.hotkeyd\"' '\(binURL.path)'",
            cwd: workDir.path,
            timeoutMilliseconds: 10_000
        )
        expectEqual(signAdhocRuntime.exitCode, 0, "codesign with --options runtime succeeds")
        do {
            _ = try CodeTrust.verify(binaryPath: binURL.path, allowAdhoc: false)
            expect(false, "ad-hoc identifier-only binary must be rejected by default")
        } catch let error as CodeTrust.TrustError {
            expectEqual(
                error,
                .adhocSignatureDisallowed(binURL.path),
                "CodeTrust.verify rejects ad-hoc identifier-only binary by default"
            )
        } catch {
            expect(false, "unexpected error: \(error)")
        }

        let adhocReport = try CodeTrust.verify(binaryPath: binURL.path, allowAdhoc: true)
        expect(adhocReport.hasHardenedRuntime, "allowAdhoc report confirms CS_RUNTIME")
        expect(adhocReport.isAdhoc, "allowAdhoc report identifies ad-hoc flag")

        // (c) Signed WITH --options runtime AND dangerous relaxation entitlement -> rejected even with allowAdhoc
        let entURL = workDir.appendingPathComponent("bad.entitlements")
        let entXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>com.apple.security.cs.allow-dyld-environment-variables</key>
            <true/>
        </dict>
        </plist>
        """
        try Data(entXML.utf8).write(to: entURL)
        let signRelaxed = ShellRunner.run(
            command: "/usr/bin/codesign --force --sign - --options runtime --entitlements '\(entURL.path)' --identifier io.github.jardondiego.hotkeyd '\(binURL.path)'",
            cwd: workDir.path,
            timeoutMilliseconds: 10_000
        )
        expectEqual(signRelaxed.exitCode, 0, "codesign with relaxation entitlement succeeds")
        expectThrows("relaxation entitlement allow-dyld-environment-variables is rejected") {
            try CodeTrust.verify(binaryPath: binURL.path, allowAdhoc: true)
        }
    } catch {
        expect(false, "CodeTrust test threw: \(error)")
    }
}

func testStrictModesAndAtomicSave() {
    let dir = Paths.realHomeDirectory.appendingPathComponent(".hotkeyd-strictmodes-test-\(UUID().uuidString)")
    do {
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        // 1. Pre-existing 0644 .hotkeyd is replaced with 0600 on Config.save
        let configURL = dir.appendingPathComponent(".hotkeyd")
        try Data("{\"version\":1,\"shortcuts\":[]}\n".utf8).write(to: configURL)
        _ = chmod(configURL.path, 0o644)

        let cfg = Config()
        try cfg.save(to: configURL)

        var st = stat()
        expectEqual(lstat(configURL.path, &st), 0, "lstat on saved config succeeds")
        expectEqual(st.st_mode & 0o777, 0o600, "Config.save replaces 0644 file with 0600")

        // 2. StrictModes.verifySecurePath accepts secure directory and regular file
        try StrictModes.verifySecurePath(dir.path, expectRegularFile: false)
        try StrictModes.verifySecurePath(configURL.path, expectRegularFile: true)
        expect(true, "StrictModes.verifySecurePath accepts 0700 dir and 0600 file")

        // 3. StrictModes.verifySecurePath rejects group/world-writable directory
        let looseDir = dir.appendingPathComponent("loose")
        try FileManager.default.createDirectory(at: looseDir, withIntermediateDirectories: true)
        _ = chmod(looseDir.path, 0o775)
        expectThrows("StrictModes rejects 0775 group-writable directory") {
            try StrictModes.verifySecurePath(looseDir.path, expectRegularFile: false)
        }

        // 4. StrictModes.verifySecurePath rejects symlink component
        let symPath = dir.appendingPathComponent("sym-link").path
        _ = symlink(configURL.path, symPath)
        expectThrows("StrictModes rejects symlink") {
            try StrictModes.verifySecurePath(symPath, expectRegularFile: true)
        }

        // 5. Config.withExclusiveLock acquires lock and creates 0600 lock file
        let lockedResult = try Config.withExclusiveLock(for: configURL) {
            return 42
        }
        expectEqual(lockedResult, 42, "Config.withExclusiveLock executes body and returns value")
    } catch {
        expect(false, "StrictModes test threw: \(error)")
    }
}

func testProcessGroupTimeoutAndPipeBounds() {
    // 1. Timeout kills entire process group (including backgrounded child)
    let pidFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("hotkeyd-grandchild-\(UUID().uuidString).pid")
    defer { try? FileManager.default.removeItem(at: pidFile) }

    let timeoutResult = ShellRunner.run(
        command: "/bin/sleep 60 & echo $! > '\(pidFile.path)'; wait",
        cwd: "/tmp",
        timeoutMilliseconds: 250,
        allowAccessibility: false
    )
    expect(timeoutResult.timedOut, "ShellRunner.run marks timedOut == true when command exceeds timeout")
    if let rawPid = try? String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
       let grandchildPid = pid_t(rawPid), grandchildPid > 0 {
        // Wait briefly for process group SIGTERM/SIGKILL reaping
        usleep(100_000)
        let alive = (kill(grandchildPid, 0) == 0)
        expect(!alive, "backgrounded grandchild in timed-out process group is terminated")
        if alive {
            _ = kill(grandchildPid, SIGKILL)
        }
    } else {
        expect(false, "grandchild PID file was written before timeout")
    }

    // 2. 1 MiB stdout output is bounded to 4096 bytes (+ truncation suffix) in memory
    let noisyResult = ShellRunner.run(
        command: "/usr/bin/yes A | /usr/bin/head -c 1048576",
        cwd: "/tmp",
        timeoutMilliseconds: 5_000,
        allowAccessibility: false
    )
    expect(
        noisyResult.stdout.hasSuffix("\n… truncated") && noisyResult.stdout.utf8.count <= ShellRunner.maxCapturedBytes + 16,
        "1 MiB stdout is bounded to 4096 bytes in memory"
    )

    // 3. dispatchDetached spawns child synchronously before returning
    let markerFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("hotkeyd-detached-\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: markerFile) }

    let shortcut = Shortcut(
        id: "det",
        name: "detached-test",
        trigger: .doubleTap(modifier: .command, windowMilliseconds: nil),
        action: .shell(command: "printf ok > '\(markerFile.path)'", cwd: "/tmp", timeoutMilliseconds: nil)
    )
    do {
        try ShellRunner.dispatchDetached(shortcut: shortcut)
        var created = false
        for _ in 0..<30 {
            if FileManager.default.fileExists(atPath: markerFile.path) {
                created = true
                break
            }
            usleep(50_000)
        }
        expect(created, "ShellRunner.dispatchDetached spawns child before returning")
    } catch {
        expect(false, "dispatchDetached threw: \(error)")
    }
}

func testConcurrencyAndEventGuards() {
    // 1. Hammer Log.action concurrently from 32 threads inside isolated HOTKEYD_HOME
    let tempHome = FileManager.default.temporaryDirectory
        .appendingPathComponent("hotkeyd-log-stress-\(UUID().uuidString)")
    let prevHotkeydHome = getenv("HOTKEYD_HOME").map { String(cString: $0) }
    let prevIgnore = Paths.ignoreEnvironmentOverride
    defer {
        Paths.ignoreEnvironmentOverride = prevIgnore
        if let prevHotkeydHome {
            setenv("HOTKEYD_HOME", prevHotkeydHome, 1)
        } else {
            unsetenv("HOTKEYD_HOME")
        }
        try? FileManager.default.removeItem(at: tempHome)
    }
    Paths.ignoreEnvironmentOverride = false
    setenv("HOTKEYD_HOME", tempHome.path, 1)

    let group = DispatchGroup()
    for index in 0..<32 {
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            Log.action("concurrent-stress-\(index)")
            group.leave()
        }
    }
    group.wait()
    Log.flush()
    let logData = (try? String(contentsOf: Paths.actionLog, encoding: .utf8)) ?? ""
    let lineCount = logData.split(separator: "\n").count
    expectEqual(lineCount, 32, "32 concurrent Log.action writes all land cleanly without data race")

    // 2. Out-of-range CGEvent keyboardEventKeycode values do not trap with UInt16(truncatingIfNeeded:)
    if let eventNeg = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
       let eventBig = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) {
        eventNeg.setIntegerValueField(.keyboardEventKeycode, value: -1)
        eventBig.setIntegerValueField(.keyboardEventKeycode, value: 70_000)
        let codeNeg = UInt16(truncatingIfNeeded: eventNeg.getIntegerValueField(.keyboardEventKeycode))
        let codeBig = UInt16(truncatingIfNeeded: eventBig.getIntegerValueField(.keyboardEventKeycode))
        expectEqual(codeNeg, UInt16.max, "negative keycode truncates safely without trapping")
        expectEqual(codeBig, UInt16(truncatingIfNeeded: 70_000), "large keycode truncates safely without trapping")
    }
}

func testCommandRegistryAndSchemas() {
    let manifest = CommandRegistry.manifest(
        version: "0.1.0-dev",
        configPath: "/Users/test/.hotkeyd",
        logsPath: "/Users/test/Library/Application Support/Hotkeyd/logs",
        launchAgentPath: "/Users/test/Library/LaunchAgents/io.github.jardondiego.hotkeyd.daemon.plist"
    )
    expect(!manifest.commands.isEmpty, "CommandRegistry has registered commands")

    var seenPaths: Set<String> = []
    for cmd in manifest.commands {
        let label = cmd.displayName
        expect(seenPaths.insert(label).inserted, "unique command path '\(label)'")
        expect(!cmd.summary.isEmpty, "command '\(label)' has non-empty summary")
        expect(!cmd.description.isEmpty, "command '\(label)' has non-empty description")
        expect(!cmd.examples.isEmpty, "command '\(label)' has at least one example")
        expect(!cmd.exitCodes.isEmpty, "command '\(label)' declares exit codes")
        for code in cmd.exitCodes {
            expect(
                CommandRegistry.exitCodeDescriptions[String(code)] != nil,
                "command '\(label)' exit code \(code) is documented in exitCodeDescriptions"
            )
        }
        for arg in cmd.args {
            expect(!arg.name.isEmpty && !arg.type.isEmpty && !arg.description.isEmpty,
                   "command '\(label)' arg '\(arg.name)' is fully documented")
        }
        for flag in cmd.flags {
            expect(flag.name.hasPrefix("--") && !flag.type.isEmpty && !flag.description.isEmpty,
                   "command '\(label)' flag '\(flag.name)' is fully documented")
        }
    }

    do {
        let encoded = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(ToolManifest.self, from: encoded)
        expectEqual(decoded, manifest, "ToolManifest round-trips losslessly through JSON")
    } catch {
        expect(false, "ToolManifest JSON round-trip threw: \(error)")
    }

    if let configSchemaData = CommandRegistry.renderJSONSchema(target: "config"),
       let configSchema = (try? JSONSerialization.jsonObject(with: configSchemaData)) as? [String: Any] {
        expectEqual(
            configSchema["$schema"] as? String,
            "https://json-schema.org/draft/2020-12/schema",
            "config JSON Schema uses draft 2020-12"
        )
        expectEqual(configSchema["additionalProperties"] as? Bool, false, "config JSON Schema forbids unknown top-level keys")
    } else {
        expect(false, "CommandRegistry.renderJSONSchema(target: 'config') failed")
    }

    if let shortcutSchemaData = CommandRegistry.renderJSONSchema(target: "shortcut"),
       let shortcutSchema = (try? JSONSerialization.jsonObject(with: shortcutSchemaData)) as? [String: Any],
       let props = shortcutSchema["properties"] as? [String: Any] {
        let expectedProps: Set<String> = [
            "keys", "tap", "doubleTap", "name",
            "maxDoubleTapDelayMs", "windowMs", "maxSequenceDelayMs", "timeoutMs",
            "cwd", "passThrough", "allowAccessibility", "enabled"
        ]
        expectEqual(Set(props.keys), expectedProps, "shortcut JSON Schema documents all 12 Shortcut properties (including legacy windowMs)")
        expectEqual(shortcutSchema["additionalProperties"] as? Bool, false, "shortcut JSON Schema forbids unknown keys")
    } else {
        expect(false, "CommandRegistry.renderJSONSchema(target: 'shortcut') failed")
    }

    expectNil(CommandRegistry.renderJSONSchema(target: "unknown-target"), "unknown schema target returns nil")

    // Command lookup & per-command help rendering
    if let addSpec = CommandRegistry.findCommand(matching: ["add"]) {
        let help = CommandRegistry.formatHelp(for: addSpec)
        expect(help.contains("hotkeyd add"), "formatHelp(for: add) contains command title")
        expect(help.contains("--force"), "formatHelp(for: add) documents --force")
        expect(help.contains("EXAMPLES"), "formatHelp(for: add) includes examples")
    } else {
        expect(false, "CommandRegistry.findCommand(['add']) failed")
    }

    expectEqual(
        CommandRegistry.findCommand(matching: ["ls"])?.path,
        ["list"],
        "CommandRegistry.findCommand resolves 'ls' alias to 'list'"
    )
    expectEqual(
        CommandRegistry.findCommand(matching: ["rm"])?.path,
        ["remove"],
        "CommandRegistry.findCommand resolves 'rm' alias to 'remove'"
    )
    expectEqual(
        CommandRegistry.findCommand(matching: ["daemon", "status"])?.path,
        ["daemon", "status"],
        "CommandRegistry.findCommand resolves 'daemon status'"
    )
    expectEqual(
        CommandRegistry.findCommand(matching: ["daemon", "logs"])?.path,
        ["daemon", "logs"],
        "CommandRegistry.findCommand resolves 'daemon logs'"
    )
    if let daemonGroupHelp = CommandRegistry.formatGroupHelp(group: "daemon") {
        expect(daemonGroupHelp.contains("daemon status"), "daemon group help lists daemon status")
        expect(daemonGroupHelp.contains("daemon start"), "daemon group help lists daemon start")
        expect(daemonGroupHelp.contains("daemon stop"), "daemon group help lists daemon stop")
        expect(daemonGroupHelp.contains("daemon logs"), "daemon group help lists daemon logs")
    } else {
        expect(false, "CommandRegistry.formatGroupHelp(group: 'daemon') returned nil")
    }

    // README.md parity: verify every top-level registered command is documented in README.md.
    let selfPathForDocs = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let repoRootForDocs = selfPathForDocs
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let readmeURL = repoRootForDocs.appendingPathComponent("README.md")
    if let readmeText = try? String(contentsOf: readmeURL, encoding: .utf8) {
        let topLevelCommands = Set(CommandRegistry.commands.compactMap(\.path.first))
        for cmd in topLevelCommands.sorted() {
            expect(
                readmeText.contains("hotkeyd \(cmd)"),
                "README.md documents registered top-level command `hotkeyd \(cmd)`"
            )
        }
    }

    // End-to-end CLI UX tests against the compiled hotkeyd binary in a sandboxed HOTKEYD_HOME
    var size: UInt32 = 0
    _NSGetExecutablePath(nil, &size)
    var buf = [CChar](repeating: 0, count: Int(size))
    _NSGetExecutablePath(&buf, &size)
    let selfURL = URL(fileURLWithPath: String(cString: buf)).resolvingSymlinksInPath()
    let cliURL = selfURL.deletingLastPathComponent().appendingPathComponent("hotkeyd")

    if FileManager.default.isExecutableFile(atPath: cliURL.path) {
        let sandbox = Paths.realHomeDirectory.appendingPathComponent(".hotkeyd-cli-ux-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: sandbox,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: sandbox) }

        func runCLI(_ args: String) -> ShellResult {
            ShellRunner.run(
                command: "HOTKEYD_HOME='\(sandbox.path)' '\(cliURL.path)' \(args)",
                cwd: sandbox.path,
                timeoutMilliseconds: 10_000
            )
        }

        // 1. Bare `hotkeyd` exits 0 and prints usage
        let bare = runCLI("")
        expectEqual(bare.exitCode, 0, "bare `hotkeyd` exits 0")
        expect(bare.stdout.contains("USAGE"), "bare `hotkeyd` prints usage")
        expect(!bare.stdout.contains("migrate-actions"), "main usage hides internal migrate-actions")

        // 2. Per-command `--help` / `-h` and `help <cmd>`
        let helpAdd = runCLI("add -h")
        expectEqual(helpAdd.exitCode, 0, "`hotkeyd add -h` exits 0")
        expect(helpAdd.stdout.contains("hotkeyd add —"), "`hotkeyd add -h` prints targeted add help")
        let helpDaemon = runCLI("help daemon")
        expectEqual(helpDaemon.exitCode, 0, "`hotkeyd help daemon` exits 0")
        expect(helpDaemon.stdout.contains("SUBCOMMANDS"), "`hotkeyd help daemon` prints daemon subcommands")

        // 3. 2-positional shorthand: modifier infers doubleTap, combo infers tap
        let addMod = runCLI("add lcmd 'open -a \"Google Chrome\"'")
        expectEqual(addMod.exitCode, 0, "positional `add lcmd '<cmd>'` succeeds")
        expect(addMod.stdout.contains("doubleTap: open -a \"Google Chrome\""), "modifier positional infers doubleTap")

        let addCombo = runCLI("add fn+space 'open -a Gemini'")
        expectEqual(addCombo.exitCode, 0, "positional `add fn+space '<cmd>'` succeeds")
        expect(addCombo.stdout.contains("tap:       open -a Gemini"), "combo positional infers tap")

        // 4. Duplicate `add` without `--force` fails; with `--json` emits JSON error envelope
        let conflictJSON = runCLI("add lcmd 'open -a Warp' --json")
        expectEqual(conflictJSON.exitCode, 4, "duplicate add without --force exits 4")
        expect(conflictJSON.stdout.contains("\"ok\" : false"), "`--json` error emits ok:false envelope")
        expect(conflictJSON.stdout.contains("\"code\" : 4"), "`--json` error includes exit code 4")

        // 5. `hotkeyd set` and `hotkeyd add --force` overwrite in place
        let setMod = runCLI("set lcmd 'open -a Warp'")
        expectEqual(setMod.exitCode, 0, "`hotkeyd set lcmd '<cmd>'` overwrites existing binding")
        expect(setMod.stdout.contains("updated lcmd"), "`hotkeyd set` reports updated")

        // 6. `hotkeyd list` outputs clean `KEYS | WHEN | COMMAND` table with zero truncation
        let listOut = runCLI("list")
        expectEqual(listOut.exitCode, 0, "`hotkeyd list` exits 0")
        expect(listOut.stdout.contains("KEYS"), "`hotkeyd list` header has KEYS")
        expect(listOut.stdout.contains("WHEN"), "`hotkeyd list` header has WHEN")
        expect(listOut.stdout.contains("COMMAND"), "`hotkeyd list` header has COMMAND")
        expect(listOut.stdout.contains("doubleTap  open -a Warp"), "`hotkeyd list` shows updated lcmd doubleTap")
        expect(listOut.stdout.contains("tap        open -a Gemini"), "`hotkeyd list` shows fn+space tap")

        // 7. `hotkeyd logs --json` and `hotkeyd daemon status --json`
        let logsJSON = runCLI("logs --lines 5 --json")
        expectEqual(logsJSON.exitCode, 0, "`hotkeyd logs --json` exits 0")
        expect(logsJSON.stdout.contains("\"command\" : \"logs\""), "`hotkeyd logs --json` emits logs envelope")

        let daemonStatusJSON = runCLI("daemon status --json")
        expectEqual(daemonStatusJSON.exitCode, 0, "`hotkeyd daemon status --json` exits 0")
        expect(
            daemonStatusJSON.stdout.contains("\"command\" : \"daemon.status\""),
            "`hotkeyd daemon status --json` emits daemon.status envelope"
        )
    }
}

// MARK: - Two-step sequences & delay naming

func testSequences() {
    // 1. Parsing & canonicalization
    do {
        let cases: [(String, String)] = [
            ("fn>q", "fn > q"),
            ("  RCMD  >  Q  ", "rcmd > q"),
            ("capsLock > F1", "capsLock > f1"),
            ("lshift > forwardDelete", "lshift > forwarddelete"),
            ("ropt > ,", "ropt > comma"),
            ("lctrl > space", "lctrl > space"),
            ("opt > return", "opt > return"),
            ("cmd > escape", "cmd > escape")
        ]
        for (raw, expected) in cases {
            let parsed = try KeyTarget.parse(raw)
            expectEqual(parsed.canonical, expected, "sequence '\(raw)' canonicalizes to '\(expected)'")
            expect(parsed.sequence != nil, "'\(raw)' parses as .sequence")
        }
        let roundTrip = try KeySequence.parse("rctrl > f12")
        expectEqual(try KeySequence.parse(roundTrip.canonical), roundTrip, "sequence parse/canonical round-trips")
        expectEqual(roundTrip.sideSpecificity, 1, "sided sequence leader has specificity 1")
        expectEqual(try KeySequence.parse("ctrl > f12").sideSpecificity, 0, "unsided sequence leader has specificity 0")
    } catch {
        expect(false, "sequence parse tests threw: \(error)")
    }

    // 2. Invalid sequence syntax & leader/follower rejections
    for invalid in [
        "shift > q",
        "SHIFT > F1",
        "fn+cmd > q",
        "q > w",
        "fn > cmd",
        "fn > capsLock",
        "fn > cmd+q",
        "fn > q > w",
        "fn > ",
        "> q",
        "fn >",
        "fn > nope"
    ] {
        expectThrows("invalid sequence '\(invalid)' is rejected") {
            try KeyTarget.parse(invalid)
        }
    }

    // 3. Config validation, maxDoubleTapDelayMs / maxSequenceDelayMs, legacy windowMs, and F18 conflict
    do {
        let validSeq = try KeySequence.parse("fn > q")
        let validConfig = Config(shortcuts: [
            Shortcut(keys: .sequence(validSeq), tap: "open -a Safari", maxSequenceDelayMilliseconds: 100),
            Shortcut(keys: .sequence(try KeySequence.parse("rcmd > space")), tap: "open ~", maxSequenceDelayMilliseconds: 1500),
            Shortcut(keys: .modifier(.leftCommand), doubleTap: "open -a Terminal", maxDoubleTapDelayMilliseconds: 100),
            Shortcut(keys: .modifier(.rightCommand), doubleTap: "open ~", maxDoubleTapDelayMilliseconds: 600)
        ])
        try validConfig.validate()
        let formatted = String(decoding: try validConfig.formattedJSON(), as: UTF8.self)
        expect(formatted.contains("\"keys\": \"fn > q\""), "formattedJSON emits canonical 'fn > q'")
        expect(formatted.contains("\"maxSequenceDelayMs\": 100"), "formattedJSON emits maxSequenceDelayMs")
        expect(formatted.contains("\"maxDoubleTapDelayMs\": 100"), "formattedJSON emits maxDoubleTapDelayMs")
        expect(!formatted.contains("windowMs"), "formattedJSON never emits legacy windowMs")
        let decoded = try JSONDecoder().decode(Config.self, from: Data(formatted.utf8))
        expectEqual(decoded, validConfig, "sequence + delay config round-trips losslessly")
    } catch {
        expect(false, "valid sequence config threw: \(error)")
    }

    do {
        let legacyWindowJSON = """
        {
          "shortcuts": [
            { "keys": "lcmd", "doubleTap": "open -a Safari", "windowMs": 350 }
          ]
        }
        """
        let decoded = try JSONDecoder().decode(Config.self, from: Data(legacyWindowJSON.utf8))
        expectEqual(decoded.shortcuts[0].maxDoubleTapDelayMilliseconds, 350, "legacy windowMs decodes into maxDoubleTapDelayMilliseconds")
        let reencoded = String(decoding: try decoded.formattedJSON(), as: UTF8.self)
        expect(reencoded.contains("\"maxDoubleTapDelayMs\": 350"), "re-saving upgrades legacy windowMs to maxDoubleTapDelayMs")
        expect(!reencoded.contains("windowMs"), "re-saving drops legacy windowMs key")
    } catch {
        expect(false, "legacy windowMs decode test threw: \(error)")
    }

    expectThrows("both maxDoubleTapDelayMs and windowMs in one shortcut object is rejected") {
        let json = """
        { "shortcuts": [ { "keys": "lcmd", "doubleTap": "true", "maxDoubleTapDelayMs": 300, "windowMs": 350 } ] }
        """
        return try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    }

    expectThrows("doubleTap on sequence is rejected by Config.validate") {
        let config = Config(shortcuts: [
            Shortcut(keys: .sequence(try KeySequence.parse("fn > q")), tap: "true", doubleTap: "true")
        ])
        try config.validate()
    }

    expectThrows("maxSequenceDelayMs 99 is rejected") {
        let config = Config(shortcuts: [
            Shortcut(keys: .sequence(try KeySequence.parse("fn > q")), tap: "true", maxSequenceDelayMilliseconds: 99)
        ])
        try config.validate()
    }

    expectThrows("maxSequenceDelayMs 1501 is rejected") {
        let config = Config(shortcuts: [
            Shortcut(keys: .sequence(try KeySequence.parse("fn > q")), tap: "true", maxSequenceDelayMilliseconds: 1501)
        ])
        try config.validate()
    }

    expectThrows("maxSequenceDelayMs on combo is rejected") {
        let config = Config(shortcuts: [
            Shortcut(keys: .combo(try KeyCombo.parse("fn+space")), tap: "true", maxSequenceDelayMilliseconds: 400)
        ])
        try config.validate()
    }

    expectThrows("maxDoubleTapDelayMs 601 is rejected") {
        let config = Config(shortcuts: [
            Shortcut(keys: .modifier(.command), doubleTap: "true", maxDoubleTapDelayMilliseconds: 601)
        ])
        try config.validate()
    }

    expectThrows("maxDoubleTapDelayMs without doubleTap is rejected") {
        let config = Config(shortcuts: [
            Shortcut(keys: .combo(try KeyCombo.parse("fn+space")), tap: "true", maxDoubleTapDelayMilliseconds: 350)
        ])
        try config.validate()
    }

    expectThrows("duplicate sequence trigger is rejected") {
        let seq = try KeySequence.parse("fn > q")
        let config = Config(shortcuts: [
            Shortcut(keys: .sequence(seq), tap: "echo one"),
            Shortcut(keys: .sequence(seq), tap: "echo two")
        ])
        try config.validate()
    }

    expectThrows("<mod> > f18 conflicts with enabled capsLock doubleTap") {
        let config = Config(shortcuts: [
            Shortcut(keys: .modifier(.capsLock), doubleTap: "true"),
            Shortcut(keys: .sequence(try KeySequence.parse("fn > f18")), tap: "true")
        ])
        try config.validate()
    }

    expectThrows("<mod> > f18 conflicts with enabled capsLock > a sequence") {
        let config = Config(shortcuts: [
            Shortcut(keys: .sequence(try KeySequence.parse("capsLock > a")), tap: "true"),
            Shortcut(keys: .sequence(try KeySequence.parse("fn > f18")), tap: "true")
        ])
        try config.validate()
    }

    do {
        let config = Config(shortcuts: [
            Shortcut(keys: .sequence(try KeySequence.parse("capsLock > a")), tap: "true", enabled: false),
            Shortcut(keys: .sequence(try KeySequence.parse("fn > f18")), tap: "true")
        ])
        try config.validate()
        expect(true, "<mod> > f18 is allowed when capsLock binding is disabled")
    } catch {
        expect(false, "<mod> > f18 should pass when capsLock is disabled: \(error)")
    }

    // 4. BindingIndex precedence (sided leader beats unsided leader)
    do {
        let rctrlQ = Shortcut(keys: .sequence(try KeySequence.parse("rctrl > q")), tap: "echo right-q")
        let ctrlQ = Shortcut(keys: .sequence(try KeySequence.parse("ctrl > q")), tap: "echo any-q")
        let ctrlW = Shortcut(keys: .sequence(try KeySequence.parse("ctrl > w")), tap: "echo any-w")
        let config = Config(shortcuts: [ctrlQ, rctrlQ, ctrlW])
        try config.validate()
        let index = BindingIndex(shortcuts: config.shortcuts)
        expectEqual(index.count, 3, "BindingIndex counts all 3 sequences")
        expectEqual(index.sequenceShortcut(leader: .rightControl, keyCode: 12)?.tap, "echo right-q",
                    "rctrl > q wins over ctrl > q for rightControl")
        expectEqual(index.sequenceShortcut(leader: .leftControl, keyCode: 12)?.tap, "echo any-q",
                    "leftControl falls back to ctrl > q")
        expectEqual(index.sequenceShortcut(leader: .rightControl, keyCode: 13)?.tap, "echo any-w",
                    "rightControl falls back to ctrl > w when no rctrl > w exists")
    } catch {
        expect(false, "BindingIndex sequence specificity test threw: \(error)")
    }

    // 5. SequenceDetector state machine
    do {
        var seq = SequenceDetector()
        seq.onModifiers([.fn], at: 0.00, doubleTapFired: false)
        seq.onModifiers([], at: 0.08, doubleTapFired: false)
        expectEqual(seq.armedLeader, .fn, "clean fn tap arms leader")
        let cand = seq.consumeKeyDown(keyCode: 12, held: HeldModifiers(), at: 0.25)
        expectEqual(cand?.leader, .fn, "step 2 within 250ms matches fn")
        expect(abs((cand?.elapsed ?? -1) - 0.17) < 0.001, "elapsed reflects gap since release")
        expectNil(seq.armedLeader, "matching disarms leader")
    }

    do {
        var seq = SequenceDetector()
        seq.onModifiers([.fn], at: 0.00, doubleTapFired: false)
        seq.onModifiers([], at: 0.28, doubleTapFired: false)
        expectNil(seq.armedLeader, "modifier held > 250ms does not arm leader")
        expectNil(seq.consumeKeyDown(keyCode: 12, held: HeldModifiers(), at: 0.35), "held modifier never fires sequence")
    }

    do {
        var seq = SequenceDetector()
        seq.onModifiers([.fn], at: 0.00, doubleTapFired: false)
        seq.onModifiers([], at: 0.08, doubleTapFired: false)
        let cand = seq.consumeKeyDown(keyCode: 12, held: HeldModifiers(), at: 0.34)
        expect(cand != nil && (cand?.elapsed ?? 0) > seq.defaultMaxDelay, "260ms gap exceeds default 250ms delay")
        expect((cand?.elapsed ?? 99) <= 0.60, "260ms gap still fits 600ms maxSequenceDelayMs override")
    }

    do {
        var seq = SequenceDetector()
        seq.onModifiers([.leftCommand], at: 0.00, doubleTapFired: false)
        seq.onModifiers([.leftCommand, .leftShift], at: 0.02, doubleTapFired: false)
        seq.onModifiers([.leftShift], at: 0.05, doubleTapFired: false)
        seq.onModifiers([], at: 0.08, doubleTapFired: false)
        expectNil(seq.armedLeader, "staggered multi-modifier chord release never arms leader")
    }

    do {
        var seq = SequenceDetector()
        seq.onModifiers([.fn], at: 0.00, doubleTapFired: false)
        expectNil(seq.consumeKeyDown(keyCode: 49, held: HeldModifiers([.fn]), at: 0.05), "fn+space does not match sequence")
        seq.onModifiers([], at: 0.12, doubleTapFired: false)
        expectNil(seq.armedLeader, "releasing fn after fn+space combo does not arm leader")
    }

    do {
        var seq = SequenceDetector()
        seq.onModifiers([.fn], at: 0.00, doubleTapFired: false)
        seq.onModifiers([], at: 0.08, doubleTapFired: false)
        // Apple Silicon emits Globe (179) keyDown/keyUp right after fn release.
        expectNil(seq.consumeKeyDown(keyCode: 179, held: HeldModifiers(), at: 0.09), "Globe 179 artifact does not fire")
        expectEqual(seq.armedLeader, .fn, "Globe 179 artifact keeps fn leader armed")
        let cand = seq.consumeKeyDown(keyCode: 12, held: HeldModifiers(), at: 0.18)
        expectEqual(cand?.leader, .fn, "q after fn + Globe 179 matches fn > q")
    }

    do {
        var seq = SequenceDetector()
        seq.onModifiers([.fn], at: 0.00, doubleTapFired: false)
        seq.onModifiers([], at: 0.08, doubleTapFired: false)
        _ = seq.consumeKeyDown(keyCode: 0, held: HeldModifiers(), at: 0.12) // unbound 'a'
        expectNil(seq.armedLeader, "unbound step-2 key disarms immediately")
        expectNil(seq.consumeKeyDown(keyCode: 12, held: HeldModifiers(), at: 0.16), "later bound key does not match after disarm")
    }

    do {
        var seq = SequenceDetector()
        seq.onModifiers([.fn], at: 0.00, doubleTapFired: false)
        seq.onModifiers([], at: 0.08, doubleTapFired: false)
        expectNil(seq.consumeKeyDown(keyCode: 12, held: HeldModifiers([.leftCommand]), at: 0.14),
                  "step-2 key with held modifier fails and disarms")
        expectNil(seq.armedLeader, "held modifier on step 2 disarmed leader")
    }

    do {
        var seq = SequenceDetector()
        seq.onModifiers([.fn], at: 0.00, doubleTapFired: false)
        seq.onModifiers([], at: 0.08, doubleTapFired: false)
        expectNil(seq.consumeKeyDown(keyCode: 12, held: HeldModifiers(), isRepeat: true, at: 0.14),
                  "auto-repeat keyDown does not trigger sequence")
        expectNil(seq.armedLeader, "auto-repeat keyDown disarms leader")
    }

    do {
        var seq = SequenceDetector()
        seq.onModifiers([.fn], at: 0.00, doubleTapFired: false)
        seq.onModifiers([], at: 0.08, doubleTapFired: false)
        seq.onMouse()
        expectNil(seq.armedLeader, "mouse activity disarms leader")
    }

    do {
        var seq = SequenceDetector()
        seq.onModifiers([.fn], at: 0.00, doubleTapFired: false)
        seq.onModifiers([], at: 0.06, doubleTapFired: false)
        seq.onModifiers([.fn], at: 0.14, doubleTapFired: false)
        seq.onModifiers([], at: 0.20, doubleTapFired: true)
        expectNil(seq.armedLeader, "firing bare-modifier doubleTap disarms sequence leader")
        expectNil(seq.consumeKeyDown(keyCode: 12, held: HeldModifiers(), at: 0.25),
                  "typing q right after doubleTap:fn does not fire fn > q")
    }

    do {
        var seq = SequenceDetector()
        seq.onModifiers([.fn], at: 0.00, doubleTapFired: false)
        seq.onModifiers([], at: 0.06, doubleTapFired: false)
        seq.onModifiers([.fn], at: 0.18, doubleTapFired: false)
        seq.onModifiers([], at: 0.24, doubleTapFired: false)
        let cand = seq.consumeKeyDown(keyCode: 12, held: HeldModifiers(), at: 0.44)
        expectEqual(cand?.leader, .fn, "2nd tap without doubleTap refreshes leader window")
        expect(abs((cand?.elapsed ?? -1) - 0.20) < 0.001, "elapsed measured from 2nd release (200ms <= 250ms)")
    }

    do {
        var seq = SequenceDetector()
        seq.onModifiers([.capsLock], at: 0.00, doubleTapFired: false)
        seq.onModifiers([], at: 0.10, doubleTapFired: false)
        expectEqual(seq.consumeKeyDown(keyCode: 0, held: HeldModifiers(), at: 0.20)?.leader, .capsLock,
                    "capsLock tap + a triggers capsLock > a")

        // Pressing Caps Lock must disarm any earlier fn leader so holding Caps + q never fires fn > q.
        seq.onModifiers([.fn], at: 1.00, doubleTapFired: false)
        seq.onModifiers([], at: 1.06, doubleTapFired: false)
        seq.onModifiers([.capsLock], at: 1.12, doubleTapFired: false)
        expectNil(seq.consumeKeyDown(keyCode: 12, held: HeldModifiers(), at: 1.15),
                  "starting Caps Lock press disarms prior fn leader")
    }

    // 6. Sandboxed CLI tests for sequences & maxDoubleTapDelayMs / maxSequenceDelayMs
    var size: UInt32 = 0
    _NSGetExecutablePath(nil, &size)
    var buf = [CChar](repeating: 0, count: Int(size))
    _NSGetExecutablePath(&buf, &size)
    let selfURL = URL(fileURLWithPath: String(cString: buf)).resolvingSymlinksInPath()
    let cliURL = selfURL.deletingLastPathComponent().appendingPathComponent("hotkeyd")

    if FileManager.default.isExecutableFile(atPath: cliURL.path) {
        let sandbox = Paths.realHomeDirectory.appendingPathComponent(".hotkeyd-seq-cli-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: sandbox,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: sandbox) }

        func runCLI(_ args: String) -> ShellResult {
            ShellRunner.run(
                command: "HOTKEYD_HOME='\(sandbox.path)' '\(cliURL.path)' \(args)",
                cwd: sandbox.path,
                timeoutMilliseconds: 10_000
            )
        }

        let addSeq = runCLI("add 'fn > q' 'echo seq' --max-sequence-delay 400 --json")
        expectEqual(addSeq.exitCode, 0, "`hotkeyd add 'fn > q' ... --max-sequence-delay 400` exits 0")
        expect(addSeq.stdout.contains("\"keys\" : \"fn > q\""), "JSON output canonicalizes 'fn > q'")
        expect(addSeq.stdout.contains("\"maxSequenceDelayMs\" : 400"), "JSON output records maxSequenceDelayMs")

        let setSeq = runCLI("set 'rcmd > space' 'open ~' --json")
        expectEqual(setSeq.exitCode, 0, "`hotkeyd set 'rcmd > space' ...` exits 0")

        let rejectShift = runCLI("add 'shift > q' 'echo no' --json")
        expectEqual(rejectShift.exitCode, 4, "unsided 'shift > q' is rejected with exit 4")

        let rejectDoubleTapSeq = runCLI("add 'fn > w' --double-tap 'echo no' --json")
        expectEqual(rejectDoubleTapSeq.exitCode, 4, "--double-tap on sequence is rejected with exit 4")

        let rejectSeqDelayOnCombo = runCLI("add 'cmd+shift+c' 'echo no' --max-sequence-delay 400 --json")
        expectEqual(rejectSeqDelayOnCombo.exitCode, 2, "--max-sequence-delay on combo is rejected with exit 2")

        let rejectWindowOnSeq = runCLI("add 'fn > w' 'echo no' --window 400 --json")
        expectEqual(rejectWindowOnSeq.exitCode, 2, "--window on sequence is rejected with exit 2")

        let rejectBothDelays = runCLI("add lcmd --double-tap 'open -a Safari' --max-double-tap-delay 350 --window 350 --json")
        expectEqual(rejectBothDelays.exitCode, 2, "passing both --max-double-tap-delay and --window exits 2")

        let legacyWindowFlag = runCLI("add lcmd --double-tap 'open -a Safari' --window 350 --json")
        expectEqual(legacyWindowFlag.exitCode, 0, "legacy --window 350 is still accepted for --double-tap")
        let savedText = (try? String(contentsOf: sandbox.appendingPathComponent(".hotkeyd"), encoding: .utf8)) ?? ""
        expect(savedText.contains("\"maxDoubleTapDelayMs\": 350"), "legacy --window writes canonical maxDoubleTapDelayMs")
        expect(!savedText.contains("windowMs"), "saved .hotkeyd does not emit windowMs")

        let runSeq = runCLI("run 'fn>q' --wait --json")
        expectEqual(runSeq.exitCode, 0, "`hotkeyd run 'fn>q' --wait --json` exits 0")
        expect(runSeq.stdout.contains("\"stdout\" : \"seq\\n\""), "run 'fn>q' executes matched sequence command")

        let listOut = runCLI("list --json")
        expectEqual(listOut.exitCode, 0, "`hotkeyd list --json` exits 0 with sequences")

        let rmSeq = runCLI("rm 'FN > Q' --json")
        expectEqual(rmSeq.exitCode, 0, "`hotkeyd rm 'FN > Q' --json` removes 'fn > q'")

        // Removing only --double-tap from a paired entry must clear maxDoubleTapDelayMs so config stays valid.
        let addPaired = runCLI("add fn+escape --tap 'echo mute' --double-tap 'echo max' --max-double-tap-delay 350 --json")
        expectEqual(addPaired.exitCode, 0, "paired fn+escape with --max-double-tap-delay succeeds")
        let rmPairedDT = runCLI("rm fn+escape --double-tap --json")
        expectEqual(rmPairedDT.exitCode, 0, "removing only --double-tap from paired fn+escape succeeds")
        let postRmAdd = runCLI("add ropt 'echo ok' --json")
        expectEqual(postRmAdd.exitCode, 0, "config remains valid after removing --double-tap from paired entry")

        let schemaOut = runCLI("schema shortcut --json")
        expectEqual(schemaOut.exitCode, 0, "`hotkeyd schema shortcut --json` exits 0")
        expect(schemaOut.stdout.contains("maxDoubleTapDelayMs"), "CLI schema includes maxDoubleTapDelayMs")
        expect(schemaOut.stdout.contains("maxSequenceDelayMs"), "CLI schema includes maxSequenceDelayMs")

        let describeFile = sandbox.appendingPathComponent("describe-cli.json")
        let describeOut = runCLI("describe --json > '\(describeFile.path)'")
        expectEqual(describeOut.exitCode, 0, "`hotkeyd describe --json` exits 0")
        let fullDescribeText = (try? String(contentsOf: describeFile, encoding: .utf8)) ?? ""
        expect(fullDescribeText.contains("--max-sequence-delay"), "describe manifest documents --max-sequence-delay")
        expect(fullDescribeText.contains("\"init\""), "describe manifest documents init command")

        let addCapsCombo = runCLI("add capsLock+space 'echo lens' --allow-accessibility --json")
        expectEqual(addCapsCombo.exitCode, 0, "`hotkeyd add capsLock+space` exits 0")
        expect(addCapsCombo.stdout.contains("\"keys\" : \"capsLock+space\""), "capsLock+space canonicalizes in CLI JSON")
        let runCapsCombo = runCLI("run 'caps+space' --wait --json")
        expectEqual(runCapsCombo.exitCode, 0, "`hotkeyd run 'caps+space' --wait --json` exits 0")
        expect(runCapsCombo.stdout.contains("\"stdout\" : \"lens\\n\""), "run 'caps+space' executes capsLock+space")
        let rmCapsCombo = runCLI("rm capsLock+space --json")
        expectEqual(rmCapsCombo.exitCode, 0, "`hotkeyd rm capsLock+space --json` exits 0")
    }
}

// MARK: - SELECTED_TEXT extraction, sanitization & ShellRunner plumbing

func testSelectedText() {
    // 1. Trigger detection
    expect(
        SelectionReader.commandUsesSelectedText("printf '%s' \"$SELECTED_TEXT\" | pbcopy"),
        "commandUsesSelectedText detects $SELECTED_TEXT"
    )
    expect(
        SelectionReader.commandUsesSelectedText("q=\"${SELECTED_TEXT:-$(pbpaste)}\""),
        "commandUsesSelectedText detects ${SELECTED_TEXT:-...}"
    )
    expect(
        SelectionReader.commandUsesSelectedText("python3 -c 'import os; print(os.environ.get(\"SELECTED_TEXT\", \"\"))'"),
        "commandUsesSelectedText detects SELECTED_TEXT in inline script"
    )
    expect(
        !SelectionReader.commandUsesSelectedText("open -a Safari"),
        "commandUsesSelectedText is false for commands without SELECTED_TEXT"
    )
    expect(
        !SelectionReader.commandUsesSelectedText("printf '%s' \"$selected_text\""),
        "commandUsesSelectedText is case-sensitive"
    )

    // 2. Sanitization: exact whitespace/indentation/newlines, NUL stripping, and UTF-8 bounds
    let indented = "    if let x = foo() {\n\t\tprint(x)\n    }\n"
    expectEqual(
        SelectionReader.sanitize(indented),
        indented,
        "sanitize preserves leading spaces, tabs, internal newlines, and trailing newline"
    )
    expectEqual(
        SelectionReader.sanitize("   "),
        "   ",
        "sanitize preserves whitespace-only selection"
    )
    expectEqual(
        SelectionReader.sanitize("alpha\0beta\0gamma"),
        "alphabetagamma",
        "sanitize strips embedded NUL bytes"
    )
    expectEqual(SelectionReader.sanitize(""), "", "sanitize maps empty string to empty string")
    expectEqual(SelectionReader.sanitize("\0\0"), "", "sanitize maps NUL-only string to empty string")

    let oversizedASCII = String(repeating: "x", count: 300_000)
    let cappedASCII = SelectionReader.sanitize(oversizedASCII)
    expectEqual(
        cappedASCII.utf8.count,
        SelectionReader.maxSelectedTextUTF8Bytes,
        "sanitize caps oversized ASCII at 262,144 UTF-8 bytes"
    )

    let oversizedEmoji = String(repeating: "🚀", count: 70_000) // 280,000 UTF-8 bytes
    let cappedEmoji = SelectionReader.sanitize(oversizedEmoji)
    expectEqual(
        cappedEmoji.utf8.count,
        SelectionReader.maxSelectedTextUTF8Bytes,
        "sanitize caps 4-byte emoji string cleanly at 262,144 bytes"
    )
    expectEqual(cappedEmoji.count, 65_536, "capped emoji string has 65,536 intact 🚀 characters")

    expectEqual(
        SelectionReader.sanitize("a🚀🚀", maxUTF8Bytes: 6),
        "a🚀",
        "sanitize never splits a 4-byte UTF-8 scalar across maxUTF8Bytes"
    )
    expectEqual(
        SelectionReader.sanitize("a👨‍👩‍👧‍👦", maxUTF8Bytes: 10),
        "a",
        "sanitize never tears a multi-scalar ZWJ grapheme cluster"
    )
    let combiningBomb = "e" + String(repeating: "\u{0301}", count: 200)
    let cappedCombining = SelectionReader.sanitize(combiningBomb, maxUTF8Bytes: 25)
    expect(
        !cappedCombining.isEmpty && cappedCombining.utf8.count <= 25,
        "sanitize falls back to scalar boundary when a single grapheme exceeds maxUTF8Bytes"
    )

    // 3. Target safety guards (never self-probe daemon PID or invalid PID)
    expectEqual(
        SelectionReader.readSelectedText(
            target: SelectionReader.TargetApp(pid: getpid(), bundleIdentifier: "io.github.jardondiego.hotkeyd")
        ),
        "",
        "readSelectedText never self-probes hotkeyd's own PID"
    )
    expectEqual(
        SelectionReader.readSelectedText(target: SelectionReader.TargetApp(pid: -1, bundleIdentifier: nil)),
        "",
        "readSelectedText returns empty string for non-positive PID"
    )

    // 4. ShellRunner environment & execution plumbing
    let envDefault = ShellRunner.scrubbedEnvironment(allowAccessibility: false)
    expect(
        !envDefault.contains(where: { $0.hasPrefix("SELECTED_TEXT=") }),
        "scrubbedEnvironment omits SELECTED_TEXT when selectedText is nil"
    )
    let envEmpty = ShellRunner.scrubbedEnvironment(allowAccessibility: false, selectedText: "")
    expect(
        envEmpty.contains("SELECTED_TEXT="),
        "scrubbedEnvironment exports SELECTED_TEXT= when selectedText is empty"
    )
    let envNul = ShellRunner.scrubbedEnvironment(allowAccessibility: false, selectedText: "hi\0there")
    expect(
        envNul.contains("SELECTED_TEXT=hithere"),
        "scrubbedEnvironment sanitizes embedded NUL bytes in SELECTED_TEXT"
    )

    let prevSelectedText = getenv("SELECTED_TEXT").map { String(cString: $0) }
    defer {
        if let prevSelectedText {
            setenv("SELECTED_TEXT", prevSelectedText, 1)
        } else {
            unsetenv("SELECTED_TEXT")
        }
    }
    setenv("SELECTED_TEXT", "parent-leaked-value", 1)

    let unsetCheck = ShellRunner.run(
        command: "/usr/bin/env",
        cwd: "/tmp",
        timeoutMilliseconds: 5_000,
        allowAccessibility: false
    )
    expectEqual(unsetCheck.exitCode, 0, "command without SELECTED_TEXT exits 0")
    expect(
        !unsetCheck.stdout.contains("SELECTED_TEXT="),
        "command without SELECTED_TEXT leaves SELECTED_TEXT unset and scrubs parent env"
    )

    let outFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("hotkeyd-sel-\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: outFile) }

    let exactSample = "  func greet() {\n      print(\"hello $USER\")\n  }\n"
    let exactRun = ShellRunner.run(
        command: "printf '%s' \"$SELECTED_TEXT\" > '\(outFile.path)'",
        cwd: "/tmp",
        timeoutMilliseconds: 5_000,
        allowAccessibility: false,
        selectedTextOverride: exactSample
    )
    expectEqual(exactRun.exitCode, 0, "ShellRunner.run with multiline indented SELECTED_TEXT exits 0")
    let writtenSample = (try? String(contentsOf: outFile, encoding: .utf8)) ?? ""
    expectEqual(
        writtenSample,
        exactSample,
        "child shell receives exact SELECTED_TEXT without shell expansion or whitespace trimming"
    )

    let emptyOverrideRun = ShellRunner.run(
        command: "printf '%s:%d' \"${SELECTED_TEXT+set}\" \"${#SELECTED_TEXT}\"",
        cwd: "/tmp",
        timeoutMilliseconds: 5_000,
        allowAccessibility: false,
        selectedTextOverride: ""
    )
    expectEqual(emptyOverrideRun.exitCode, 0, "empty SELECTED_TEXT override exits 0")
    expectEqual(emptyOverrideRun.stdout, "set:0", "empty SELECTED_TEXT is defined with length 0")

    let largeOverrideRun = ShellRunner.run(
        command: "printf '%s' \"$SELECTED_TEXT\" | /usr/bin/wc -c | /usr/bin/tr -d ' \\n'",
        cwd: "/tmp",
        timeoutMilliseconds: 10_000,
        allowAccessibility: false,
        selectedTextOverride: oversizedASCII
    )
    expectEqual(largeOverrideRun.exitCode, 0, "300 KiB SELECTED_TEXT spawns /bin/zsh without E2BIG")
    expectEqual(
        largeOverrideRun.stdout,
        String(SelectionReader.maxSelectedTextUTF8Bytes),
        "oversized SELECTED_TEXT arrives in /bin/zsh capped at 262,144 bytes"
    )

    // 5. CommandRegistry & JSON Schema documentation
    let manifest = CommandRegistry.manifest(
        version: "0.1.0-dev",
        configPath: "/Users/test/.hotkeyd",
        logsPath: "/Users/test/Library/Application Support/Hotkeyd/logs",
        launchAgentPath: "/Users/test/Library/LaunchAgents/io.github.jardondiego.hotkeyd.daemon.plist"
    )
    expect(
        manifest.conventions.env["SELECTED_TEXT"] != nil,
        "CommandRegistry manifest documents SELECTED_TEXT in conventions.env"
    )
}

// MARK: - App Resolution (including nested Chrome PWAs & fallback)

func testAppResolution() {
    let fm = FileManager.default
    let workDir = fm.temporaryDirectory.appendingPathComponent("hotkeyd-app-res-\(UUID().uuidString)")
    let rootA = workDir.appendingPathComponent("SysApps", isDirectory: true)
    let rootB = workDir.appendingPathComponent("UserApps", isDirectory: true)
    let chromeApps = rootB.appendingPathComponent("Chrome Apps.localized", isDirectory: true)
    let deepDir = rootB.appendingPathComponent("Outer/Inner", isDirectory: true)
    let hiddenDir = rootB.appendingPathComponent(".Hidden", isDirectory: true)
    let insideBundleDir = rootB.appendingPathComponent("Wrapper.app/Contents/Resources", isDirectory: true)

    do {
        for dir in [
            rootA.appendingPathComponent("TopApp.app", isDirectory: true),
            rootA.appendingPathComponent("Shadowed.app", isDirectory: true),
            chromeApps.appendingPathComponent("TIDAL.app", isDirectory: true),
            chromeApps.appendingPathComponent("Google Calendar.app", isDirectory: true),
            chromeApps.appendingPathComponent("Shadowed.app", isDirectory: true),
            deepDir.appendingPathComponent("DeepApp.app", isDirectory: true),
            hiddenDir.appendingPathComponent("Secret.app", isDirectory: true),
            insideBundleDir.appendingPathComponent("NestedInsideApp.app", isDirectory: true)
        ] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        defer { try? fm.removeItem(at: workDir) }

        let roots = [rootA.path, rootB.path]
        expectEqual(
            ShellRunner.resolveApplicationURL(for: "TopApp", searchRoots: roots)?.path,
            rootA.appendingPathComponent("TopApp.app").standardizedFileURL.path,
            "resolveApplicationURL finds top-level .app"
        )
        expectEqual(
            ShellRunner.resolveApplicationURL(for: "TIDAL", searchRoots: roots)?.path,
            chromeApps.appendingPathComponent("TIDAL.app").standardizedFileURL.path,
            "resolveApplicationURL finds Chrome PWA inside Chrome Apps.localized"
        )
        expectEqual(
            ShellRunner.resolveApplicationURL(for: "google calendar", searchRoots: roots)?.path,
            chromeApps.appendingPathComponent("Google Calendar.app").standardizedFileURL.path,
            "resolveApplicationURL matches nested Chrome PWA case-insensitively"
        )
        expectEqual(
            ShellRunner.resolveApplicationURL(for: "DeepApp.app", searchRoots: roots)?.path,
            deepDir.appendingPathComponent("DeepApp.app").standardizedFileURL.path,
            "resolveApplicationURL finds depth-2 nested .app"
        )
        expectEqual(
            ShellRunner.resolveApplicationURL(for: "Shadowed", searchRoots: roots)?.path,
            rootA.appendingPathComponent("Shadowed.app").standardizedFileURL.path,
            "resolveApplicationURL prefers depth-0 match ahead of nested duplicate"
        )
        expectNil(
            ShellRunner.resolveApplicationURL(for: "Secret", searchRoots: roots),
            "resolveApplicationURL skips dot-prefixed hidden directories"
        )
        expectNil(
            ShellRunner.resolveApplicationURL(for: "NestedInsideApp", searchRoots: roots),
            "resolveApplicationURL does not descend inside .app bundles"
        )

        let missingPathRes = ShellRunner.runApp(target: workDir.appendingPathComponent("NoSuchApp.app").path)
        expectEqual(missingPathRes.exitCode, 1, "runApp fails with exit 1 on missing explicit .app path")

        let missingNameRes = ShellRunner.runApp(target: "HotkeydDefinitelyMissingApp\(UUID().uuidString)")
        expectEqual(missingNameRes.exitCode, 1, "runApp /usr/bin/open fallback returns exit 1 on missing app name")
    } catch {
        expect(false, "testAppResolution setup threw: \(error)")
    }
}

// MARK: - Critical & High Security Audit Regression Suite

func testCriticalAndHighSecurityFixes() {
    let fm = FileManager.default

    var pathSize: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &pathSize)
    var pathBuf = [CChar](repeating: 0, count: Int(pathSize))
    _ = _NSGetExecutablePath(&pathBuf, &pathSize)
    let selfExecURL = URL(fileURLWithPath: String(cString: pathBuf)).resolvingSymlinksInPath()
    let cliExecURL = selfExecURL.deletingLastPathComponent().appendingPathComponent("hotkeyd")

    // 1. [C-01 / H-02 CodeTrust] Mach-O __TEXT page-hash validation, expanded entitlement denylist,
    //    disjunctive requirement rejection, and in-memory verifyCurrentProcess check.
    expectThrows("verifyCurrentProcess rejects debug selftest binary") {
        try CodeTrust.verifyCurrentProcess(allowAdhoc: true)
    }

    do {
        let workDir = fm.temporaryDirectory.appendingPathComponent("hotkeyd-sec-audit-\(UUID().uuidString)")
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: workDir) }

        if fm.isExecutableFile(atPath: cliExecURL.path) {
            let signedCopy = workDir.appendingPathComponent("tamper-target")
            try fm.copyItem(at: cliExecURL, to: signedCopy)
            let signRes = ShellRunner.run(
                command: "/usr/bin/codesign --force --sign - --options runtime --identifier io.github.jardondiego.hotkeyd '\(signedCopy.path)'",
                cwd: workDir.path,
                timeoutMilliseconds: 10_000
            )
            expectEqual(signRes.exitCode, 0, "ad-hoc runtime signing of tamper-target succeeds")
            _ = try CodeTrust.verify(binaryPath: signedCopy.path, allowAdhoc: true)
            expect(true, "untampered signed copy passes CodeTrust.verify(allowAdhoc: true)")

            let signedSleep = workDir.appendingPathComponent("signed-sleep")
            try fm.copyItem(atPath: "/bin/sleep", toPath: signedSleep.path)
            let signSleepRes = ShellRunner.run(
                command: "/usr/bin/codesign --force --sign - --options runtime --identifier io.github.jardondiego.hotkeyd '\(signedSleep.path)'",
                cwd: workDir.path,
                timeoutMilliseconds: 10_000
            )
            expectEqual(signSleepRes.exitCode, 0, "ad-hoc runtime signing of signed-sleep succeeds")
            let sleepSpawn = ShellRunner.spawnProcess(
                executablePath: signedSleep.path,
                arguments: [signedSleep.path, "2"],
                environment: ["PATH=/usr/bin:/bin"],
                workingDirectory: workDir.path
            )
            if case .success(let sleepPID) = sleepSpawn {
                defer {
                    _ = kill(sleepPID, SIGKILL)
                    var st: Int32 = 0
                    _ = waitpid(sleepPID, &st, 0)
                }
                let liveReport = try CodeTrust.verifyRunningProcess(pid: sleepPID, allowAdhoc: true)
                expectEqual(liveReport.identifier, "io.github.jardondiego.hotkeyd", "verifyRunningProcess accepts valid signed CS_RUNTIME process")
                expect(liveReport.hasHardenedRuntime, "verifyRunningProcess confirms CS_RUNTIME on live signed process")
            } else {
                expect(false, "failed to spawn signed-sleep for live CodeTrust test")
            }

            var binaryData = try Data(contentsOf: signedCopy)
            let needle = Data("unknown command".utf8)
            if let range = binaryData.range(of: needle) {
                binaryData[range.lowerBound] = UInt8(ascii: "U")
                try binaryData.write(to: signedCopy)
                expectThrows("Mach-O __TEXT byte tamper is caught by kSecCSStrictValidate") {
                    try CodeTrust.verify(binaryPath: signedCopy.path, allowAdhoc: true)
                }
            } else {
                expect(false, "expected 'unknown command' string in __TEXT,__cstring of hotkeyd binary")
            }
        }

        let dummyBin = workDir.appendingPathComponent("ent-target")
        try fm.copyItem(atPath: "/usr/bin/true", toPath: dummyBin.path)

        let deniedEntitlements = [
            "com.apple.security.cs.disable-executable-page-protection",
            "com.apple.security.cs.allow-jit",
            "com.apple.security.cs.debugger",
            "com.apple.private.tcc.allow",
            "com.example.unexpected-entitlement"
        ]
        for entKey in deniedEntitlements {
            let entFile = workDir.appendingPathComponent("ent-\(UUID().uuidString).plist")
            let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>\(entKey)</key>
                <true/>
            </dict>
            </plist>
            """
            try Data(xml.utf8).write(to: entFile)
            let res = ShellRunner.run(
                command: "/usr/bin/codesign --force --sign - --options runtime --entitlements '\(entFile.path)' --identifier io.github.jardondiego.hotkeyd '\(dummyBin.path)'",
                cwd: workDir.path,
                timeoutMilliseconds: 10_000
            )
            expectEqual(res.exitCode, 0, "codesign with entitlement \(entKey) succeeds")
            expectThrows("CodeTrust rejects entitlement \(entKey)") {
                try CodeTrust.verify(binaryPath: dummyBin.path, allowAdhoc: true)
            }
        }

        let disjunctiveSign = ShellRunner.run(
            command: "/usr/bin/codesign --force --sign - --options runtime --identifier io.github.jardondiego.hotkeyd --requirements '=designated => identifier \"io.github.jardondiego.hotkeyd\" or certificate leaf = H\"0000000000000000000000000000000000000000\"' '\(dummyBin.path)'",
            cwd: workDir.path,
            timeoutMilliseconds: 10_000
        )
        expectEqual(disjunctiveSign.exitCode, 0, "codesign with disjunctive requirement succeeds")
        expectThrows("CodeTrust rejects disjunctive 'or' designated requirement when allowAdhoc == false") {
            try CodeTrust.verify(binaryPath: dummyBin.path, allowAdhoc: false)
        }
    } catch {
        expect(false, "CodeTrust tamper/entitlement regression test threw: \(error)")
    }

    // 2. [C-02] TCC delegation & SELECTED_TEXT live probe blocked under HOTKEYD_HOME or disallowAccessibilityDelegation
    do {
        let prevKH = getenv("HOTKEYD_HOME").map { String(cString: $0) }
        let prevIgnore = Paths.ignoreEnvironmentOverride
        let prevDisallow = ShellRunner.disallowAccessibilityDelegation
        defer {
            Paths.ignoreEnvironmentOverride = prevIgnore
            ShellRunner.disallowAccessibilityDelegation = prevDisallow
            if let prevKH { setenv("HOTKEYD_HOME", prevKH, 1) } else { unsetenv("HOTKEYD_HOME") }
        }

        let khDir = fm.temporaryDirectory.appendingPathComponent("hotkeyd-kh-\(UUID().uuidString)")
        try fm.createDirectory(at: khDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: khDir) }

        Paths.ignoreEnvironmentOverride = false
        ShellRunner.disallowAccessibilityDelegation = false
        setenv("HOTKEYD_HOME", khDir.path, 1)

        expect(!ShellRunner.canDelegateAccessibility(true), "HOTKEYD_HOME disables Accessibility TCC delegation")

        let pidFile = khDir.appendingPathComponent("child.pid")
        let doneSem = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = ShellRunner.run(
                command: "echo $$ > '\(pidFile.path)'; /bin/sleep 0.35",
                cwd: khDir.path,
                timeoutMilliseconds: 5_000,
                allowAccessibility: true
            )
            doneSem.signal()
        }
        var childPID: pid_t = -1
        for _ in 0..<40 {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
               let parsed = pid_t(text), parsed > 1 {
                childPID = parsed
                break
            }
            usleep(15_000)
        }
        expect(childPID > 1, "spawned child wrote PID under HOTKEYD_HOME")
        if childPID > 1 {
            expectEqual(
                ShellRunner.responsiblePID(for: childPID),
                childPID,
                "allowAccessibility: true still disclaims TCC responsibility when HOTKEYD_HOME is active"
            )
        }
        _ = doneSem.wait(timeout: .now() + 5.0)

        unsetenv("HOTKEYD_HOME")
        Paths.ignoreEnvironmentOverride = true
        ShellRunner.disallowAccessibilityDelegation = true
        expect(!ShellRunner.canDelegateAccessibility(true), "disallowAccessibilityDelegation blocks TCC delegation")
    } catch {
        expect(false, "HOTKEYD_HOME TCC disclaim regression test threw: \(error)")
    }

    // 3. [C-03] Action shell quoting, migratedFromShellCommand single-quote round-trip, & openPath hardening
    do {
        let queryURL = "https://example.com/search?q=hello+world&lang=en;v=2"
        let urlAction = Action.url(queryURL)
        expectEqual(
            urlAction.shellCommandString,
            "open 'https://example.com/search?q=hello+world&lang=en;v=2'",
            "Action.url single-quotes query URLs containing ? & ;"
        )
        expectEqual(
            Action.migratedFromShellCommand(urlAction.shellCommandString),
            urlAction,
            "single-quoted query URL round-trips back to .url for NSWorkspace fast-path"
        )

        let trickyApp = Action.app(
            target: "MyApp\"; touch /tmp/hotkeyd-never; #",
            arguments: ["$(id)", "`whoami`", "it's fine"]
        )
        expectEqual(
            Action.migratedFromShellCommand(trickyApp.shellCommandString),
            trickyApp,
            "Action.app with quotes, $, backticks, semicolons, and apostrophes round-trips losslessly"
        )

        let canary = fm.temporaryDirectory.appendingPathComponent("hotkeyd-inj-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: canary) }
        let injShortcut = Shortcut(
            id: "inj1",
            name: "inj",
            trigger: .doubleTap(modifier: .leftCommand, windowMilliseconds: nil),
            action: .app(target: "NoSuchApp; /usr/bin/touch '\(canary.path)'", arguments: ["$(/usr/bin/touch '\(canary.path)')"])
        )
        _ = ShellRunner.execute(action: injShortcut.activeAction, allowAccessibility: false)
        expect(!fm.fileExists(atPath: canary.path), "Action.app metacharacters never execute in /bin/zsh")

        let openDash = ShellRunner.execute(action: .openPath("-a Calculator"), allowAccessibility: false)
        expectEqual(openDash.exitCode, 1, "Action.openPath rejects leading '-' option injection")
        let openNewline = ShellRunner.execute(action: .openPath("/tmp/foo\n/usr/bin/touch '\(canary.path)'"), allowAccessibility: false)
        expectEqual(openNewline.exitCode, 1, "Action.openPath rejects embedded newlines without invoking /bin/zsh")
        expect(!fm.fileExists(atPath: canary.path), "Action.openPath newline payload never executes")

        expectThrows("JSONDecoder rejects Action.open with leading '-'") {
            let badOpen = """
            {"version":1,"shortcuts":[{"id":"o","name":"bad","enabled":true,
             "trigger":{"type":"doubleTap","modifier":"cmd"},
             "action":{"type":"open","path":"-a Safari"}}]}
            """
            return try JSONDecoder().decode(Config.self, from: Data(badOpen.utf8))
        }

        expectThrows("Config.validate rejects NUL byte in tap command") {
            let cfg = Config(shortcuts: [Shortcut(keys: .combo(try KeyCombo.parse("fn+space")), tap: "echo hi\0rm")])
            try cfg.validate()
        }
        expectThrows("Config.validate rejects NUL byte in shortcut name") {
            let cfg = Config(shortcuts: [Shortcut(keys: .modifier(.leftCommand), doubleTap: "true", name: "bad\0name")])
            try cfg.validate()
        }

        let nulSpawn = ShellRunner.spawnProcess(
            executablePath: "/bin/echo",
            arguments: ["/bin/echo", "bad\0arg"],
            environment: ["PATH=/usr/bin:/bin"],
            workingDirectory: "/"
        )
        if case .failure(let err) = nulSpawn {
            expectEqual(err.errnoCode, EINVAL, "spawnProcess rejects embedded NUL bytes with EINVAL")
        } else {
            expect(false, "spawnProcess must fail on embedded NUL bytes")
        }
    } catch {
        expect(false, "Action quoting / openPath regression test threw: \(error)")
    }

    // 4. [H-01 & H-03] runOpenDirectory rejects .app/.pkg/.workflow bundles & symlinks; resolveApplicationURL rejects user symlinks
    do {
        let dir = fm.temporaryDirectory.appendingPathComponent("hotkeyd-pkg-sym-\(UUID().uuidString)")
        let realFolder = dir.appendingPathComponent("PlainFolder", isDirectory: true)
        let fakeApp = dir.appendingPathComponent("Disguised.app", isDirectory: true)
        let fakePkg = dir.appendingPathComponent("Disguised.pkg", isDirectory: true)
        let fakeWorkflow = dir.appendingPathComponent("Disguised.workflow", isDirectory: true)
        try fm.createDirectory(at: realFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: fakeApp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: fakePkg, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: fakeWorkflow, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: dir) }

        let folderSymlink = dir.appendingPathComponent("FolderLink")
        _ = symlink(realFolder.path, folderSymlink.path)

        let appSymlink = dir.appendingPathComponent("Hijack.app")
        _ = symlink(fakeApp.path, appSymlink.path)

        expectNil(ShellRunner.runOpenDirectory(fakeApp.path), "runOpenDirectory refuses .app bundle directories")
        expectNil(ShellRunner.runOpenDirectory(fakePkg.path), "runOpenDirectory refuses .pkg bundle directories")
        expectNil(ShellRunner.runOpenDirectory(fakeWorkflow.path), "runOpenDirectory refuses .workflow bundle directories")
        expectNil(ShellRunner.runOpenDirectory(folderSymlink.path), "runOpenDirectory refuses symlinked directories")

        expectNil(
            ShellRunner.resolveApplicationURL(for: "Hijack", searchRoots: [dir.path]),
            "resolveApplicationURL rejects user-owned symlinked .app bundles"
        )
    } catch {
        expect(false, "bundle / symlink rejection test threw: \(error)")
    }

    // 5. [H-05 & M-01/M-02] StrictModes traversal/tmp rejection, Config ancestor check, Log 0600/ANSI/O_NOFOLLOW, & CLI sticky flags
    for badPath in ["/..", "/Users/../etc/passwd", "/./Users", "/tmp", "/private/tmp", "/var/tmp", "/private/var/tmp"] {
        expectThrows("StrictModes.verifySecurePath rejects '\(badPath)'") {
            try StrictModes.verifySecurePath(badPath, expectRegularFile: false)
        }
    }
    expectNil(Paths.resolveWorkingDirectory("~/../etc"), "Paths.resolveWorkingDirectory rejects '..' traversal")
    expectNil(Paths.resolveWorkingDirectory("/Users/./Shared"), "Paths.resolveWorkingDirectory rejects '.' segment")

    do {
        let prevIgnore = Paths.ignoreEnvironmentOverride
        defer { Paths.ignoreEnvironmentOverride = prevIgnore }
        Paths.ignoreEnvironmentOverride = true

        let tmpSub = URL(fileURLWithPath: "/private/tmp/hotkeyd-untrusted-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmpSub, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: tmpSub) }
        let tmpCfg = tmpSub.appendingPathComponent(".hotkeyd")
        try Data("{\"shortcuts\":[]}\n".utf8).write(to: tmpCfg)
        _ = chmod(tmpCfg.path, 0o600)

        expectThrows("Config.load rejects config under world-writable /private/tmp ancestor when HOTKEYD_HOME is inactive") {
            try Config.load(from: tmpCfg)
        }
    } catch {
        expect(false, "Config.load /private/tmp ancestor rejection test threw: \(error)")
    }

    do {
        let prevKH = getenv("HOTKEYD_HOME").map { String(cString: $0) }
        let prevIgnore = Paths.ignoreEnvironmentOverride
        defer {
            Paths.ignoreEnvironmentOverride = prevIgnore
            if let prevKH { setenv("HOTKEYD_HOME", prevKH, 1) } else { unsetenv("HOTKEYD_HOME") }
        }
        let logHome = fm.temporaryDirectory.appendingPathComponent("hotkeyd-log-sec-\(UUID().uuidString)")
        try fm.createDirectory(at: logHome, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: logHome) }

        Paths.ignoreEnvironmentOverride = false
        setenv("HOTKEYD_HOME", logHome.path, 1)

        Log.action("hello \u{1B}[31mred\u{1B}[0m\rworld")
        Log.flush()

        var st = stat()
        expectEqual(lstat(Paths.actionLog.path, &st), 0, "actions.log created")
        expectEqual(st.st_mode & 0o777, 0o600, "actions.log has strict 0600 permissions")
        let logContents = (try? String(contentsOf: Paths.actionLog, encoding: .utf8)) ?? ""
        expect(!logContents.contains("\u{1B}"), "Log strips ESC control bytes")
        expect(!logContents.contains("\r"), "Log strips carriage-return log-spoofing bytes")

        let canaryTarget = logHome.appendingPathComponent("symlink-target.txt")
        try Data("untouched".utf8).write(to: canaryTarget)
        try fm.removeItem(at: Paths.actionLog)
        _ = symlink(canaryTarget.path, Paths.actionLog.path)
        Log.action("must-not-follow-symlink")
        Log.flush()
        expectEqual(
            (try? String(contentsOf: canaryTarget, encoding: .utf8)) ?? "",
            "untouched",
            "Log.append O_NOFOLLOW refuses to write through symlinked actions.log"
        )
    } catch {
        expect(false, "Log 0600 / ANSI / O_NOFOLLOW regression test threw: \(error)")
    }

    if fm.isExecutableFile(atPath: cliExecURL.path) {
        let sandbox = Paths.realHomeDirectory.appendingPathComponent(".hotkeyd-sec-cli-\(UUID().uuidString)")
        try? fm.createDirectory(at: sandbox, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: sandbox) }

        func runCLI(_ args: String) -> ShellResult {
            ShellRunner.run(
                command: "HOTKEYD_HOME='\(sandbox.path)' '\(cliExecURL.path)' \(args)",
                cwd: sandbox.path,
                timeoutMilliseconds: 10_000
            )
        }

        let addPriv = runCLI("add fn+f12 'echo old' --allow-accessibility --pass-through --json")
        expectEqual(addPriv.exitCode, 0, "add fn+f12 with --allow-accessibility --pass-through succeeds")
        let beforeOverwrite = (try? String(contentsOf: sandbox.appendingPathComponent(".hotkeyd"), encoding: .utf8)) ?? ""
        expect(beforeOverwrite.contains("\"allowAccessibility\": true"), "initial shortcut stores allowAccessibility: true")
        expect(beforeOverwrite.contains("\"passThrough\": true"), "initial shortcut stores passThrough: true")

        let overwriteUnpriv = runCLI("set fn+f12 'echo safe' --json")
        expectEqual(overwriteUnpriv.exitCode, 0, "hotkeyd set fn+f12 without --allow-accessibility succeeds")
        let afterOverwrite = (try? String(contentsOf: sandbox.appendingPathComponent(".hotkeyd"), encoding: .utf8)) ?? ""
        expect(!afterOverwrite.contains("allowAccessibility"), "hotkeyd set clears sticky allowAccessibility when replacing all slots")
        expect(!afterOverwrite.contains("passThrough"), "hotkeyd set clears sticky passThrough when replacing all slots")

        _ = runCLI("set fn+f12 --tap 'echo a' --double-tap 'echo b' --allow-accessibility --json")
        let revokeFlag = runCLI("set fn+f12 --tap 'echo a2' --no-allow-accessibility --json")
        expectEqual(revokeFlag.exitCode, 0, "--no-allow-accessibility flag succeeds on partial slot update")
        let afterRevoke = (try? String(contentsOf: sandbox.appendingPathComponent(".hotkeyd"), encoding: .utf8)) ?? ""
        expect(!afterRevoke.contains("allowAccessibility"), "--no-allow-accessibility explicitly revokes allowAccessibility")

        let rejectDaemonConfig = runCLI("daemon run --config '\(sandbox.path)/.hotkeyd'")
        expectEqual(rejectDaemonConfig.exitCode, 2, "daemon run rejects removed --config flag with exit 2")

        let rejectStopInSandbox = runCLI("daemon stop --json")
        expectEqual(rejectStopInSandbox.exitCode, 6, "daemon stop refuses to touch live LaunchAgent when HOTKEYD_HOME is set")

        let rejectPanicInSandbox = runCLI("panic --json")
        expectEqual(rejectPanicInSandbox.exitCode, 6, "panic refuses to touch live LaunchAgent when HOTKEYD_HOME is set")
    }
}

// MARK: - UX, Runtime Hygiene & Agent Contract Regression Suite

func testUXAndAgentContractFixes() {
    let fm = FileManager.default

    // 1. Modifier aliases, KeyCodes.isFunctionKey(117) fix, ISO section key, shell-safe `:` sequence alias
    expectEqual(Modifier.parse("globe"), .fn, "Modifier.parse accepts 'globe'")
    expectEqual(Modifier.parse("🌐"), .fn, "Modifier.parse accepts '🌐'")
    expect(!KeyCodes.isFunctionKey(117), "forwarddelete (117) is NOT classified as a function key")
    expect(KeyCodes.isFunctionKey(122), "f1 (122) is a function key")
    expect(KeyCodes.isFunctionKey(79), "f18 (79) is a function key")
    expect(KeyCodes.isFunctionKey(90), "f20 (90) is a function key")
    expectThrows("bare forwarddelete is rejected") { try KeyCombo.parse("forwarddelete") }
    expectThrows("shift+forwarddelete is rejected") { try KeyCombo.parse("shift+forwarddelete") }
    do {
        expectEqual(try KeyCombo.parse("cmd+§").canonical, "cmd+section", "ISO § key parses to canonical 'section'")
        expectEqual(try KeyTarget.parse("fn:q").canonical, "fn > q", "shell-safe fn:q parses to 'fn > q'")
        expectEqual(try KeyTarget.parse("rcmd:space").canonical, "rcmd > space", "shell-safe rcmd:space parses to 'rcmd > space'")
        expectEqual(try KeyTarget.parse("capsLock:o").canonical, "capsLock > o", "shell-safe capsLock:o parses to 'capsLock > o'")
        expectEqual(try KeyTarget.parse("fn:,").canonical, "fn > comma", "shell-safe fn:, parses to 'fn > comma'")
    } catch {
        expect(false, "ISO section / shell-safe sequence parse threw: \(error)")
    }

    // 2. HeldModifiers: direct fn flag tracking + physicalFnDown survival across synthetic CGEvents
    do {
        var held = HeldModifiers()
        held.update(keyCode: 63, flags: .maskSecondaryFn)
        expectEqual(held.keys, [.fn], "fn flagsChanged down sets .fn")
        // Duplicate down event does NOT toggle .fn off
        held.update(keyCode: 63, flags: .maskSecondaryFn)
        expectEqual(held.keys, [.fn], "duplicate fn flagsChanged with maskSecondaryFn stays .fn (no toggle inversion)")
        // Synthetic CGEvent omitting maskSecondaryFn while physical Fn is still down preserves .fn
        held.reconcile(with: [.maskCommand, .maskShift], physicalFnDown: true)
        expect(held.keys.contains(.fn), "physicalFnDown preserves .fn across synthetic CGEvents")
        // Once physical Fn is released and flags lack maskSecondaryFn, .fn clears
        held.reconcile(with: [], physicalFnDown: false)
        expect(!held.keys.contains(.fn), ".fn clears when physicalFnDown is false and flag is absent")
    }

    // 3. Config name-vs-keys collision, rolloverWarnings, and detailed JSON error reporting
    do {
        let collision = Config(shortcuts: [
            Shortcut(keys: .combo(try KeyCombo.parse("fn+space")), tap: "true", name: "Shot"),
            Shortcut(keys: .modifier(.leftCommand), doubleTap: "true", name: "fn+space")
        ])
        expectThrows("Config.validate rejects shortcut name colliding with another shortcut's keys") {
            try collision.validate()
        }

        let rollover = Config(shortcuts: [
            Shortcut(keys: .combo(try KeyCombo.parse("fn+q")), tap: "echo combo", name: "Combo Q"),
            Shortcut(keys: .sequence(try KeySequence.parse("fn > q")), tap: "echo seq", name: "Seq Q")
        ])
        try rollover.validate()
        let warnings = rollover.rolloverWarnings()
        expectEqual(warnings.count, 1, "rolloverWarnings detects fn+q vs fn > q overlap")

        let dir = fm.temporaryDirectory.appendingPathComponent("hotkeyd-json-err-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: dir) }
        let badCfg = dir.appendingPathComponent(".hotkeyd")
        try Data("{\n  \"shortcuts\": [\n    { \"keys\": \"lcmd\" \"doubleTap\": \"true\" }\n  ]\n}\n".utf8).write(to: badCfg)
        _ = chmod(badCfg.path, 0o600)
        let prevKH = getenv("HOTKEYD_HOME").map { String(cString: $0) }
        let prevIgnore = Paths.ignoreEnvironmentOverride
        defer {
            Paths.ignoreEnvironmentOverride = prevIgnore
            if let prevKH { setenv("HOTKEYD_HOME", prevKH, 1) } else { unsetenv("HOTKEYD_HOME") }
        }
        Paths.ignoreEnvironmentOverride = false
        setenv("HOTKEYD_HOME", dir.path, 1)
        do {
            _ = try Config.load(from: badCfg)
            expect(false, "malformed JSON should fail to load")
        } catch {
            expect(
                error.localizedDescription.contains("line") || error.localizedDescription.contains("Expected") || error.localizedDescription.contains("corrupted"),
                "Config.describe includes actionable syntax/line detail: \(error.localizedDescription)"
            )
        }
    } catch {
        expect(false, "Config UX tests threw: \(error)")
    }

    // 4. RuntimeState atomic 0600 save/load/remove and permission enforcement
    do {
        let dir = Paths.realHomeDirectory.appendingPathComponent(".hotkeyd-rt-test-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: dir) }
        let stateURL = dir.appendingPathComponent("runtime-state.json")
        let snap = RuntimeState(
            pid: getpid(),
            startedAt: RuntimeState.timestamp(),
            updatedAt: RuntimeState.timestamp(),
            binaryPath: "/Users/test/.local/bin/hotkeyd",
            configPath: "/Users/test/.hotkeyd",
            tapActive: true,
            tapNote: "listening for shortcuts",
            secureInputActive: false,
            capsRemapped: true,
            activeBindings: 29,
            configValid: true,
            configError: nil
        )
        try snap.save(to: stateURL)
        var st = stat()
        expectEqual(lstat(stateURL.path, &st), 0, "runtime-state.json exists")
        expectEqual(st.st_mode & 0o777, 0o600, "runtime-state.json has mode 0600")
        expectEqual(RuntimeState.load(from: stateURL), snap, "RuntimeState round-trips losslessly")
        _ = chmod(stateURL.path, 0o644)
        expectNil(RuntimeState.load(from: stateURL), "RuntimeState.load refuses world/group-readable 0644 file")
        RuntimeState.remove(at: stateURL)
        expect(!fm.fileExists(atPath: stateURL.path), "RuntimeState.remove unlinks state file")
    } catch {
        expect(false, "RuntimeState test threw: \(error)")
    }

    // 5. ShellRunner: post-exit pipe drain timeout prevents worker-slot leak; native fast-path exempt; SELECTED_TEXT_STATUS
    do {
        let start = CFAbsoluteTimeGetCurrent()
        // Detached grandchild keeps stdout open for 15s, but parent shell exits immediately.
        let res = ShellRunner.run(
            command: "echo ready; (/bin/sleep 15) &",
            cwd: nil,
            timeoutMilliseconds: 10_000
        )
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        expectEqual(res.exitCode, 0, "command with detached grandchild exits 0")
        expect(res.stdout.contains("ready"), "stdout before child exit is captured")
        expect(elapsed < 2.5, "post-exit pipe drain stops within grace window (elapsed=\(String(format: "%.2f", elapsed))s)")
        expectEqual(ShellRunner.currentInFlightCount, 0, "worker slot count returns to 0 after detached grandchild")

        expect(
            ShellRunner.isFastNativeAction(.shell(command: "open -a Terminal", cwd: nil, timeoutMilliseconds: nil), allowAccessibility: false),
            "open -a Terminal qualifies as fast native action (exempt from shell worker cap)"
        )
        expect(
            !ShellRunner.isFastNativeAction(.shell(command: "echo $SELECTED_TEXT", cwd: nil, timeoutMilliseconds: nil), allowAccessibility: false),
            "SELECTED_TEXT shell command is not classified as fast native action"
        )
        let env = ShellRunner.scrubbedEnvironment(allowAccessibility: false, selectedText: "hi", selectedTextStatus: .ok)
        expect(env.contains("SELECTED_TEXT=hi"), "scrubbedEnvironment includes SELECTED_TEXT")
        expect(env.contains("SELECTED_TEXT_STATUS=ok"), "scrubbedEnvironment includes SELECTED_TEXT_STATUS")
        ShellRunner.clearApplicationURLCache()
    }

    // 6. End-to-end CLI & AI-agent contract regression tests in isolated HOTKEYD_HOME
    var pathSize: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &pathSize)
    var pathBuf = [CChar](repeating: 0, count: Int(pathSize))
    _ = _NSGetExecutablePath(&pathBuf, &pathSize)
    let binDir = URL(fileURLWithPath: String(cString: pathBuf)).resolvingSymlinksInPath().deletingLastPathComponent()
    let cliURL = binDir.appendingPathComponent("hotkeyd")
    let devURL = binDir.appendingPathComponent("hotkeyd-dev")

    if fm.isExecutableFile(atPath: cliURL.path) {
        let sandbox = Paths.realHomeDirectory.appendingPathComponent(".hotkeyd-ux-cli-\(UUID().uuidString)")
        try? fm.createDirectory(at: sandbox, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: sandbox) }

        func runCLI(_ args: String) -> ShellResult {
            ShellRunner.run(
                command: "HOTKEYD_HOME='\(sandbox.path)' '\(cliURL.path)' \(args)",
                cwd: sandbox.path,
                timeoutMilliseconds: 10_000
            )
        }

        // 6a. doctor on missing config exits non-zero (7)
        let docMissing = runCLI("doctor --json")
        expectEqual(docMissing.exitCode, 7, "doctor exits 7 when config is missing")
        expect(docMissing.stdout.contains("\"ok\" : false"), "doctor --json sets ok:false when checks fail")

        // 6b. --flag=false never enables switches; invalid bool exits 2
        let falseFlags = runCLI("add fn+f11 'echo hi' --allow-accessibility=false --pass-through=false --json=true")
        expectEqual(falseFlags.exitCode, 0, "add with --flag=false --json=true succeeds")
        expect(falseFlags.stdout.contains("\"allowAccessibility\" : false"), "--allow-accessibility=false keeps allowAccessibility false")
        expect(falseFlags.stdout.contains("\"passThrough\" : false"), "--pass-through=false keeps passThrough false")
        expect(falseFlags.stdout.contains("\"enabled\" : true"), "ShortcutView JSON explicitly includes enabled: true")
        let badBool = runCLI("list --json=maybe")
        expectEqual(badBool.exitCode, 2, "invalid boolean flag value exits 2")
        let jsonFalse = runCLI("list --json=false")
        expectEqual(jsonFalse.exitCode, 0, "list --json=false succeeds")
        expect(!jsonFalse.stdout.contains("\"schemaVersion\""), "--json=false emits human output, not JSON")

        // 6c. rm --double-tap on tap-only shortcut exits 3 (no silent no-op!)
        let rmMissingSlot = runCLI("rm fn+f11 --double-tap")
        expectEqual(rmMissingSlot.exitCode, 3, "rm --double-tap exits 3 when doubleTap slot is absent")
        let rmBothSlots = runCLI("rm fn+f11 --tap --double-tap")
        expectEqual(rmBothSlots.exitCode, 2, "rm --tap --double-tap together exits 2")

        // 6d. Metadata-only `set`, `--dry-run`, `show`, `enable`/`disable`, disabled `set` no-duplicate
        let dryAdd = runCLI("add fn:q 'open -a Safari' --dry-run --json")
        expectEqual(dryAdd.exitCode, 0, "add --dry-run succeeds with fn:q sequence syntax")
        expect(dryAdd.stdout.contains("\"dryRun\" : true"), "add --dry-run JSON marks dryRun: true")
        expectEqual(runCLI("show fn:q").exitCode, 3, "--dry-run did not persist fn:q")

        expectEqual(runCLI("add fn:q 'open -a Safari' --name Safari").exitCode, 0, "add fn:q --name Safari succeeds")
        let showOut = runCLI("show Safari --json")
        expectEqual(showOut.exitCode, 0, "show by name succeeds")
        expect(showOut.stdout.contains("\"keys\" : \"fn > q\""), "show resolves canonical 'fn > q'")
        expect(showOut.stdout.contains("\"executionMode\" : \"native-app\""), "show reports native-app executionMode")

        let metaUpdate = runCLI("set Safari --timeout 45000 --max-sequence-delay 450 --json")
        expectEqual(metaUpdate.exitCode, 0, "metadata-only set by name succeeds")
        expect(metaUpdate.stdout.contains("\"timeoutMs\" : 45000"), "metadata-only set updates timeoutMs")
        expect(metaUpdate.stdout.contains("\"maxSequenceDelayMs\" : 450"), "metadata-only set updates maxSequenceDelayMs")
        expect(metaUpdate.stdout.contains("\"tap\" : \"open -a Safari\""), "metadata-only set preserves existing command")

        expectEqual(runCLI("disable Safari --json").exitCode, 0, "disable succeeds")
        expect(runCLI("show Safari --json").stdout.contains("\"enabled\" : false"), "disable persists enabled: false")
        // Updating a disabled shortcut with `set` must NOT create a duplicate!
        expectEqual(runCLI("set 'fn > q' 'open -a Terminal'").exitCode, 0, "set on disabled shortcut succeeds")
        expectEqual(runCLI("enable Safari --json").exitCode, 0, "enable re-enables without duplicate conflict")

        // 6e. Multiline script truncation in `list` vs full in `list --full`
        let addLong = runCLI("add fn+f10 $'echo line1\\necho line2\\necho line3' --name MultiLine")
        expectEqual(addLong.exitCode, 0, "add multiline command succeeds")
        let listCompact = runCLI("list")
        expectEqual(listCompact.exitCode, 0, "list succeeds")
        expect(!listCompact.stdout.contains("line1\necho line2"), "list collapses multiline commands onto one row")
        let listFull = runCLI("list --full")
        expect(listFull.stdout.contains("line1\necho line2"), "list --full prints raw multiline command")

        // 6f. `validate` + rollover warnings
        expectEqual(runCLI("add fn+q 'echo combo-q'").exitCode, 0, "add fn+q for rollover test")
        let valJSON = runCLI("validate --json")
        expectEqual(valJSON.exitCode, 0, "validate exits 0 on valid config")
        expect(valJSON.stdout.contains("rollover overlap"), "validate detects fn+q vs fn > q rollover overlap")

        // 6g. `run --wait --json` ok:false on failure + `detached: true` on non-wait
        expectEqual(runCLI("add fn+f9 'exit 1' --name Failing").exitCode, 0, "add failing command")
        let runFail = runCLI("run Failing --wait --json")
        expectEqual(runFail.exitCode, 8, "run --wait on failing command exits 8")
        expect(runFail.stdout.contains("\"ok\" : false"), "run --wait --json emits ok: false when command exits non-zero")
        expect(runFail.stdout.contains("\"detached\" : false"), "run --wait --json includes detached: false")

        let runDetached = runCLI("run fn+f11 --json")
        expectEqual(runDetached.exitCode, 0, "detached run --json exits 0")
        expect(runDetached.stdout.contains("\"detached\" : true"), "detached run --json includes detached: true")

        // 6h. `migrate-actions` preserves names by default
        let migDry = runCLI("migrate-actions --json")
        expectEqual(migDry.exitCode, 0, "migrate-actions succeeds")
        expectEqual(runCLI("show Safari").exitCode, 0, "migrate-actions preserves shortcut names by default")

        // 6i. `schema entry --json` uses standard envelope without non-standard `target` key
        let schemaEntry = runCLI("schema entry --json")
        expectEqual(schemaEntry.exitCode, 0, "schema entry --json exits 0")
        expect(schemaEntry.stdout.contains("\"title\" : \"HotkeydShortcut\""), "schema entry emits HotkeydShortcut")
        expect(!schemaEntry.stdout.contains("\"target\""), "schema --json omits non-standard top-level target key")

        // 6j. `caps --json`, `help --json`, `describe --json` keys/reservedCombos, and CommandRegistry parity
        let capsJSON = runCLI("caps --json")
        expectEqual(capsJSON.exitCode, 0, "`hotkeyd caps --json` exits 0")
        expect(capsJSON.stdout.contains("\"command\" : \"caps.status\""), "`hotkeyd caps --json` maps to caps.status")

        let helpJSON = runCLI("help add --json")
        expectEqual(helpJSON.exitCode, 0, "`hotkeyd help add --json` exits 0")
        expect(helpJSON.stdout.contains("\"command\" : \"help\""), "`hotkeyd help add --json` emits help envelope")

        let describeOutFile = sandbox.appendingPathComponent("describe.json")
        let describeJSON = runCLI("describe --json > '\(describeOutFile.path)'")
        expectEqual(describeJSON.exitCode, 0, "`hotkeyd describe --json` exits 0")
        let fullDescribe = (try? String(contentsOf: describeOutFile, encoding: .utf8)) ?? ""
        expect(fullDescribe.contains("\"reservedCombos\""), "describe --json includes reservedCombos")
        expect(fullDescribe.contains("\"keyAliases\""), "describe --json includes keyAliases")
        expect(fullDescribe.contains("\"SELECTED_TEXT_STATUS\""), "describe --json documents SELECTED_TEXT_STATUS")

        // Parity check: every command registered in CommandRegistry must accept `--help` with exit 0!
        for spec in CommandRegistry.commands {
            let cmdArgs = spec.path.joined(separator: " ") + " --help"
            let res = runCLI(cmdArgs)
            expectEqual(res.exitCode, 0, "CLI parity: `hotkeyd \(cmdArgs)` exits 0")
        }

        // 6k. [CRITICAL/HIGH security regressions] hotkeyd edit TCC disclaim + umask + symlink refusal + daemon reload sandbox check
        let reloadSandbox = runCLI("daemon reload --json")
        expectEqual(reloadSandbox.exitCode, 6, "daemon reload refuses to touch live LaunchAgent under HOTKEYD_HOME")

        // Verify spawnProcess(..., setProcessGroup: false, disclaimResponsibility: true) keeps
        // caller PGID while disclaiming TCC responsibility.
        let editSpawn = ShellRunner.spawnProcess(
            executablePath: "/bin/sleep",
            arguments: ["/bin/sleep", "0.4"],
            environment: ["PATH=/usr/bin:/bin"],
            workingDirectory: sandbox.path,
            disclaimResponsibility: true,
            setProcessGroup: false,
            inheritStandardIO: false
        )
        if case .success(let pid) = editSpawn {
            defer {
                _ = kill(pid, SIGKILL)
                var st: Int32 = 0
                _ = waitpid(pid, &st, 0)
            }
            expectEqual(getpgid(pid), getpgrp(), "setProcessGroup: false keeps caller TTY process group")
            expectEqual(ShellRunner.responsiblePID(for: pid), pid, "setProcessGroup: false still disclaims TCC responsibility")
        } else {
            expect(false, "spawnProcess with setProcessGroup: false should succeed")
        }

        // End-to-end PTY test of `hotkeyd edit`:
        //  (1) refuses symlinked .hotkeyd (never invokes $VISUAL)
        //  (2) falls back from empty VISUAL="" to EDITOR and enforces umask 0077 + TCC disclaim
        let editSandbox = Paths.realHomeDirectory.appendingPathComponent(".hotkeyd-edit-sec-\(UUID().uuidString)")
        try? fm.createDirectory(at: editSandbox, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: editSandbox) }

        let decoyTarget = editSandbox.appendingPathComponent("decoy.json")
        try? Data("{\"shortcuts\":[]}\n".utf8).write(to: decoyTarget)
        let symCfg = editSandbox.appendingPathComponent(".hotkeyd")
        _ = symlink(decoyTarget.path, symCfg.path)
        let editorCanary = editSandbox.appendingPathComponent("editor-ran")
        let symEditRes = ShellRunner.run(
            command: """
            /usr/bin/python3 -c '
            import os, pty, select, subprocess, sys
            m, s = pty.openpty()
            env = os.environ.copy()
            env["HOTKEYD_HOME"] = sys.argv[1]
            env["VISUAL"] = "/usr/bin/touch " + sys.argv[3]
            p = subprocess.Popen([sys.argv[2], "edit"], stdin=s, stdout=s, stderr=s, env=env, close_fds=True)
            os.close(s)
            while True:
                r, _, _ = select.select([m], [], [], 0.2)
                if r:
                    try:
                        if not os.read(m, 4096): break
                    except OSError:
                        break
                if p.poll() is not None:
                    break
            os.close(m)
            sys.exit(p.wait())
            ' '\(editSandbox.path)' '\(cliURL.path)' '\(editorCanary.path)'
            """,
            cwd: editSandbox.path,
            timeoutMilliseconds: 10_000
        )
        expectEqual(symEditRes.exitCode, 7, "`hotkeyd edit` rejects symlinked .hotkeyd with exit 7")
        expect(!fm.fileExists(atPath: editorCanary.path), "`hotkeyd edit` does not launch editor on symlinked .hotkeyd")

        try? fm.removeItem(at: symCfg)
        let probeEditor = editSandbox.appendingPathComponent("probe-editor.sh")
        let umaskOut = editSandbox.appendingPathComponent("umask.txt")
        let editorPidOut = editSandbox.appendingPathComponent("editor-resp.txt")
        let probeScript = """
        #!/bin/sh
        umask > '\(umaskOut.path)'
        echo $$ > '\(editorPidOut.path)'
        /bin/sleep 0.25
        exit 0
        """
        try? Data(probeScript.utf8).write(to: probeEditor)
        _ = chmod(probeEditor.path, 0o700)

        let okEditRes = ShellRunner.run(
            command: """
            /usr/bin/python3 -c '
            import ctypes, os, pty, select, subprocess, sys, time
            m, s = pty.openpty()
            env = os.environ.copy()
            env["HOTKEYD_HOME"] = sys.argv[1]
            env["VISUAL"] = ""
            env["EDITOR"] = sys.argv[3]
            p = subprocess.Popen([sys.argv[2], "edit"], stdin=s, stdout=s, stderr=s, env=env, close_fds=True)
            os.close(s)
            resp_ok = False
            lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
            lib.responsibility_get_pid_responsible_for_pid.argtypes = [ctypes.c_int]
            lib.responsibility_get_pid_responsible_for_pid.restype = ctypes.c_int
            deadline = time.time() + 5.0
            while time.time() < deadline:
                if not resp_ok and os.path.exists(sys.argv[4]):
                    try:
                        epid = int(open(sys.argv[4]).read().strip())
                        if epid > 1:
                            rpid = lib.responsibility_get_pid_responsible_for_pid(epid)
                            if rpid == epid:
                                resp_ok = True
                    except Exception:
                        pass
                r, _, _ = select.select([m], [], [], 0.05)
                if r:
                    try:
                        os.read(m, 4096)
                    except OSError:
                        pass
                if p.poll() is not None:
                    break
            os.close(m)
            rc = p.wait()
            print("EDIT_RESP_OK=" + ("1" if resp_ok else "0"))
            sys.exit(rc)
            ' '\(editSandbox.path)' '\(cliURL.path)' '\(probeEditor.path)' '\(editorPidOut.path)'
            """,
            cwd: editSandbox.path,
            timeoutMilliseconds: 10_000
        )
        expectEqual(okEditRes.exitCode, 0, "`hotkeyd edit` succeeds with VISUAL='' falling back to EDITOR")
        expect(okEditRes.stdout.contains("EDIT_RESP_OK=1"), "`hotkeyd edit` disclaims TCC responsibility on spawned editor")
        let recordedUmask = ((try? String(contentsOf: umaskOut, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        expectEqual(recordedUmask, "0077", "`hotkeyd edit` enforces umask 0077 for editor process")
        var editedSt = stat()
        expectEqual(lstat(symCfg.path, &editedSt), 0, "`hotkeyd edit` created .hotkeyd")
        expectEqual(editedSt.st_mode & 0o777, 0o600, "`hotkeyd edit` saved .hotkeyd with mode 0600")

        // Verify scripts/build.sh and scripts/setup-signing.sh reject newline injection and parse flags safely
        var repoRootCandidate = binDir
        var foundRepoRoot: URL?
        for _ in 0..<5 {
            if fm.fileExists(atPath: repoRootCandidate.appendingPathComponent("scripts/build.sh").path)
                && fm.fileExists(atPath: repoRootCandidate.appendingPathComponent("scripts/setup-signing.sh").path) {
                foundRepoRoot = repoRootCandidate
                break
            }
            repoRootCandidate = repoRootCandidate.deletingLastPathComponent()
        }
        expect(foundRepoRoot != nil, "selftest locates repo root containing scripts/build.sh and scripts/setup-signing.sh")
        if let repoRoot = foundRepoRoot {
            let buildScript = repoRoot.appendingPathComponent("scripts/build.sh")
            let setupScript = repoRoot.appendingPathComponent("scripts/setup-signing.sh")
            let nlBuild = ShellRunner.run(
                command: "HOTKEYD_SIGNING_PASSWORD=$'pass\\nhelp' '\(buildScript.path)'",
                cwd: repoRoot.path,
                timeoutMilliseconds: 5_000
            )
            expectEqual(nlBuild.exitCode, 2, "scripts/build.sh rejects newline in HOTKEYD_SIGNING_PASSWORD with exit 2")
            let nlBuildAdhoc = ShellRunner.run(
                command: "HOTKEYD_SIGNING_PASSWORD=$'pass\\nhelp' '\(buildScript.path)' --adhoc",
                cwd: repoRoot.path,
                timeoutMilliseconds: 5_000
            )
            expectEqual(nlBuildAdhoc.exitCode, 2, "scripts/build.sh --adhoc still rejects newline in HOTKEYD_SIGNING_PASSWORD with exit 2")
            let helpBuild = ShellRunner.run(
                command: "'\(buildScript.path)' --help",
                cwd: repoRoot.path,
                timeoutMilliseconds: 5_000
            )
            expectEqual(helpBuild.exitCode, 0, "scripts/build.sh --help exits 0")
            expect(helpBuild.stdout.contains("--adhoc"), "scripts/build.sh --help documents --adhoc")
            expect(helpBuild.stdout.contains("Accessibility"), "scripts/build.sh --help explains Accessibility caveat for --adhoc")
            let conflictBuild = ShellRunner.run(
                command: "'\(buildScript.path)' --install --no-restart",
                cwd: repoRoot.path,
                timeoutMilliseconds: 5_000
            )
            expectEqual(conflictBuild.exitCode, 2, "scripts/build.sh rejects conflicting --install --no-restart with exit 2")
            let bogusBuild = ShellRunner.run(
                command: "'\(buildScript.path)' --adhoc --bogus",
                cwd: repoRoot.path,
                timeoutMilliseconds: 5_000
            )
            expectEqual(bogusBuild.exitCode, 2, "scripts/build.sh rejects unknown option combined with --adhoc")
            let ctrlBuild = ShellRunner.run(
                command: "HOTKEYD_SIGNING_PASSWORD=$'pass\\x1b[31m' '\(buildScript.path)' --adhoc",
                cwd: repoRoot.path,
                timeoutMilliseconds: 5_000
            )
            expectEqual(ctrlBuild.exitCode, 2, "scripts/build.sh rejects ESC control chars in HOTKEYD_SIGNING_PASSWORD with exit 2")
            let nlSetup = ShellRunner.run(
                command: "HOTKEYD_KEYCHAIN=$'/tmp/k\\nhelp' '\(setupScript.path)'",
                cwd: repoRoot.path,
                timeoutMilliseconds: 5_000
            )
            expectEqual(nlSetup.exitCode, 2, "scripts/setup-signing.sh rejects newline in HOTKEYD_KEYCHAIN with exit 2")
            let ctrlSetup = ShellRunner.run(
                command: "HOTKEYD_KEYCHAIN=$'/tmp/k\\x1b[31m' '\(setupScript.path)'",
                cwd: repoRoot.path,
                timeoutMilliseconds: 5_000
            )
            expectEqual(ctrlSetup.exitCode, 2, "scripts/setup-signing.sh rejects ESC control chars in HOTKEYD_KEYCHAIN with exit 2")
        }
    }

    if fm.isExecutableFile(atPath: devURL.path) {
        for sub in ["--help", "listen --help", "tap --help", "modtap --help"] {
            let res = ShellRunner.run(
                command: "'\(devURL.path)' \(sub)",
                cwd: nil,
                timeoutMilliseconds: 5_000
            )
            expectEqual(res.exitCode, 0, "`hotkeyd-dev \(sub)` exits 0 without TTY")
        }
    }
}

func testInitOnboardingAndPrerequisites() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("hotkeyd-init-test-\(UUID().uuidString)")
    try? fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: root) }

    // 1. RuntimeState.remove(expectedPID:) guards against stale daemon unlinking newer PID's state.
    let stateURL = root.appendingPathComponent("runtime-state.json")
    let state = RuntimeState(
        pid: 11_111,
        startedAt: RuntimeState.timestamp(),
        updatedAt: RuntimeState.timestamp(),
        binaryPath: "/Users/test/.local/bin/hotkeyd",
        configPath: root.appendingPathComponent(".hotkeyd").path,
        tapActive: true,
        tapNote: "listening for shortcuts",
        activeBindings: 3
    )
    do {
        try state.save(to: stateURL)
        RuntimeState.remove(at: stateURL, expectedPID: 22_222)
        expect(RuntimeState.load(from: stateURL)?.pid == 11_111, "RuntimeState.remove(expectedPID:) preserves another PID's state")
        RuntimeState.remove(at: stateURL, expectedPID: 11_111)
        expect(RuntimeState.load(from: stateURL) == nil, "RuntimeState.remove(expectedPID:) removes matching PID's state")
    } catch {
        expect(false, "RuntimeState expectedPID test failed: \(error)")
    }

    // 2. One-shot AX prompt suppression sentinel (valid 0600, consumed once, rejects symlink & 0644).
    let sentinelURL = root.appendingPathComponent(".suppress-ax-prompt")
    do {
        try RuntimeState.writeSuppressAXPromptSentinel(to: sentinelURL)
        expect(RuntimeState.consumeSuppressAXPromptSentinel(at: sentinelURL), "valid AX-suppress sentinel consumes true once")
        expect(!RuntimeState.consumeSuppressAXPromptSentinel(at: sentinelURL), "consumed AX-suppress sentinel returns false on second read")

        let decoy = root.appendingPathComponent("decoy-sentinel")
        try Data("1\n".utf8).write(to: decoy)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: decoy.path)
        try fm.createSymbolicLink(atPath: sentinelURL.path, withDestinationPath: decoy.path)
        expect(!RuntimeState.consumeSuppressAXPromptSentinel(at: sentinelURL), "symlink AX-suppress sentinel is rejected")

        try Data("1\n".utf8).write(to: sentinelURL)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: sentinelURL.path)
        expect(!RuntimeState.consumeSuppressAXPromptSentinel(at: sentinelURL), "0644 AX-suppress sentinel is rejected")
    } catch {
        expect(false, "AX-suppress sentinel test failed: \(error)")
    }

    // 3. InitSupport 6-state config inspection & safe repairs (missing, valid, empty, 0644, symlink, invalid).
    let previousOverride = getenv("HOTKEYD_HOME").map { String(cString: $0) }
    setenv("HOTKEYD_HOME", root.path, 1)
    defer {
        if let previousOverride {
            setenv("HOTKEYD_HOME", previousOverride, 1)
        } else {
            unsetenv("HOTKEYD_HOME")
        }
    }

    let cfgURL = root.appendingPathComponent(".hotkeyd")
    expectEqual(InitSupport.inspectConfigState(at: cfgURL).kindName, "missing", "inspectConfigState detects missing config")

    // Empty config (0-byte and empty JSON)
    try? Data().write(to: cfgURL)
    try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cfgURL.path)
    expectEqual(InitSupport.inspectConfigState(at: cfgURL).kindName, "empty", "inspectConfigState detects 0-byte empty config")

    let sampleShortcut = Shortcut(
        keys: .modifier(.leftOption),
        doubleTap: "open -a Terminal",
        name: "Terminal"
    )
    do {
        try Config(shortcuts: [sampleShortcut]).save(to: cfgURL)
        if case .valid(let count, _) = InitSupport.inspectConfigState(at: cfgURL) {
            expectEqual(count, 1, "inspectConfigState detects valid 0600 config with 1 shortcut")
        } else {
            expect(false, "expected valid config state")
        }

        // Loose 0644 permissions -> repair to 0600
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: cfgURL.path)
        if case .loosePermissions(let mode) = InitSupport.inspectConfigState(at: cfgURL) {
            expectEqual(mode, 0o644, "inspectConfigState detects loose 0644 permissions")
        } else {
            expect(false, "expected loosePermissions config state")
        }
        try InitSupport.fixLoosePermissions(at: cfgURL)
        expectEqual(InitSupport.inspectConfigState(at: cfgURL).kindName, "valid", "fixLoosePermissions restores valid 0600 state")

        // Symlinked dotfiles config -> materialize safely without touching source
        let dotfilesDir = root.appendingPathComponent("dotfiles")
        try fm.createDirectory(at: dotfilesDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let dotfileSrc = dotfilesDir.appendingPathComponent("hotkeyd.json")
        try Config(shortcuts: [sampleShortcut]).save(to: dotfileSrc)
        try fm.removeItem(at: cfgURL)
        try fm.createSymbolicLink(atPath: cfgURL.path, withDestinationPath: dotfileSrc.path)
        if case .symlink(let target) = InitSupport.inspectConfigState(at: cfgURL) {
            expectEqual(target, dotfileSrc.path, "inspectConfigState detects symlink target")
        } else {
            expect(false, "expected symlink config state")
        }
        let materialized = try InitSupport.materializeSymlinkConfig(at: cfgURL)
        expectEqual(materialized.shortcuts.count, 1, "materializeSymlinkConfig preserves shortcuts")
        var matStat = stat()
        expectEqual(lstat(cfgURL.path, &matStat), 0, "materialized config exists")
        expectEqual(matStat.st_mode & S_IFMT, S_IFREG, "materialized config is a regular file, not a symlink")
        expectEqual(matStat.st_mode & 0o777, 0o600, "materialized config has mode 0600")
        expect(fm.fileExists(atPath: dotfileSrc.path), "materializeSymlinkConfig leaves dotfiles source intact")

        // Symlink pointing to malformed JSON refuses to overwrite the symlink
        let badDotfile = dotfilesDir.appendingPathComponent("bad.json")
        try Data("{ bad json".utf8).write(to: badDotfile)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: badDotfile.path)
        try fm.removeItem(at: cfgURL)
        try fm.createSymbolicLink(atPath: cfgURL.path, withDestinationPath: badDotfile.path)
        var materializeThrew = false
        do {
            _ = try InitSupport.materializeSymlinkConfig(at: cfgURL)
        } catch {
            materializeThrew = true
        }
        expect(materializeThrew, "materializeSymlinkConfig rejects malformed JSON target before replacing symlink")
        var stillLink = stat()
        expectEqual(lstat(cfgURL.path, &stillLink), 0, "symlink still exists after failed materialization")
        expectEqual(stillLink.st_mode & S_IFMT, S_IFLNK, "failed materialization does not overwrite symlink")

        // H3 security tests: materializeSymlinkConfig rejects 0666 target, 0777 target dir, /tmp target, and root-owned target
        let worldWritableTarget = dotfilesDir.appendingPathComponent("ww.json")
        try Config(shortcuts: [sampleShortcut]).save(to: worldWritableTarget)
        try fm.setAttributes([.posixPermissions: 0o666], ofItemAtPath: worldWritableTarget.path)
        try fm.removeItem(at: cfgURL)
        try fm.createSymbolicLink(atPath: cfgURL.path, withDestinationPath: worldWritableTarget.path)
        var wwThrew = false
        do { _ = try InitSupport.materializeSymlinkConfig(at: cfgURL) } catch { wwThrew = true }
        expect(wwThrew, "materializeSymlinkConfig rejects group/world-writable (0666) symlink target")

        let wwDir = root.appendingPathComponent("ww-dir")
        try fm.createDirectory(at: wwDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o777])
        try fm.setAttributes([.posixPermissions: 0o777], ofItemAtPath: wwDir.path)
        let inWWDir = wwDir.appendingPathComponent("cfg.json")
        try Data("{\"shortcuts\":[]}\n".utf8).write(to: inWWDir)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: inWWDir.path)
        try fm.removeItem(at: cfgURL)
        try fm.createSymbolicLink(atPath: cfgURL.path, withDestinationPath: inWWDir.path)
        var wwDirThrew = false
        do { _ = try InitSupport.materializeSymlinkConfig(at: cfgURL) } catch { wwDirThrew = true }
        expect(wwDirThrew, "materializeSymlinkConfig rejects target inside group/world-writable (0777) directory")

        let tmpTarget = URL(fileURLWithPath: "/tmp/hotkeyd-h3-test-\(UUID().uuidString).json")
        try Data("{\"shortcuts\":[]}\n".utf8).write(to: tmpTarget)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmpTarget.path)
        defer { try? fm.removeItem(at: tmpTarget) }
        try fm.removeItem(at: cfgURL)
        try fm.createSymbolicLink(atPath: cfgURL.path, withDestinationPath: tmpTarget.path)
        var tmpThrew = false
        do { _ = try InitSupport.materializeSymlinkConfig(at: cfgURL) } catch { tmpThrew = true }
        expect(tmpThrew, "materializeSymlinkConfig rejects symlink target inside /tmp")

        try fm.removeItem(at: cfgURL)
        try fm.createSymbolicLink(atPath: cfgURL.path, withDestinationPath: "/etc/hosts")
        var rootOwnedThrew = false
        do { _ = try InitSupport.materializeSymlinkConfig(at: cfgURL) } catch { rootOwnedThrew = true }
        expect(rootOwnedThrew, "materializeSymlinkConfig rejects root-owned symlink target")

        // H2 security test: verifyRunningProcess rejects mismatched expectedBinaryPath
        var mismatchThrew = false
        do {
            _ = try CodeTrust.verifyRunningProcess(
                pid: getpid(),
                expectedBinaryPath: "/usr/bin/true",
                allowAdhoc: true
            )
        } catch {
            mismatchThrew = true
        }
        expect(mismatchThrew, "CodeTrust.verifyRunningProcess rejects mismatched expectedBinaryPath")

        // Malformed regular config -> invalid
        try fm.removeItem(at: cfgURL)
        try Data("{ invalid".utf8).write(to: cfgURL)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cfgURL.path)
        expectEqual(InitSupport.inspectConfigState(at: cfgURL).kindName, "invalid", "inspectConfigState detects malformed JSON")
    } catch {
        expect(false, "InitSupport config state tests failed: \(error)")
    }

    // 4. Active terminal detection (including tmux/screen passthrough) & starter pack validation.
    expectEqual(InitSupport.detectActiveTerminalSpec(environment: ["TERM_PROGRAM": "iTerm.app"])?.name, "iTerm", "detects iTerm.app")
    expectEqual(InitSupport.detectActiveTerminalSpec(environment: ["TERM_PROGRAM": "ghostty"])?.name, "Ghostty", "detects Ghostty")
    expectEqual(InitSupport.detectActiveTerminalSpec(environment: ["TERM_PROGRAM": "vscode"])?.name, "Visual Studio Code", "detects VS Code")
    expectEqual(
        InitSupport.detectActiveTerminalSpec(environment: ["TERM_PROGRAM": "tmux", "LC_TERMINAL": "iTerm2"])?.name,
        "iTerm",
        "unwraps tmux via LC_TERMINAL=iTerm2"
    )
    expectEqual(
        InitSupport.detectActiveTerminalSpec(environment: ["GHOSTTY_RESOURCES_DIR": "/Applications/Ghostty.app/Contents/Resources"])?.name,
        "Ghostty",
        "detects Ghostty via GHOSTTY_RESOURCES_DIR"
    )

    let starters = InitSupport.buildMinimalStarters(environment: ["TERM_PROGRAM": "Apple_Terminal"])
    expectEqual(starters.count, 3, "minimal starter preset produces 3 bindings")
    expectEqual(starters.map(\.keys), ["lcmd", "lopt", "rcmd"], "minimal starters bind lcmd, lopt, rcmd")
    expectEqual(starters[1].summary, "Terminal", "TERM_PROGRAM=Apple_Terminal selects Terminal for lopt")
    do {
        let starterShortcuts = try starters.map { try $0.toShortcut() }
        let starterConfig = Config(shortcuts: starterShortcuts)
        try starterConfig.validate()
        expect(starterShortcuts.allSatisfy { !$0.allowAccessibility }, "all starter shortcuts have allowAccessibility=false")
    } catch {
        expect(false, "starter shortcuts failed validation: \(error)")
    }

    // 5. Safe Step 4 verification candidate selection (must NEVER pick shell/lock/sleep/URL/dir/AX/args).
    let unsafeOnly = Config(shortcuts: [
        Shortcut(keys: .sequence(KeySequence(leader: .fn, keyCode: 53)), tap: "pmset displaysleepnow", name: "Lock"),
        Shortcut(keys: .modifier(.rightOption), doubleTap: "/usr/bin/osascript -e 'beep'", name: "Beep"),
        Shortcut(keys: .modifier(.leftOption), doubleTap: "open -a Terminal", name: "PrivilegedTerm", allowAccessibility: true),
        Shortcut(keys: .modifier(.rightCommand), doubleTap: "open ~", name: "Home"),
        Shortcut(keys: .modifier(.leftCommand), doubleTap: "open https://example.com", name: "Web"),
        Shortcut(keys: .modifier(.leftShift), doubleTap: "open -a Terminal --args -v", name: "ArgsTerm"),
        // M8 security test: combo with destructive paired `tap` + benign `doubleTap` must NEVER be selected
        Shortcut(keys: .combo(try! KeyCombo.parse("fn+escape")), tap: "pmset displaysleepnow", doubleTap: "open -a Terminal", name: "PairedHazard")
    ])
    expect(
        InitSupport.selectSafeVerificationCandidate(from: unsafeOnly, environment: ["TERM_PROGRAM": "Apple_Terminal"]) == nil,
        "selectSafeVerificationCandidate refuses shell, AX, URL, directory, --args, and paired-destructive-tap shortcuts"
    )

    // M2 security test: fixLoosePermissions rejects symlinked parent directory
    let realParentDir = root.appendingPathComponent("real-parent-dir")
    try? fm.createDirectory(at: realParentDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let looseInsideReal = realParentDir.appendingPathComponent(".hotkeyd")
    try? Data("{\"shortcuts\":[]}\n".utf8).write(to: looseInsideReal)
    try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: looseInsideReal.path)
    let symParentDir = root.appendingPathComponent("sym-parent-dir")
    try? fm.createSymbolicLink(atPath: symParentDir.path, withDestinationPath: realParentDir.path)
    var symParentFixThrew = false
    do {
        try InitSupport.fixLoosePermissions(at: symParentDir.appendingPathComponent(".hotkeyd"))
    } catch {
        symParentFixThrew = true
    }
    expect(symParentFixThrew, "fixLoosePermissions rejects symlinked parent directory")

    let mixedDotfiles = Config(shortcuts: [
        Shortcut(keys: .sequence(KeySequence(leader: .fn, keyCode: 53)), tap: "pmset displaysleepnow", name: "Lock"),
        Shortcut(keys: .modifier(.leftCommand), doubleTap: "open -a Safari", name: "Browser"),
        Shortcut(keys: .modifier(.leftOption), doubleTap: "open -a iTerm", name: "MyTerm")
    ])
    let pickedMixed = InitSupport.selectSafeVerificationCandidate(
        from: mixedDotfiles,
        environment: ["TERM_PROGRAM": "iTerm.app"]
    )
    expectEqual(pickedMixed?.keys, "lopt", "selectSafeVerificationCandidate prefers active terminal .app shortcut")
    expectEqual(pickedMixed?.isCurrentTerminal, true, "active terminal candidate marks isCurrentTerminal=true")
    expectEqual(pickedMixed?.triggerDisplay, "doubleTap:lopt", "candidate triggerDisplay matches daemon.log format")

    let capsOnly = Config(shortcuts: [
        Shortcut(keys: .modifier(.capsLock), doubleTap: "open -a Terminal", name: "CapsTerm")
    ])
    expect(
        InitSupport.selectSafeVerificationCandidate(from: capsOnly, capsLockRemapped: false) == nil,
        "capsLock candidate is skipped when Caps Lock is not remapped"
    )
    expectEqual(
        InitSupport.selectSafeVerificationCandidate(from: capsOnly, capsLockRemapped: true)?.keys,
        "capsLock",
        "capsLock candidate is allowed when Caps Lock is remapped"
    )

    // 6. Two-stage daemon.log + actions.log verification parsers.
    if let cand = pickedMixed {
        expectEqual(
            InitSupport.parseDaemonLogLine("2026-11-20T01:00:00.001Z daemon fire doubleTap:lopt -> MyTerm", candidate: cand),
            .fired(trigger: "doubleTap:lopt", name: "MyTerm"),
            "parseDaemonLogLine matches exact fire line"
        )
        expect(
            InitSupport.parseDaemonLogLine("2026-11-20T01:00:00.001Z daemon fire doubleTap:lcmd -> Browser", candidate: cand) == nil,
            "parseDaemonLogLine ignores unrelated trigger"
        )
        expectEqual(
            InitSupport.parseActionLogLine("2026-11-20T01:00:00.029Z action shortcut=MyTerm exit=0 28ms action=open -a iTerm", candidate: cand),
            .completed(exitCode: 0, durationMs: 28),
            "parseActionLogLine parses exit=0 with duration"
        )
        expectEqual(
            InitSupport.parseActionLogLine("2026-11-20T01:00:00.041Z action shortcut=MyTerm exit=1 12ms action=open -a iTerm", candidate: cand),
            .completed(exitCode: 1, durationMs: 12),
            "parseActionLogLine parses non-zero exit code"
        )
        expectEqual(
            InitSupport.parseActionLogLine("2026-11-20T01:00:10.001Z action shortcut=MyTerm timeout 10000ms action=open -a iTerm", candidate: cand),
            .timedOut(durationMs: 10_000),
            "parseActionLogLine parses timeout"
        )
        expectEqual(
            InitSupport.parseActionLogLine("2026-11-20T01:00:00.005Z action shortcut=MyTerm dropped (concurrency limit)", candidate: cand),
            .dropped,
            "parseActionLogLine parses dropped action"
        )
        expect(
            InitSupport.parseActionLogLine("2026-11-20T01:00:00.041Z action shortcut=MyTerm stderr=not found", candidate: cand) == nil,
            "parseActionLogLine ignores stderr continuation line"
        )
    }

    // 7. End-to-end CLI tests against built `hotkeyd` binary in isolated HOTKEYD_HOME sandboxes.
    let selfPath = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let cliURL = selfPath.deletingLastPathComponent().appendingPathComponent("hotkeyd")
    guard fm.isExecutableFile(atPath: cliURL.path) else { return }

    let cliSandbox = root.appendingPathComponent("cli-sandbox")
    try? fm.createDirectory(at: cliSandbox, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

    func runInitCLI(_ args: String, home: URL = cliSandbox) -> ShellResult {
        ShellRunner.run(
            command: "HOTKEYD_HOME='\(home.path)' TERM_PROGRAM=Apple_Terminal '\(cliURL.path)' \(args)",
            cwd: home.path,
            timeoutMilliseconds: 10_000
        )
    }

    let helpRes = runInitCLI("init --help")
    expectEqual(helpRes.exitCode, 0, "`hotkeyd init --help` exits 0")
    expect(helpRes.stdout.contains("--starter") && helpRes.stdout.contains("--dry-run"), "`hotkeyd init --help` documents key flags")

    // Non-TTY without --non-interactive -> exit 2
    let noTTY = runInitCLI("init --no-daemon")
    expectEqual(noTTY.exitCode, 2, "`hotkeyd init` without TTY and without --non-interactive exits 2")

    // HOTKEYD_HOME without --no-daemon -> exit 2
    let envRefuse = runInitCLI("init --non-interactive --starter minimal")
    expectEqual(envRefuse.exitCode, 2, "`hotkeyd init` under HOTKEYD_HOME without --no-daemon exits 2")

    // Non-interactive with missing config and no --starter -> exit 2 (fail-closed)
    let missingStarter = runInitCLI("init --non-interactive --no-daemon --json")
    expectEqual(missingStarter.exitCode, 2, "`hotkeyd init --non-interactive` with missing config and no --starter exits 2")

    // Invalid --starter value -> exit 2
    let badStarter = runInitCLI("init --non-interactive --no-daemon --starter bogus --json")
    expectEqual(badStarter.exitCode, 2, "`hotkeyd init --starter bogus` exits 2")

    // --dry-run does not create ~/.hotkeyd and returns plannedStarters in JSON
    let dryRunOut = runInitCLI("init --dry-run --no-daemon --json")
    expectEqual(dryRunOut.exitCode, 0, "`hotkeyd init --dry-run --no-daemon --json` exits 0")
    expect(dryRunOut.stdout.contains("\"dryRun\" : true"), "dry-run JSON reports dryRun=true")
    expect(dryRunOut.stdout.contains("\"lopt\""), "dry-run JSON includes plannedStarters")
    expect(!fm.fileExists(atPath: cliSandbox.appendingPathComponent(".hotkeyd").path), "dry-run does not create .hotkeyd")

    // Non-interactive minimal bootstrap creates 0600 .hotkeyd with 3 shortcuts
    let createRes = runInitCLI("init --non-interactive --no-daemon --starter minimal --json")
    expectEqual(createRes.exitCode, 0, "`hotkeyd init --non-interactive --no-daemon --starter minimal --json` exits 0")
    expect(createRes.stdout.contains("\"configCreated\" : true"), "init JSON reports configCreated=true")
    expect(createRes.stdout.contains("\"shortcutsAdded\" : 3"), "init JSON reports shortcutsAdded=3")
    let validateRes = runInitCLI("validate --json")
    expectEqual(validateRes.exitCode, 0, "starter config passes `hotkeyd validate --json`")

    // Idempotent re-run keeps existing config untouched
    let rerunRes = runInitCLI("init --non-interactive --no-daemon --starter minimal --json")
    expectEqual(rerunRes.exitCode, 0, "idempotent `hotkeyd init` re-run exits 0")
    expect(rerunRes.stdout.contains("\"configCreated\" : false"), "re-run reports configCreated=false")
    expect(rerunRes.stdout.contains("\"shortcutsAdded\" : 0"), "re-run reports shortcutsAdded=0")

    // Loose 0644 config fails closed in --non-interactive with exit 7
    let cliCfg = cliSandbox.appendingPathComponent(".hotkeyd")
    try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: cliCfg.path)
    let looseRes = runInitCLI("init --non-interactive --no-daemon --json")
    expectEqual(looseRes.exitCode, 7, "loose 0644 config exits 7 in --non-interactive mode")
    expect(looseRes.stdout.contains("chmod 0600"), "loose 0644 JSON error hints chmod 0600")

    // PTY interactive test 1: repair 0644 config interactively by answering 'y'
    let ptyRepair = ShellRunner.run(
        command: """
        /usr/bin/python3 -c "import os, pty, select, subprocess, time
        env = os.environ.copy()
        env['HOTKEYD_HOME'] = '\(cliSandbox.path)'
        env['TERM_PROGRAM'] = 'Apple_Terminal'
        m, s = pty.openpty()
        p = subprocess.Popen(['\(cliURL.path)', 'init', '--no-daemon'], stdin=s, stdout=s, stderr=s, env=env, close_fds=True)
        os.close(s)
        out = b''
        sent = False
        end = time.time() + 8
        while time.time() < end:
            r, _, _ = select.select([m], [], [], 0.1)
            if r:
                try:
                    chunk = os.read(m, 4096)
                    if not chunk: break
                    out += chunk
                    if (not sent) and b'Tighten permissions' in out:
                        os.write(m, b'y\\n')
                        sent = True
                except OSError:
                    break
            if p.poll() is not None:
                break
        os.close(m)
        raise SystemExit(p.wait(timeout=2))"
        """,
        cwd: cliSandbox.path,
        timeoutMilliseconds: 10_000
    )
    expectEqual(ptyRepair.exitCode, 0, "PTY interactive `hotkeyd init --no-daemon` repairs 0644 config")
    var repairedSt = stat()
    expectEqual(lstat(cliCfg.path, &repairedSt), 0, "repaired config exists after PTY init")
    expectEqual(repairedSt.st_mode & 0o777, 0o600, "PTY interactive init tightened .hotkeyd to 0600")

    // PTY interactive test 2: materialize symlinked dotfiles config by answering 'y'
    let symSandbox = root.appendingPathComponent("pty-symlink-sandbox")
    try? fm.createDirectory(at: symSandbox, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let dotSrc = root.appendingPathComponent("dotfiles-pty-src.json")
    try? Config(shortcuts: [sampleShortcut]).save(to: dotSrc)
    let symCfg = symSandbox.appendingPathComponent(".hotkeyd")
    try? fm.createSymbolicLink(atPath: symCfg.path, withDestinationPath: dotSrc.path)

    // First verify headless rejects symlink with exit 7 (and M4: single-quote target is POSIX-escaped in hint)
    let symHeadless = runInitCLI("init --non-interactive --no-daemon --json", home: symSandbox)
    expectEqual(symHeadless.exitCode, 7, "symlinked config exits 7 in --non-interactive mode")
    expect(symHeadless.stdout.contains("install -m 0600"), "symlink JSON error hints install -m 0600")

    let quoteSymSandbox = root.appendingPathComponent("quote-sym-sandbox")
    try? fm.createDirectory(at: quoteSymSandbox, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try? fm.createSymbolicLink(
        atPath: quoteSymSandbox.appendingPathComponent(".hotkeyd").path,
        withDestinationPath: "a'b;id;.json"
    )
    let quoteSymRes = runInitCLI("init --non-interactive --no-daemon --json", home: quoteSymSandbox)
    expectEqual(quoteSymRes.exitCode, 7, "symlink target with single quote exits 7")
    expect(quoteSymRes.stdout.contains("a'\\\\''b;id;.json"), "M4: symlink hint POSIX-quotes embedded single quotes safely")

    // M2 PTY test: world-writable 0666 config defaults to NO on plain Enter and warns of tampering
    let wwSandbox = root.appendingPathComponent("pty-0666-sandbox")
    try? fm.createDirectory(at: wwSandbox, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let wwCfg = wwSandbox.appendingPathComponent(".hotkeyd")
    try? Config(shortcuts: [sampleShortcut]).save(to: wwCfg)
    try? fm.setAttributes([.posixPermissions: 0o666], ofItemAtPath: wwCfg.path)
    let pty0666DefaultNo = ShellRunner.run(
        command: """
        /usr/bin/python3 -c "import os, pty, select, subprocess, time
        env = os.environ.copy()
        env['HOTKEYD_HOME'] = '\(wwSandbox.path)'
        env['TERM_PROGRAM'] = 'Apple_Terminal'
        m, s = pty.openpty()
        p = subprocess.Popen(['\(cliURL.path)', 'init', '--no-daemon'], stdin=s, stdout=s, stderr=s, env=env, close_fds=True)
        os.close(s)
        out = b''
        sent = False
        end = time.time() + 8
        while time.time() < end:
            r, _, _ = select.select([m], [], [], 0.1)
            if r:
                try:
                    chunk = os.read(m, 4096)
                    if not chunk: break
                    out += chunk
                    if (not sent) and b'[y/N]' in out:
                        os.write(m, b'\\n')
                        sent = True
                except OSError:
                    break
            if p.poll() is not None:
                break
        os.close(m)
        print('HAS_WARN=' + ('1' if b'WARNING: group/world write bits' in out else '0'))
        raise SystemExit(p.wait(timeout=2))"
        """,
        cwd: wwSandbox.path,
        timeoutMilliseconds: 10_000
    )
    expectEqual(pty0666DefaultNo.exitCode, 7, "M2: 0666 config defaults to NO (exit 7) when user presses Enter")
    expect(pty0666DefaultNo.stdout.contains("HAS_WARN=1"), "M2: 0666 config prints explicit tampering warning")

    let ptySym = ShellRunner.run(
        command: """
        /usr/bin/python3 -c "import os, pty, select, subprocess, time
        env = os.environ.copy()
        env['HOTKEYD_HOME'] = '\(symSandbox.path)'
        env['TERM_PROGRAM'] = 'Apple_Terminal'
        m, s = pty.openpty()
        p = subprocess.Popen(['\(cliURL.path)', 'init', '--no-daemon'], stdin=s, stdout=s, stderr=s, env=env, close_fds=True)
        os.close(s)
        out = b''
        sent = False
        end = time.time() + 8
        while time.time() < end:
            r, _, _ = select.select([m], [], [], 0.1)
            if r:
                try:
                    chunk = os.read(m, 4096)
                    if not chunk: break
                    out += chunk
                    if (not sent) and b'Copy target to a regular 0600 file' in out:
                        os.write(m, b'y\\n')
                        sent = True
                except OSError:
                    break
            if p.poll() is not None:
                break
        os.close(m)
        raise SystemExit(p.wait(timeout=2))"
        """,
        cwd: symSandbox.path,
        timeoutMilliseconds: 10_000
    )
    expectEqual(ptySym.exitCode, 0, "PTY interactive `hotkeyd init --no-daemon` materializes symlinked config")
    var symAfter = stat()
    expectEqual(lstat(symCfg.path, &symAfter), 0, "materialized config exists after PTY symlink init")
    expectEqual(symAfter.st_mode & S_IFMT, S_IFREG, "PTY init replaced symlink with regular file")
    expectEqual(symAfter.st_mode & 0o777, 0o600, "PTY init wrote 0600 regular file")

    // PTY interactive test 3: fresh sandbox accepts starter pack interactively
    let freshSandbox = root.appendingPathComponent("pty-fresh-sandbox")
    try? fm.createDirectory(at: freshSandbox, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let ptyFresh = ShellRunner.run(
        command: """
        /usr/bin/python3 -c "import os, pty, select, subprocess, time
        env = os.environ.copy()
        env['HOTKEYD_HOME'] = '\(freshSandbox.path)'
        env['TERM_PROGRAM'] = 'Apple_Terminal'
        m, s = pty.openpty()
        p = subprocess.Popen(['\(cliURL.path)', 'init', '--no-daemon'], stdin=s, stdout=s, stderr=s, env=env, close_fds=True)
        os.close(s)
        out = b''
        sent = False
        end = time.time() + 8
        while time.time() < end:
            r, _, _ = select.select([m], [], [], 0.1)
            if r:
                try:
                    chunk = os.read(m, 4096)
                    if not chunk: break
                    out += chunk
                    if (not sent) and b'Write these 3 starter shortcuts' in out:
                        os.write(m, b'y\\n')
                        sent = True
                except OSError:
                    break
            if p.poll() is not None:
                break
        os.close(m)
        raise SystemExit(p.wait(timeout=2))"
        """,
        cwd: freshSandbox.path,
        timeoutMilliseconds: 10_000
    )
    expectEqual(ptyFresh.exitCode, 0, "PTY interactive `hotkeyd init --no-daemon` creates fresh starter config")
    if case .valid(let count, _) = InitSupport.inspectConfigState(at: freshSandbox.appendingPathComponent(".hotkeyd")) {
        expectEqual(count, 3, "PTY fresh init created 3 valid starter shortcuts at 0600")
    } else {
        expect(false, "expected valid 3-shortcut config after PTY fresh init")
    }
}

func testCompletionsAndManPage() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("hotkeyd-completions-test-\(UUID().uuidString)")
    try? fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: root) }

    // 1. Dynamic shortcut completion candidates & sanitization (all / enabled / disabled)
    let sampleConfig = Config(shortcuts: [
        Shortcut(keys: .modifier(.leftCommand), doubleTap: "open -a \"Google Chrome\"", name: "Chrome", enabled: true),
        Shortcut(keys: .sequence(KeySequence(leader: .fn, keyCode: 12)), tap: "echo 'hi:there'\nsecond line\t$(rm -rf /)", name: "Quick:Note", enabled: true),
        Shortcut(keys: .modifier(.rightOption), doubleTap: "open -a Terminal", name: "DisabledTerm", enabled: false)
    ])

    let allCandidates = ShellCompletions.shortcutCandidates(from: sampleConfig, filter: .all)
    let allValues = allCandidates.map(\.value)
    expect(allValues.contains("lcmd"), "all candidates include canonical lcmd")
    expect(allValues.contains("Chrome"), "all candidates include shortcut name Chrome")
    expect(allValues.contains("fn > q"), "all candidates include sequence canonical 'fn > q'")
    expect(allValues.contains("Quick:Note"), "all candidates include name with colon")
    expect(allValues.contains("DisabledTerm"), "all candidates include disabled shortcut")

    // Verify zero raw newlines/tabs/control chars leak into formatted TSV output
    let tsv = ShellCompletions.formatCandidates(allCandidates, plain: false)
    for line in tsv.split(separator: "\n", omittingEmptySubsequences: true) {
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
        expectEqual(parts.count, 2, "each TSV completion line has exactly 2 tab-separated fields: \(line)")
    }

    let enabledOnly = ShellCompletions.shortcutCandidates(from: sampleConfig, filter: .enabledOnly).map(\.value)
    expect(enabledOnly.contains("Chrome"), "enabledOnly includes enabled Chrome")
    expect(!enabledOnly.contains("DisabledTerm"), "enabledOnly excludes DisabledTerm")

    let disabledOnly = ShellCompletions.shortcutCandidates(from: sampleConfig, filter: .disabledOnly).map(\.value)
    expect(disabledOnly.contains("DisabledTerm"), "disabledOnly includes DisabledTerm")
    expect(!disabledOnly.contains("Chrome"), "disabledOnly excludes Chrome")

    // 2. Generated zsh, bash, and fish scripts include all registered commands + real shell syntax checks
    let zshScript = ShellCompletions.generateScript(for: .zsh, version: "0.1.0")
    let bashScript = ShellCompletions.generateScript(for: .bash, version: "0.1.0")
    let fishScript = ShellCompletions.generateScript(for: .fish, version: "0.1.0")

    expect(zshScript.hasPrefix("#compdef hotkeyd\n"), "zsh completion starts with #compdef hotkeyd")
    expect(zshScript.contains("_hotkeyd_shortcuts"), "zsh completion wires dynamic shortcut helper")
    expect(bashScript.contains("complete -F _hotkeyd_completions hotkeyd"), "bash completion registers complete -F")
    expect(bashScript.contains("__complete \"$kind\" --plain"), "bash completion wires dynamic plain helper")
    expect(fishScript.contains("complete -c hotkeyd"), "fish completion registers complete -c hotkeyd")
    expect(fishScript.contains("__complete shortcuts --enabled"), "fish completion filters enabled shortcuts for disable")
    expect(fishScript.contains("__complete shortcuts --disabled"), "fish completion filters disabled shortcuts for enable")

    for spec in CommandRegistry.commands {
        if let first = spec.path.first {
            expect(zshScript.contains(first), "zsh script covers command '\(first)'")
            expect(bashScript.contains(first), "bash script covers command '\(first)'")
            expect(fishScript.contains(first), "fish script covers command '\(first)'")
        }
        if spec.path.count > 1, let sub = spec.path.last {
            expect(zshScript.contains(sub), "zsh script covers subcommand '\(spec.displayName)'")
            expect(bashScript.contains(sub), "bash script covers subcommand '\(spec.displayName)'")
            expect(fishScript.contains(sub), "fish script covers subcommand '\(spec.displayName)'")
        }
    }

    let zshFile = root.appendingPathComponent("_hotkeyd")
    let bashFile = root.appendingPathComponent("hotkeyd.bash")
    try? Data(zshScript.utf8).write(to: zshFile)
    try? Data(bashScript.utf8).write(to: bashFile)

    let zshLint = ShellRunner.runSystemTool(
        executablePath: "/bin/zsh",
        arguments: ["/bin/zsh", "-n", zshFile.path],
        timeoutMilliseconds: 5_000
    )
    expectEqual(zshLint.exitCode, 0, "generated zsh completion passes `zsh -n` syntax check (stderr: \(zshLint.stderr))")

    let bashLint = ShellRunner.runSystemTool(
        executablePath: "/bin/bash",
        arguments: ["/bin/bash", "-n", bashFile.path],
        timeoutMilliseconds: 5_000
    )
    expectEqual(bashLint.exitCode, 0, "generated bash completion passes `bash -n` syntax check (stderr: \(bashLint.stderr))")

    // Bare `hotkeyd peek --search/--terminal/--query` default-action flag completion across all 3 shells
    expect(zshScript.contains("if [[ \"${words[2]}\" == -* ]]; then"), "zsh completion supports bare `hotkeyd peek --...` flags without typing `toggle`")
    expect(bashScript.contains("if [[ \"$subcmd\" == -* ]]; then"), "bash completion supports bare `hotkeyd peek --...` flags without typing `toggle`")
    expect(fishScript.contains("__fish_seen_subcommand_from peek; and not __fish_seen_subcommand_from status enable disable set"), "fish completion supports bare `hotkeyd peek --...` flags without typing `toggle`")

    // 3. Man page generation & strict `mandoc -Tlint` check
    let manContent = ManPageGenerator.generate(version: "0.1.0")
    let manFile = root.appendingPathComponent("hotkeyd.1")
    try? Data(manContent.utf8).write(to: manFile)

    if fm.isExecutableFile(atPath: "/usr/bin/mandoc") {
        let mandocLint = ShellRunner.runSystemTool(
            executablePath: "/usr/bin/mandoc",
            arguments: ["/usr/bin/mandoc", "-Tlint", manFile.path],
            timeoutMilliseconds: 5_000
        )
        expectEqual(mandocLint.exitCode, 0, "generated hotkeyd.1 passes `mandoc -Tlint` cleanly (stderr: \(mandocLint.stderr))")
        expect(
            mandocLint.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && mandocLint.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "generated hotkeyd.1 produces zero mandoc lint warnings (out: \(mandocLint.stdout) err: \(mandocLint.stderr))"
        )

        let renderedFile = root.appendingPathComponent("hotkeyd.txt")
        let renderRes = ShellRunner.run(
            command: "/usr/bin/mandoc -Tutf8 '\(manFile.path)' | /usr/bin/col -b > '\(renderedFile.path)'",
            cwd: root.path,
            timeoutMilliseconds: 5_000
        )
        expectEqual(renderRes.exitCode, 0, "`mandoc -Tutf8` renders hotkeyd.1 cleanly")
        let rendered = (try? String(contentsOf: renderedFile, encoding: .utf8)) ?? ""
        for heading in ["NAME", "SYNOPSIS", "DESCRIPTION", "COMMANDS", "KEY SYNTAX", "CONFIGURATION", "ENVIRONMENT", "FILES", "EXIT STATUS", "EXAMPLES", "SEE ALSO"] {
            expect(rendered.contains(heading), "rendered man page includes \(heading) section")
        }
        expect(rendered.contains("hotkeyd init"), "rendered man page documents hotkeyd init")
        expect(rendered.contains("hotkeyd completions"), "rendered man page documents hotkeyd completions")
        expect(rendered.contains("hotkeyd man"), "rendered man page documents hotkeyd man")
        expect(rendered.contains("Peek Overlay & Spotlight Search"), "rendered man page includes Peek Overlay & Spotlight Search subsection")
        expect(rendered.contains("hotkeyd peek --search"), "rendered man page documents hotkeyd peek --search")
    }

    // 4. End-to-end CLI tests in isolated HOTKEYD_HOME sandbox
    let selfPath = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let cliURL = selfPath.deletingLastPathComponent().appendingPathComponent("hotkeyd")
    guard fm.isExecutableFile(atPath: cliURL.path) else { return }

    let cliHome = root.appendingPathComponent("cli-home")
    try? fm.createDirectory(at: cliHome, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

    func runCompCLI(_ args: String) -> ShellResult {
        ShellRunner.run(
            command: "HOTKEYD_HOME='\(cliHome.path)' '\(cliURL.path)' \(args)",
            cwd: cliHome.path,
            timeoutMilliseconds: 10_000
        )
    }

    expectEqual(runCompCLI("completions --help").exitCode, 0, "`hotkeyd completions --help` exits 0")
    expectEqual(runCompCLI("man --help").exitCode, 0, "`hotkeyd man --help` exits 0")
    expectEqual(runCompCLI("completions").exitCode, 2, "`hotkeyd completions` without shell exits 2")
    expectEqual(runCompCLI("completions tcsh").exitCode, 2, "`hotkeyd completions tcsh` exits 2")

    // Missing config: `__complete shortcuts` fails silently (exit 0, empty stdout/stderr)
    let silentMissing = runCompCLI("__complete shortcuts")
    expectEqual(silentMissing.exitCode, 0, "`hotkeyd __complete shortcuts` exits 0 when config is missing")
    expect(silentMissing.stdout.isEmpty && silentMissing.stderr.isEmpty, "`hotkeyd __complete shortcuts` stays silent when config is missing")

    // Install completions (zsh, bash, fish) and man page into HOTKEYD_HOME sandbox
    let zshInstall = runCompCLI("completions zsh --install --json")
    expectEqual(zshInstall.exitCode, 0, "`hotkeyd completions zsh --install --json` exits 0")
    expect(zshInstall.stdout.contains("\"installed\" : true"), "completions --install --json reports installed=true")
    let installedZsh = cliHome.appendingPathComponent("completions/zsh/_hotkeyd")
    expect(fm.fileExists(atPath: installedZsh.path), "zsh completion installed inside HOTKEYD_HOME")

    expectEqual(runCompCLI("completions bash --install").exitCode, 0, "`hotkeyd completions bash --install` exits 0")
    expect(fm.fileExists(atPath: cliHome.appendingPathComponent("completions/bash/hotkeyd").path), "bash completion installed inside HOTKEYD_HOME")

    expectEqual(runCompCLI("completions fish --install").exitCode, 0, "`hotkeyd completions fish --install` exits 0")
    expect(fm.fileExists(atPath: cliHome.appendingPathComponent("completions/fish/hotkeyd.fish").path), "fish completion installed inside HOTKEYD_HOME")

    let manInstall = runCompCLI("man --install --json")
    expectEqual(manInstall.exitCode, 0, "`hotkeyd man --install --json` exits 0")
    let installedMan = cliHome.appendingPathComponent("share/man/man1/hotkeyd.1")
    expect(fm.fileExists(atPath: installedMan.path), "man page installed inside HOTKEYD_HOME")
    var manSt = stat()
    expectEqual(lstat(installedMan.path, &manSt), 0, "installed man page stat succeeds")
    expectEqual(manSt.st_mode & 0o777, 0o644, "installed man page has mode 0644")

    // M6 security test: symlinked intermediate dir inside HOTKEYD_HOME must not escape sandbox
    let escapeOutside = root.appendingPathComponent("escape-outside")
    try? fm.createDirectory(at: escapeOutside, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let escapeHome = root.appendingPathComponent("escape-home")
    try? fm.createDirectory(at: escapeHome, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try? fm.createSymbolicLink(
        atPath: escapeHome.appendingPathComponent("share").path,
        withDestinationPath: escapeOutside.path
    )
    let escapeRes = ShellRunner.run(
        command: "HOTKEYD_HOME='\(escapeHome.path)' '\(cliURL.path)' man --install --json",
        cwd: escapeHome.path,
        timeoutMilliseconds: 10_000
    )
    expectEqual(escapeRes.exitCode, 7, "M6: `man --install` refuses symlinked intermediate dir inside HOTKEYD_HOME")
    expect(!fm.fileExists(atPath: escapeOutside.appendingPathComponent("man/man1/hotkeyd.1").path), "M6: symlinked intermediate dir cannot write outside HOTKEYD_HOME")

    // M4 security test: ShellCompletions.sanitizeField strips C1 CSI and Unicode Bidi overrides
    let c1Bidi = "ok\u{001B}[31m\u{009B}2J\u{202E}evil"
    let sanitizedField = ShellCompletions.sanitizeField(c1Bidi, limit: 80)
    expect(!sanitizedField.contains("\u{001B}") && !sanitizedField.contains("\u{009B}") && !sanitizedField.contains("\u{202E}"), "M4: sanitizeField strips ESC, C1 CSI, and Bidi override")

    // Dynamic `__complete shortcuts` against real sandbox config
    let sandboxCfg = cliHome.appendingPathComponent(".hotkeyd")
    try? sampleConfig.save(to: sandboxCfg)

    let compAll = runCompCLI("__complete shortcuts")
    expectEqual(compAll.exitCode, 0, "`hotkeyd __complete shortcuts` exits 0")
    expect(compAll.stdout.contains("Chrome\t"), "TSV dynamic completion includes Chrome with tab description")
    expect(compAll.stdout.contains("fn > q\t"), "TSV dynamic completion includes sequence 'fn > q'")

    let compEnabled = runCompCLI("__complete shortcuts --enabled --plain")
    expectEqual(compEnabled.exitCode, 0, "`hotkeyd __complete shortcuts --enabled --plain` exits 0")
    expect(compEnabled.stdout.contains("Chrome\n"), "plain enabled completion includes Chrome")
    expect(!compEnabled.stdout.contains("DisabledTerm"), "plain enabled completion excludes DisabledTerm")

    let compDisabled = runCompCLI("__complete shortcuts --disabled --plain")
    expectEqual(compDisabled.exitCode, 0, "`hotkeyd __complete shortcuts --disabled --plain` exits 0")
    expect(compDisabled.stdout.contains("DisabledTerm\n"), "plain disabled completion includes DisabledTerm")
    expect(!compDisabled.stdout.contains("Chrome"), "plain disabled completion excludes Chrome")

    let compKeys = runCompCLI("__complete keys")
    expectEqual(compKeys.exitCode, 0, "`hotkeyd __complete keys` exits 0")
    expect(compKeys.stdout.contains("lcmd\t") && compKeys.stdout.contains("capsLock\t"), "`__complete keys` lists modifiers")

    // H1 security test: execute generated Bash completion against `fn > q`, spaces, and shell metacharacters
    let bashExecDir = root.appendingPathComponent("bash-exec-cwd")
    try? fm.createDirectory(at: bashExecDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let hostileConfig = Config(shortcuts: [
        Shortcut(keys: .sequence(KeySequence(leader: .fn, keyCode: 12)), tap: "open -a Safari", name: "Google Chrome"),
        Shortcut(keys: .modifier(.leftOption), doubleTap: "echo ok", name: "pwn$(touch canary);echo_bad")
    ])
    try? hostileConfig.save(to: sandboxCfg)
    let bashBinDir = cliURL.deletingLastPathComponent().path
    let bashHarness = root.appendingPathComponent("test-bash-comp.sh")
    let harnessSource = """
    set -euo pipefail
    export PATH="\(bashBinDir):$PATH"
    export HOTKEYD_HOME="\(cliHome.path)"
    source "\(bashFile.path)"
    COMPREPLY=()
    _hotkeyd_complete_dynamic shortcuts "" ""
    for reply in "${COMPREPLY[@]}"; do
      eval "printf 'EVAL=%s\\n' $reply"
    done
    """
    try? Data((harnessSource + "\n").utf8).write(to: bashHarness)
    let bashRuntimeRes = ShellRunner.run(
        command: "/bin/bash '\(bashHarness.path)'",
        cwd: bashExecDir.path,
        timeoutMilliseconds: 10_000
    )
    expectEqual(bashRuntimeRes.exitCode, 0, "Bash _hotkeyd_complete_dynamic executes cleanly with hostile shortcut names")
    expect(bashRuntimeRes.stdout.contains("EVAL=fn > q\n"), "Bash completion preserves literal 'fn > q' without redirection")
    expect(bashRuntimeRes.stdout.contains("EVAL=Google Chrome\n"), "Bash completion preserves literal 'Google Chrome' as one token")
    expect(bashRuntimeRes.stdout.contains("EVAL=pwn$(touch canary);echo_bad\n"), "Bash completion quotes shell metacharacters literally")
    expect(!fm.fileExists(atPath: bashExecDir.appendingPathComponent("q").path), "Bash completion of 'fn > q' does not clobber file 'q'")
    expect(!fm.fileExists(atPath: bashExecDir.appendingPathComponent("canary").path), "Bash completion does not execute $(touch canary)")
}

func testStatsAnalyzerAndCLI() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("hotkeyd-stats-test-\(UUID().uuidString)")
    try? fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: root) }

    // 1. StatsWindow parser
    let refNow = Date(timeIntervalSince1970: 1_795_200_000)
    expectEqual(StatsWindow.parse("all", now: refNow)?.label, "all", "StatsWindow parses 'all'")
    expect(StatsWindow.parse("all", now: refNow)?.cutoff == nil, "'all' window has nil cutoff")
    expectEqual(StatsWindow.parse("7d", now: refNow)?.label, "7d", "StatsWindow parses '7d'")
    expectEqual(StatsWindow.parse("24h", now: refNow)?.label, "24h", "StatsWindow parses '24h'")
    expectEqual(StatsWindow.parse("30m", now: refNow)?.label, "30m", "StatsWindow parses '30m'")
    expectEqual(StatsWindow.parse("2w", now: refNow)?.label, "2w", "StatsWindow parses '2w'")
    expectEqual(StatsWindow.parse("2026-11-19", now: refNow)?.label, "2026-11-19", "StatsWindow parses YYYY-MM-DD")
    expect(StatsWindow.parse("0d", now: refNow) == nil, "StatsWindow rejects 0d")
    expect(StatsWindow.parse("-5d", now: refNow) == nil, "StatsWindow rejects negative duration")
    expect(StatsWindow.parse("bogus", now: refNow) == nil, "StatsWindow rejects bogus window")

    // 2. Action log line parser (including spaces in shortcut names, stderr, timeout, dropped)
    let spaceNameLine = "2026-11-20T01:17:32.620Z action shortcut=VS Code exit=0 38ms action=open -a \"Visual Studio Code\""
    if case .event(let parsed) = StatsAnalyzer.parseActionLogLine(spaceNameLine) {
        expectEqual(parsed.shortcutName, "VS Code", "parses shortcut name with spaces verbatim")
        expectEqual(parsed.outcome, .exited(0), "parses exit=0")
        expectEqual(parsed.durationMs, 38, "parses duration 38ms")
        expectEqual(parsed.actionSummary, "open -a \"Visual Studio Code\"", "parses action summary")
    } else {
        expect(false, "failed to parse space-containing shortcut line")
    }

    let timeoutLine = "2026-11-20T02:00:00.000Z action shortcut=Slow Script timeout 30000ms action=sleep 60"
    if case .event(let parsed) = StatsAnalyzer.parseActionLogLine(timeoutLine) {
        expectEqual(parsed.shortcutName, "Slow Script", "parses timeout shortcut name with spaces")
        expectEqual(parsed.outcome, .timedOut, "parses timeout outcome")
        expectEqual(parsed.durationMs, 30_000, "parses timeout duration")
    } else {
        expect(false, "failed to parse timeout line")
    }

    let dropLine = "2026-11-20T02:01:00.000Z action shortcut=Heavy Job dropped (max 8 concurrent actions in flight)"
    if case .event(let parsed) = StatsAnalyzer.parseActionLogLine(dropLine) {
        expectEqual(parsed.shortcutName, "Heavy Job", "parses dropped shortcut name")
        expectEqual(parsed.outcome, .dropped, "parses dropped outcome")
        expect(parsed.durationMs == nil, "dropped entry has nil duration")
    } else {
        expect(false, "failed to parse dropped line")
    }

    let stderrLine = "2026-11-20T02:02:00.000Z action shortcut=Broken Script stderr=command not found"
    if case .stderr(_, let name, let msg) = StatsAnalyzer.parseActionLogLine(stderrLine) {
        expectEqual(name, "Broken Script", "parses stderr shortcut name")
        expectEqual(msg, "command not found", "parses stderr message")
    } else {
        expect(false, "failed to parse stderr line")
    }
    expect(StatsAnalyzer.parseActionLogLine("2026-11-20T02:00:00.000Z daemon fire doubleTap:lcmd -> Chrome") == nil, "ignores non-action lines")

    // M3 security test: huge/overflowing durationMs values are rejected on parse and never crash computeLatency
    expect(
        StatsAnalyzer.parseActionLogLine("2026-11-20T02:00:00.000Z action shortcut=Overflow exit=0 9223372036854775807ms action=echo hi") == nil,
        "M3: parseActionLogLine rejects Int.max durationMs above 24h cap"
    )
    let syntheticOverflowEvents: [ParsedActionLogLine] = [
        .event(ActionLogEntry(timestamp: refNow, shortcutName: "Huge", outcome: .exited(0), durationMs: Int.max, actionSummary: "echo hi")),
        .event(ActionLogEntry(timestamp: refNow, shortcutName: "Huge", outcome: .exited(0), durationMs: Int.max, actionSummary: "echo hi"))
    ]
    let overflowReport = StatsAnalyzer.aggregate(
        parsedLines: syntheticOverflowEvents,
        filesScanned: ["actions.log"],
        config: nil,
        window: StatsWindow(label: "all", cutoff: nil)
    )
    expectEqual(overflowReport.shortcuts.first?.avgMs, StatsAnalyzer.maxDurationMs, "M3: computeLatency clamps extreme durations without overflow crash")

    // M4 security test: StatsAnalyzer strips ESC / C1 / Bidi from shortcut names and command previews
    let escConfig = Config(shortcuts: [
        Shortcut(keys: .modifier(.leftControl), doubleTap: "echo \u{001B}[31mred\u{009B}2J", name: "Bad\u{001B}[31m\u{202E}Name", enabled: true)
    ])
    let escReport = StatsAnalyzer.aggregate(
        parsedLines: [],
        filesScanned: [],
        config: escConfig,
        window: StatsWindow(label: "all", cutoff: nil)
    )
    let unusedEsc = escReport.unusedShortcuts.first
    expect(
        unusedEsc != nil && !unusedEsc!.name.contains("\u{001B}") && !unusedEsc!.name.contains("\u{202E}")
            && !unusedEsc!.commandPreview.contains("\u{001B}") && !unusedEsc!.commandPreview.contains("\u{009B}"),
        "M4: StatsAnalyzer strips ESC, C1, and Bidi from unused shortcut name and command preview"
    )

    // 3. Aggregation across rotated actions.log.1 + actions.log, latency split, alerts, unused & removed
    let logsDir = root.appendingPathComponent("logs")
    try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

    let config = Config(shortcuts: [
        Shortcut(keys: .modifier(.leftCommand), doubleTap: "open -a \"Google Chrome\"", name: "Chrome", enabled: true),
        Shortcut(keys: .modifier(.leftShift), doubleTap: "open -a \"Visual Studio Code\"", name: "VS Code", enabled: true),
        Shortcut(keys: .combo(try! KeyCombo.parse("fn+r")), tap: "echo hi", name: "Slow Task", enabled: true),
        Shortcut(keys: .modifier(.rightCommand), doubleTap: "open ~", name: "Unused Home", enabled: true),
        Shortcut(keys: .modifier(.rightOption), doubleTap: "open -a Terminal", name: "Disabled Term", enabled: false)
    ])

    let rotatedLog = """
    2026-11-10T10:00:00.000Z action shortcut=lcmd exit=0 20ms action=open -a "Google Chrome"
    2026-11-10T10:05:00.000Z action shortcut=Old Renamed exit=0 50ms action=open -a Safari
    """
    let liveLog = """
    2026-11-20T01:00:00.000Z action shortcut=Chrome exit=0 30ms action=open -a "Google Chrome"
    2026-11-20T01:01:00.000Z action shortcut=Chrome exit=0 40ms action=open -a "Google Chrome"
    2026-11-20T01:02:00.000Z action shortcut=VS Code exit=0 25ms action=open -a "Visual Studio Code"
    2026-11-20T01:03:00.000Z action shortcut=Slow Task exit=0 1200ms action=echo hi
    2026-11-20T01:04:00.000Z action shortcut=Slow Task exit=1 400ms action=echo hi
    2026-11-20T01:04:00.001Z action shortcut=Slow Task stderr=boom failure
    """
    let rotatedURL = logsDir.appendingPathComponent("actions.log.1")
    let liveURL = logsDir.appendingPathComponent("actions.log")
    try? Data((rotatedLog + "\n").utf8).write(to: rotatedURL)
    try? Data((liveLog + "\n").utf8).write(to: liveURL)
    try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: rotatedURL.path)
    try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: liveURL.path)

    let reportAll = StatsAnalyzer.analyze(logsDirectory: logsDir, config: config)
    expectEqual(reportAll.filesScanned, ["actions.log.1", "actions.log"], "scans rotated actions.log.1 then actions.log")
    expectEqual(reportAll.totalEvents, 7, "counts 7 execution events (excluding stderr continuation line)")
    expectEqual(reportAll.successCount, 6, "counts 6 successes")
    expectEqual(reportAll.failureCount, 1, "counts 1 failure")
    expectEqual(reportAll.nativeSummary.count, 5, "classifies 5 native fast-path fires")
    expectEqual(reportAll.shellSummary.count, 2, "classifies 2 shell fires")
    expectEqual(reportAll.shortcuts.first?.name, "Chrome", "top shortcut is Chrome")
    expectEqual(reportAll.shortcuts.first?.count, 3, "Chrome has 3 fires across rotated + live logs")
    expectEqual(reportAll.shortcuts.first?.medianMs, 30, "Chrome median latency is 30ms")
    expectEqual(reportAll.shortcuts.first(where: { $0.name == "Old Renamed" })?.status, "removed", "unmatched historical shortcut marked removed")
    expectEqual(reportAll.shortcuts.first(where: { $0.name == "Slow Task" })?.lastError, "boom failure", "captures last stderr on failing shortcut")
    expect(reportAll.alerts.contains(where: { $0.kind == "failure" && $0.name == "Slow Task" }), "raises failure alert for Slow Task")
    expectEqual(reportAll.unusedShortcuts.map(\.name), ["Unused Home"], "lists only enabled unused shortcuts (excludes disabled)")

    // Trailing date window filters out Nov 10 rotated entries
    let sinceNov19 = StatsWindow.parse("2026-11-19")!
    let reportRecent = StatsAnalyzer.analyze(logsDirectory: logsDir, config: config, window: sinceNov19)
    expectEqual(reportRecent.totalEvents, 5, "--since 2026-11-19 filters out older Nov 10 entries")

    // Symlinked actions.log is refused (O_NOFOLLOW)
    let symLogsDir = root.appendingPathComponent("sym-logs")
    try? fm.createDirectory(at: symLogsDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try? fm.createSymbolicLink(atPath: symLogsDir.appendingPathComponent("actions.log").path, withDestinationPath: liveURL.path)
    let symReport = StatsAnalyzer.analyze(logsDirectory: symLogsDir, config: config)
    expectEqual(symReport.totalEvents, 0, "StatsAnalyzer refuses symlinked actions.log via O_NOFOLLOW")

    // High #1 security tests: 0600 enforcement, symlinked ancestor rejection, fast RFC3339 parser,
    // LogFingerprint change detection, and lightweight loadShortcutCounts
    let looseLogsDir = root.appendingPathComponent("loose-logs")
    try? fm.createDirectory(at: looseLogsDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let looseLogURL = looseLogsDir.appendingPathComponent("actions.log")
    try? Data((liveLog + "\n").utf8).write(to: looseLogURL)
    try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: looseLogURL.path)
    expectEqual(StatsAnalyzer.analyze(logsDirectory: looseLogsDir, config: config).totalEvents, 0, "High #1: StatsAnalyzer rejects 0644 group/world-readable actions.log")
    expect(StatsAnalyzer.loadShortcutCounts(logsDirectory: looseLogsDir).isEmpty, "High #1: loadShortcutCounts rejects 0644 actions.log")

    let realSub = root.appendingPathComponent("real-parent")
    let nestedLogs = realSub.appendingPathComponent("logs")
    try? fm.createDirectory(at: nestedLogs, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let nestedLogFile = nestedLogs.appendingPathComponent("actions.log")
    try? Data((liveLog + "\n").utf8).write(to: nestedLogFile)
    try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: nestedLogFile.path)
    let symParent = root.appendingPathComponent("sym-parent")
    try? fm.createSymbolicLink(atPath: symParent.path, withDestinationPath: realSub.path)
    let viaSymAncestor = symParent.appendingPathComponent("logs")
    expectEqual(StatsAnalyzer.analyze(logsDirectory: viaSymAncestor, config: config).totalEvents, 0, "High #1: StatsAnalyzer rejects symlinked ancestor directory")
    expect(StatsAnalyzer.loadShortcutCounts(logsDirectory: viaSymAncestor).isEmpty, "High #1: loadShortcutCounts rejects symlinked ancestor directory")

    // Fast allocation-free RFC3339 parser coverage (fractional, whole, timezone offsets, leap day, invalid dates)
    expect(StatsAnalyzer.parseActionLogLine("2024-02-29T23:59:59.500Z action shortcut=Leap exit=0 10ms action=echo ok") != nil, "High #1: RFC3339 parser accepts leap day with fractional Z")
    expect(StatsAnalyzer.parseActionLogLine("2026-11-20T12:00:00Z action shortcut=Whole exit=0 10ms action=echo ok") != nil, "High #1: RFC3339 parser accepts whole-second Z")
    if case .event(let plusTz) = StatsAnalyzer.parseActionLogLine("2026-11-20T17:30:00+05:30 action shortcut=TZ exit=0 10ms action=echo ok"),
       case .event(let utcRef) = StatsAnalyzer.parseActionLogLine("2026-11-20T12:00:00Z action shortcut=TZ exit=0 10ms action=echo ok") {
        expectEqual(Int(plusTz.timestamp.timeIntervalSince1970), Int(utcRef.timestamp.timeIntervalSince1970), "High #1: RFC3339 +05:30 offset converts accurately to UTC")
    } else {
        expect(false, "High #1: RFC3339 +05:30 offset line failed to parse")
    }
    if case .event(let minusTz) = StatsAnalyzer.parseActionLogLine("2026-11-20T06:00:00-06:00 action shortcut=TZ exit=0 10ms action=echo ok"),
       case .event(let utcRef) = StatsAnalyzer.parseActionLogLine("2026-11-20T12:00:00Z action shortcut=TZ exit=0 10ms action=echo ok") {
        expectEqual(Int(minusTz.timestamp.timeIntervalSince1970), Int(utcRef.timestamp.timeIntervalSince1970), "High #1: RFC3339 -06:00 offset converts accurately to UTC")
    } else {
        expect(false, "High #1: RFC3339 -06:00 offset line failed to parse")
    }
    expect(StatsAnalyzer.parseActionLogLine("2026-02-30T12:00:00Z action shortcut=Bad exit=0 10ms action=echo ok") == nil, "High #1: RFC3339 parser rejects invalid calendar day 2026-02-30")
    expect(StatsAnalyzer.parseActionLogLine("2026-13-01T12:00:00Z action shortcut=Bad exit=0 10ms action=echo ok") == nil, "High #1: RFC3339 parser rejects month 13")
    expect(StatsAnalyzer.parseActionLogLine("2026-11-20T25:00:00Z action shortcut=Bad exit=0 10ms action=echo ok") == nil, "High #1: RFC3339 parser rejects hour 25")

    // LogFingerprint stability & cache invalidation + lightweight loadShortcutCounts
    let fp1 = StatsAnalyzer.logsFingerprint(logsDirectory: logsDir)
    let fp2 = StatsAnalyzer.logsFingerprint(logsDirectory: logsDir)
    expectEqual(fp1, fp2, "High #1: logsFingerprint is deterministic across unchanged files")
    expect(fp1.rotated != nil && fp1.current != nil, "High #1: logsFingerprint tracks both actions.log.1 and actions.log")
    let counts = StatsAnalyzer.loadShortcutCounts(logsDirectory: logsDir)
    expectEqual(counts["chrome"], 2, "High #1: loadShortcutCounts tallies named Chrome events")
    expectEqual(counts["lcmd"], 1, "High #1: loadShortcutCounts tallies historical canonical lcmd events")
    let cachedSnap = PeekSearchBuilder.buildSnapshot(from: config, logsDirectory: nil, cachedUsageCounts: counts)
    expectEqual(cachedSnap.items.first?.label, "Chrome", "High #1: cachedUsageCounts ranks Chrome first without disk reads")
    expectEqual(cachedSnap.items.first?.usageCount, 3, "High #1: cachedUsageCounts merges displayName + canonical counts (2 + 1 = 3)")

    // 4. End-to-end CLI tests in isolated HOTKEYD_HOME sandbox
    let selfPath = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let cliURL = selfPath.deletingLastPathComponent().appendingPathComponent("hotkeyd")
    guard fm.isExecutableFile(atPath: cliURL.path) else { return }

    let cliHome = root.appendingPathComponent("cli-stats-home")
    let cliLogs = cliHome.appendingPathComponent("logs")
    try? fm.createDirectory(at: cliLogs, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

    func runStatsCLI(_ args: String) -> ShellResult {
        ShellRunner.run(
            command: "HOTKEYD_HOME='\(cliHome.path)' '\(cliURL.path)' \(args)",
            cwd: cliHome.path,
            timeoutMilliseconds: 10_000
        )
    }

    expectEqual(runStatsCLI("stats --help").exitCode, 0, "`hotkeyd stats --help` exits 0")
    expectEqual(runStatsCLI("stats --since bogus").exitCode, 2, "`hotkeyd stats --since bogus` exits 2")
    expectEqual(runStatsCLI("stats --top 0").exitCode, 2, "`hotkeyd stats --top 0` exits 2")

    // Empty sandbox exits 0 cleanly
    let emptyRes = runStatsCLI("stats --json")
    expectEqual(emptyRes.exitCode, 0, "`hotkeyd stats --json` exits 0 with no logs or config")
    expect(emptyRes.stdout.contains("\"totalEvents\" : 0"), "empty stats JSON reports totalEvents=0")

    // Populated sandbox (both rotated actions.log.1 and live actions.log)
    try? config.save(to: cliHome.appendingPathComponent(".hotkeyd"))
    try? Data((rotatedLog + "\n").utf8).write(to: cliLogs.appendingPathComponent("actions.log.1"))
    try? Data((liveLog + "\n").utf8).write(to: cliLogs.appendingPathComponent("actions.log"))
    try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cliLogs.appendingPathComponent("actions.log.1").path)
    try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cliLogs.appendingPathComponent("actions.log").path)

    let textRes = runStatsCLI("stats --unused")
    expectEqual(textRes.exitCode, 0, "`hotkeyd stats --unused` exits 0")
    expect(textRes.stdout.contains("TOP SHORTCUTS"), "text stats prints TOP SHORTCUTS")
    expect(textRes.stdout.contains("ALERTS"), "text stats prints ALERTS")
    expect(textRes.stdout.contains("Unused Home"), "text stats --unused lists Unused Home")

    let jsonTop = runStatsCLI("stats --top 1 --json")
    expectEqual(jsonTop.exitCode, 0, "`hotkeyd stats --top 1 --json` exits 0")
    expect(jsonTop.stdout.contains("\"totalEvents\" : 7"), "stats JSON reports 7 totalEvents across rotated + live logs")
    expect(jsonTop.stdout.contains("\"Chrome\""), "stats JSON top 1 includes Chrome")
    expect(!jsonTop.stdout.contains("\"VS Code\""), "stats JSON --top 1 truncates shortcuts array to 1")
}

func testPauseAndResume() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("hotkeyd-pause-test-\(UUID().uuidString)")
    try? fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: root) }

    // 1. Duration parsing & formatting
    expectEqual(PauseState.parseDurationSeconds("5s"), 5, "parses minimum 5s")
    expectEqual(PauseState.parseDurationSeconds("30s"), 30, "parses 30s")
    expectEqual(PauseState.parseDurationSeconds("15m"), 900, "parses 15m")
    expectEqual(PauseState.parseDurationSeconds("2h"), 7_200, "parses 2h")
    expectEqual(PauseState.parseDurationSeconds("1h30m"), 5_400, "parses compound 1h30m")
    expectEqual(PauseState.parseDurationSeconds("1h30m15s"), 5_415, "parses compound 1h30m15s")
    expectEqual(PauseState.parseDurationSeconds("24h"), 86_400, "parses maximum 24h")
    expect(PauseState.parseDurationSeconds("4s") == nil, "rejects < 5s")
    expect(PauseState.parseDurationSeconds("0s") == nil, "rejects 0s")
    expect(PauseState.parseDurationSeconds("25h") == nil, "rejects > 24h")
    expect(PauseState.parseDurationSeconds("10m10m") == nil, "rejects duplicate units")
    expect(PauseState.parseDurationSeconds("5m2h") == nil, "rejects out-of-order units")
    expect(PauseState.parseDurationSeconds("15") == nil, "rejects bare number without unit")
    expect(PauseState.parseDurationSeconds("-5m") == nil, "rejects negative duration")
    expectEqual(PauseState.formatDuration(900), "15m", "formats 900s as 15m")
    expectEqual(PauseState.formatDuration(5_400), "1h 30m", "formats 5400s as 1h 30m")
    expectEqual(PauseState.formatDuration(45), "45s", "formats 45s as 45s")

    // 2. PauseState persistence, expiry pruning, O_NOFOLLOW & 0600 enforcement
    let stateURL = root.appendingPathComponent("pause-state.json")
    let now = Date()
    let active = PauseState(pausedAtDate: now, durationSeconds: 600, reason: "  pairing\nwith team\t")
    expectEqual(active.reason, "pairing with team", "sanitizes newlines/tabs in reason")
    do {
        try active.save(to: stateURL)
        var st = stat()
        expectEqual(lstat(stateURL.path, &st), 0, "pause-state.json exists")
        expectEqual(st.st_mode & 0o777, 0o600, "pause-state.json saved with mode 0600")
        let loaded = PauseState.loadActive(from: stateURL, now: now)
        expectEqual(loaded, active, "PauseState round-trips via loadActive")
        expect(PauseState.loadActive(from: stateURL, now: now.addingTimeInterval(601), pruneExpired: true) == nil, "expired PauseState returns nil and prunes file")
        expect(!fm.fileExists(atPath: stateURL.path), "pruneExpired removes expired pause-state.json")

        // Loose permissions 0644 rejected
        try active.save(to: stateURL)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: stateURL.path)
        expect(PauseState.load(from: stateURL) == nil, "PauseState.load rejects 0644 file")

        // Symlink rejected (O_NOFOLLOW)
        let decoy = root.appendingPathComponent("decoy-pause.json")
        try active.save(to: decoy)
        try fm.removeItem(at: stateURL)
        try fm.createSymbolicLink(atPath: stateURL.path, withDestinationPath: decoy.path)
        expect(PauseState.load(from: stateURL) == nil, "PauseState.load rejects symlink")
        try fm.removeItem(at: stateURL)
    } catch {
        expect(false, "PauseState persistence test failed: \(error)")
    }

    // M4 security test: PauseState Codable decoding sanitizes ESC, C1 CSI, Bidi, and enforces maxReasonLength
    let hostilePauseJSON = """
    {"pausedAt":"2026-11-20T00:00:00.000Z","reason":"hello\\u001b[31m\\u009b2J\\u202eevil\\n\(String(repeating: "x", count: 200))"}
    """
    if let decodedHostile = try? JSONDecoder().decode(PauseState.self, from: Data(hostilePauseJSON.utf8)),
       let cleanReason = decodedHostile.reason {
        expect(!cleanReason.contains("\u{001B}") && !cleanReason.contains("\u{009B}") && !cleanReason.contains("\u{202E}") && !cleanReason.contains("\n"), "M4: PauseState Decodable strips ESC, C1, Bidi, and newlines")
        expect(cleanReason.count <= PauseState.maxReasonLength, "M4: PauseState Decodable enforces maxReasonLength")
    } else {
        expect(false, "failed to decode hostile PauseState JSON")
    }

    // 3. RuntimeState backwards-compatible decoding without paused fields
    let legacyRuntimeJSON = """
    {"activeBindings":3,"binaryPath":"/Users/test/.local/bin/hotkeyd","capsRemapped":false,"configPath":"/Users/test/.hotkeyd","configValid":true,"pid":4242,"secureInputActive":false,"startedAt":"2026-11-20T00:00:00.000Z","tapActive":true,"tapNote":"listening","updatedAt":"2026-11-20T00:00:01.000Z"}
    """
    if let decoded = try? JSONDecoder().decode(RuntimeState.self, from: Data(legacyRuntimeJSON.utf8)) {
        expectEqual(decoded.paused, false, "legacy RuntimeState decodes with paused=false default")
        expect(decoded.pausedUntil == nil && decoded.pauseReason == nil, "legacy RuntimeState decodes nil pause metadata")
    } else {
        expect(false, "failed to decode legacy RuntimeState JSON without pause fields")
    }

    // 4. End-to-end CLI tests in isolated HOTKEYD_HOME sandbox
    let selfPath = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let cliURL = selfPath.deletingLastPathComponent().appendingPathComponent("hotkeyd")
    guard fm.isExecutableFile(atPath: cliURL.path) else { return }

    let cliHome = root.appendingPathComponent("cli-pause-home")
    try? fm.createDirectory(at: cliHome, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

    func runPauseCLI(_ args: String) -> ShellResult {
        ShellRunner.run(
            command: "HOTKEYD_HOME='\(cliHome.path)' '\(cliURL.path)' \(args)",
            cwd: cliHome.path,
            timeoutMilliseconds: 10_000
        )
    }

    expectEqual(runPauseCLI("pause --help").exitCode, 0, "`hotkeyd pause --help` exits 0")
    expectEqual(runPauseCLI("resume --help").exitCode, 0, "`hotkeyd resume --help` exits 0")
    expectEqual(runPauseCLI("pause --for bogus").exitCode, 2, "`hotkeyd pause --for bogus` exits 2")
    expectEqual(runPauseCLI("pause --for 25h").exitCode, 2, "`hotkeyd pause --for 25h` exits 2")

    // Timed pause with reason
    let pauseTimed = runPauseCLI("pause --for 15m --reason pairing --json")
    expectEqual(pauseTimed.exitCode, 0, "`hotkeyd pause --for 15m --reason pairing --json` exits 0")
    expect(pauseTimed.stdout.contains("\"paused\" : true"), "pause JSON reports paused=true")
    expect(pauseTimed.stdout.contains("\"reason\" : \"pairing\""), "pause JSON reports reason")
    let sandboxPauseFile = cliHome.appendingPathComponent("pause-state.json")
    expect(fm.fileExists(atPath: sandboxPauseFile.path), "pause creates pause-state.json in HOTKEYD_HOME")

    // Status reflects paused state
    let statusPaused = runPauseCLI("status --json")
    expectEqual(statusPaused.exitCode, 0, "`hotkeyd status --json` exits 0 while paused")
    expect(statusPaused.stdout.contains("\"paused\" : true"), "status JSON reports paused=true")
    expect(statusPaused.stdout.contains("\"pauseReason\" : \"pairing\""), "status JSON reports pauseReason")

    // --toggle resumes when already paused
    let toggleOff = runPauseCLI("pause --toggle --json")
    expectEqual(toggleOff.exitCode, 0, "`hotkeyd pause --toggle --json` resumes when paused")
    expect(toggleOff.stdout.contains("\"paused\" : false"), "toggle off JSON reports paused=false")
    expect(!fm.fileExists(atPath: sandboxPauseFile.path), "toggle off removes pause-state.json")

    // --toggle pauses indefinitely when active
    let toggleOn = runPauseCLI("pause --toggle --json")
    expectEqual(toggleOn.exitCode, 0, "`hotkeyd pause --toggle --json` pauses when active")
    expect(toggleOn.stdout.contains("\"paused\" : true"), "toggle on JSON reports paused=true")
    expect(fm.fileExists(atPath: sandboxPauseFile.path), "toggle on writes pause-state.json")

    // Explicit resume & idempotent second resume
    let resume1 = runPauseCLI("resume --json")
    expectEqual(resume1.exitCode, 0, "`hotkeyd resume --json` exits 0")
    expect(resume1.stdout.contains("\"paused\" : false"), "resume JSON reports paused=false")
    expect(resume1.stdout.contains("\"alreadyInState\" : false"), "first resume reports alreadyInState=false")

    let resume2 = runPauseCLI("resume --json")
    expectEqual(resume2.exitCode, 0, "idempotent second `hotkeyd resume --json` exits 0")
    expect(resume2.stdout.contains("\"alreadyInState\" : true"), "second resume reports alreadyInState=true")
}

func testPeekOverlayAndCLI() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("hotkeyd-peek-test-\(UUID().uuidString)")
    try? fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: root) }

    // 1. PeekConfig defaults, activeTriggers, matchesTrigger, and strict validation
    let def = PeekConfig.default
    expect(!def.enabled, "PeekConfig default enabled is false (opt-in)")
    expectEqual(def.triggers, [.fn], "PeekConfig default triggers are [fn] only")
    expectEqual(def.delayMilliseconds, 450, "PeekConfig default delayMs is 450")
    expect(def.toggle == nil, "PeekConfig default toggle is nil")
    expect(!def.showDisabled, "PeekConfig default showDisabled is false")
    expect(def.isDefault, "PeekConfig.default reports isDefault=true")
    expectEqual(def.activeTriggers(capsLockRemapped: true), [], "disabled default peek reports zero active triggers")

    let withCapsTrigger = PeekConfig(enabled: true, triggers: [.fn, .capsLock])
    expectEqual(withCapsTrigger.activeTriggers(capsLockRemapped: false), [.fn], "capsLock trigger stays dormant when capsLock is not remapped")
    expectEqual(withCapsTrigger.activeTriggers(capsLockRemapped: true), [.fn, .capsLock], "capsLock trigger activates when capsLock is remapped")
    expect(withCapsTrigger.isCapsLockTriggerDormant(hasCapsLockBinding: false), "reports capsLock trigger dormant without capsLock bindings")
    expect(!withCapsTrigger.isCapsLockTriggerDormant(hasCapsLockBinding: true), "capsLock trigger not dormant with capsLock bindings")

    let sidedPeek = PeekConfig(enabled: true, triggers: [.leftCommand, .option])
    expect(sidedPeek.matchesTrigger(.leftCommand, capsLockRemapped: false), "lcmd trigger matches lcmd")
    expect(!sidedPeek.matchesTrigger(.rightCommand, capsLockRemapped: false), "lcmd trigger does not match rcmd")
    expect(sidedPeek.matchesTrigger(.leftOption, capsLockRemapped: false), "unsided opt trigger matches lopt")
    expect(sidedPeek.matchesTrigger(.rightOption, capsLockRemapped: false), "unsided opt trigger matches ropt")

    // Default peek is omitted from formattedJSON; non-default peek serializes & round-trips cleanly
    do {
        let defaultCfg = Config(shortcuts: [
            Shortcut(keys: .combo(try KeyCombo.parse("fn+space")), tap: "open -a Terminal", name: "Term")
        ])
        let defaultJSON = String(decoding: try defaultCfg.formattedJSON(), as: UTF8.self)
        expect(!defaultJSON.contains("\"peek\""), "Config.formattedJSON omits default peek block")

        let customPeek = PeekConfig(
            enabled: true,
            triggers: [.fn, .leftCommand],
            delayMilliseconds: 650,
            toggle: .sequence(try KeySequence.parse("fn:/")),
            showDisabled: true,
            dimUnmatched: false
        )
        let customCfg = Config(shortcuts: defaultCfg.shortcuts, peek: customPeek)
        try customCfg.validate()
        let customJSON = try customCfg.formattedJSON()
        let customText = String(decoding: customJSON, as: UTF8.self)
        expect(customText.contains("\"peek\":"), "Config.formattedJSON includes non-default peek block")
        expect(customText.contains("\"fn > slash\""), "Config.formattedJSON serializes sequence toggle canonically")
        expect(customText.contains("\"dimUnmatched\": false"), "Config.formattedJSON serializes dimUnmatched=false")
        let decoded = try JSONDecoder().decode(Config.self, from: customJSON)
        expectEqual(decoded.peek, customPeek, "Config with custom peek (sequence toggle + dimUnmatched) round-trips losslessly")

        // Caps Lock remap requirement: default triggers alone do NOT require remap, enabled capsLock toggle DOES
        expect(!Config(shortcuts: defaultCfg.shortcuts).requiresCapsLockRemap, "default peek triggers alone do not require Caps Lock remap")
        let disabledCapsToggleCfg = Config(shortcuts: defaultCfg.shortcuts, peek: PeekConfig(enabled: false, toggle: .sequence(try KeySequence.parse("capsLock:/"))))
        expect(!disabledCapsToggleCfg.requiresCapsLockRemap, "disabled peek with capsLock toggle does not activate Caps Lock remap")
        let capsToggleCfg = Config(shortcuts: defaultCfg.shortcuts, peek: PeekConfig(enabled: true, toggle: .sequence(try KeySequence.parse("capsLock:/"))))
        try capsToggleCfg.validate()
        expect(capsToggleCfg.requiresCapsLockRemap, "enabled capsLock peek.toggle activates requiresCapsLockRemap")
    } catch {
        expect(false, "PeekConfig round-trip failed: \(error)")
    }

    // Strict decoding & validation guards
    expectThrows("PeekConfig rejects unknown JSON key") {
        let bad = Data("{\"peek\":{\"bogus\":true},\"shortcuts\":[]}".utf8)
        return try JSONDecoder().decode(Config.self, from: bad)
    }
    expectThrows("PeekConfig rejects delayMs below 300ms floor") {
        let cfg = Config(shortcuts: [], peek: PeekConfig(delayMilliseconds: 299))
        try cfg.validate()
    }
    expectThrows("PeekConfig rejects delayMs above 2000ms ceiling") {
        let cfg = Config(shortcuts: [], peek: PeekConfig(delayMilliseconds: 2001))
        try cfg.validate()
    }
    expectThrows("PeekConfig rejects duplicate triggers") {
        let cfg = Config(shortcuts: [], peek: PeekConfig(triggers: [.fn, .fn]))
        try cfg.validate()
    }
    expectThrows("PeekConfig rejects overlapping side + unsided triggers") {
        let cfg = Config(shortcuts: [], peek: PeekConfig(triggers: [.command, .leftCommand]))
        try cfg.validate()
    }
    expectThrows("PeekConfig rejects combo toggle colliding with enabled shortcut") {
        let combo = try KeyCombo.parse("fn+/")
        let cfg = Config(
            shortcuts: [Shortcut(keys: .combo(combo), tap: "echo hi", name: "Slash")],
            peek: PeekConfig(toggle: .combo(combo))
        )
        try cfg.validate()
    }
    expectThrows("PeekConfig rejects sequence toggle colliding with enabled sequence") {
        let seq = try KeySequence.parse("fn > q")
        let cfg = Config(
            shortcuts: [Shortcut(keys: .sequence(seq), tap: "echo hi", name: "SeqQ")],
            peek: PeekConfig(toggle: .sequence(seq))
        )
        try cfg.validate()
    }
    expectThrows("PeekConfig rejects modifier toggle colliding with enabled modifier double-tap") {
        let cfg = Config(
            shortcuts: [Shortcut(keys: .modifier(.rightCommand), doubleTap: "echo hi", name: "Rcmd")],
            peek: PeekConfig(toggle: .modifier(.rightCommand))
        )
        try cfg.validate()
    }
    expectThrows("PeekConfig rejects F18 toggle when capsLock shortcut is enabled") {
        let cfg = Config(
            shortcuts: [Shortcut(keys: .modifier(.capsLock), doubleTap: "echo hi")],
            peek: PeekConfig(toggle: .combo(try KeyCombo.parse("f18")))
        )
        try cfg.validate()
    }

    // 2. KeycapFormatter (side-aware pills & display strings)
    do {
        expectEqual(KeycapFormatter.displayString(for: .modifier(.leftCommand), isDoubleTap: true), "L⌘ 2×", "lcmd formats as L⌘ 2×")
        expectEqual(KeycapFormatter.displayString(for: .modifier(.rightCommand), isDoubleTap: true), "R⌘ 2×", "rcmd formats as R⌘ 2×")
        expectEqual(KeycapFormatter.displayString(for: .modifier(.command), isDoubleTap: true), "⌘ 2×", "unsided cmd formats as ⌘ 2×")
        expectEqual(KeycapFormatter.displayString(for: .sequence(try KeySequence.parse("fn > q")), isDoubleTap: false), "fn › Q", "fn > q formats as fn › Q")
        expectEqual(KeycapFormatter.displayString(for: .combo(try KeyCombo.parse("fn+escape")), isDoubleTap: true), "fn + Esc 2×", "fn+escape doubleTap formats as fn + Esc 2×")
        expectEqual(KeycapFormatter.displayString(for: .combo(try KeyCombo.parse("capsLock+space")), isDoubleTap: false), "⇪ + Space", "capsLock+space formats as ⇪ + Space")
    } catch {
        expect(false, "KeycapFormatter test failed: \(error)")
    }

    // 3. PeekLabeler (smart labels + URL query/userinfo redaction + control-char stripping)
    do {
        let named = Shortcut(keys: .modifier(.leftCommand), doubleTap: "echo x", name: "My\u{001B}[31m\u{202E}App")
        let namedLabel = PeekLabeler.label(for: named, command: "echo x")
        expect(!namedLabel.contains("\u{001B}") && !namedLabel.contains("\u{202E}"), "PeekLabeler strips ESC and Bidi controls")

        let appShortcut = Shortcut(keys: .combo(try KeyCombo.parse("fn+a")), tap: "open -a \"/Applications/Google Chrome.app\"")
        expectEqual(PeekLabeler.label(for: appShortcut, command: appShortcut.activeCommand), "Google Chrome", "PeekLabeler strips .app path from unnamed app action")

        let urlShortcut = Shortcut(
            keys: .combo(try KeyCombo.parse("fn+u")),
            tap: "open 'https://alice:secret@www.github.com/org/repo?token=topsecret#frag'"
        )
        let urlLabel = PeekLabeler.label(for: urlShortcut, command: urlShortcut.activeCommand)
        expectEqual(urlLabel, "github.com/org/repo", "PeekLabeler strips userinfo, www., query string, and fragment from unnamed URLs")
        expect(!urlLabel.contains("secret") && !urlLabel.contains("token"), "URL secrets never appear in peek label")

        let homePath = Paths.realHomeDirectory.appendingPathComponent("Downloads").path
        let pathShortcut = Shortcut(keys: .combo(try KeyCombo.parse("fn+d")), tap: "open '\(homePath)'")
        expectEqual(PeekLabeler.label(for: pathShortcut, command: pathShortcut.activeCommand), "~/Downloads", "PeekLabeler shortens home prefix to ~")
    } catch {
        expect(false, "PeekLabeler test failed: \(error)")
    }

    // 4. PeekModel auto-grouping, smart-focus hold, live-narrowing, and zero-match fallback
    do {
        let sample = Config(shortcuts: [
            Shortcut(keys: .combo(try KeyCombo.parse("fn+space")), tap: "open -a Terminal", name: "Terminal"),
            Shortcut(keys: .combo(try KeyCombo.parse("fn+shift+s")), tap: "echo shot", name: "Screenshot"),
            Shortcut(keys: .sequence(try KeySequence.parse("fn > q")), tap: "open -a Safari", name: "Safari"),
            Shortcut(keys: .combo(try KeyCombo.parse("capsLock+h")), tap: "echo left", name: "Window Left"),
            Shortcut(keys: .modifier(.leftCommand), doubleTap: "open -a \"Google Chrome\"", name: "Chrome"),
            Shortcut(keys: .combo(try KeyCombo.parse("fn+z")), tap: "echo off", name: "DisabledOne", enabled: false)
        ])

        // Pinned mode hides disabled by default & highlights all groups
        let pinned = PeekModel.buildSnapshot(from: sample, mode: .pinned)
        expectEqual(pinned.totalCount, 5, "pinned snapshot excludes disabled shortcuts by default")
        expect(pinned.groups.allSatisfy(\.highlighted), "pinned snapshot highlights all groups")
        expectEqual(pinned.groups.map(\.title), ["fn + …", "fn › …", "⇪ Caps Lock + …", "Double-Tap Modifiers"], "auto-groups in deterministic trigger-family order, omitting empty groups")

        let pinnedWithDisabled = PeekModel.buildSnapshot(from: sample, mode: .pinned, showDisabledOverride: true)
        expectEqual(pinnedWithDisabled.totalCount, 6, "showDisabled includes disabled shortcuts")
        expect(pinnedWithDisabled.groups.flatMap(\.entries).contains { $0.label == "DisabledOne" && $0.badges.contains("disabled") }, "disabled shortcut carries disabled badge")

        // Hold `fn`: calm uniform overview of all shortcuts (zero fn bias), advertises Tab to pin
        let holdFn = PeekModel.buildSnapshot(from: sample, mode: .hold, heldModifiers: [.fn])
        expectEqual(holdFn.title, "Shortcuts", "hold fn uses neutral 'Shortcuts' title")
        expectEqual(holdFn.matchedCount, 5, "hold fn shows all 5 shortcuts uniformly")
        expect(holdFn.groups.allSatisfy(\.highlighted), "hold fn keeps all groups highlighted (zero fn bias)")
        expect(holdFn.groups.flatMap(\.entries).allSatisfy(\.matched), "hold fn marks all entries matched")
        expect(holdFn.subtitle?.contains("Tab to pin") == true, "hold-peek footer advertises Tab to pin")
        expectEqual(holdFn.dimUnmatched, false, "hold snapshot does not dim unmatched groups")

        // Pinned + no modifier: full brightness + helper text for holding any modifier
        expect(pinned.subtitle?.contains("Hold any modifier") == true, "pinned footer hints holding any modifier to show related shortcuts")

        // Pinned + hold `fn`: in-place spotlight keeps exact group order, marks fn entries matched
        let pinnedFn = PeekModel.buildSnapshot(from: sample, mode: .pinned, heldModifiers: [.fn])
        expectEqual(pinnedFn.title, "Related to fn", "pinned spotlight title is 'Related to fn'")
        expectEqual(pinnedFn.matchedCount, 3, "pinned spotlight fn matches 2 fn combos + 1 fn sequence")
        expectEqual(pinnedFn.groups.map(\.title), pinned.groups.map(\.title), "pinned spotlight preserves exact group order (zero layout jump)")
        expectEqual(pinnedFn.groups.filter(\.highlighted).map(\.title), ["fn + …", "fn › …"], "pinned fn elevates fn+ and fn › cards")
        expectEqual(pinnedFn.groups.filter { !$0.highlighted }.map(\.title), ["⇪ Caps Lock + …", "Double-Tap Modifiers"], "non-matching cards are unhighlighted in place")
        expectEqual(pinnedFn.dimUnmatched, true, "default pinned spotlight sets dimUnmatched=true")

        let noDimSample = Config(shortcuts: sample.shortcuts, peek: PeekConfig(dimUnmatched: false))
        let pinnedNoDim = PeekModel.buildSnapshot(from: noDimSample, mode: .pinned, heldModifiers: [.fn])
        expectEqual(pinnedNoDim.dimUnmatched, false, "pinned spotlight propagates dimUnmatched=false")

        // Pinned + hold `lcmd`: spotlights Chrome inside Double-Tap Modifiers in place
        let pinnedLCmd = PeekModel.buildSnapshot(from: sample, mode: .pinned, heldModifiers: [.leftCommand])
        expectEqual(pinnedLCmd.matchedCount, 1, "pinned spotlight lcmd matches 1 shortcut")
        expectEqual(pinnedLCmd.groups.flatMap(\.entries).filter(\.matched).map(\.label), ["Chrome"], "pinned lcmd spotlights Chrome in place")

        // Pinned + live-narrow `fn + lshift`: spotlights only Screenshot in place without reshuffling
        let narrowFnShift = PeekModel.buildSnapshot(from: sample, mode: .pinned, heldModifiers: [.fn, .leftShift])
        expectEqual(narrowFnShift.matchedCount, 1, "pinned spotlight fn + lshift matches only fn+shift+s")
        expectEqual(narrowFnShift.groups.map(\.title), pinned.groups.map(\.title), "live-narrowing preserves exact card order")
        expectEqual(narrowFnShift.groups.flatMap(\.entries).filter(\.matched).map(\.label), ["Screenshot"], "pinned fn + lshift spotlights only Screenshot")

        // Pinned + zero-match hold: keeps all cards anchored with clear subtitle
        let zeroMatch = PeekModel.buildSnapshot(from: sample, mode: .pinned, heldModifiers: [.fn, .rightOption])
        expectEqual(zeroMatch.matchedCount, 0, "unmatched modifier combo reports matchedCount=0")
        expect(zeroMatch.subtitle?.contains("No shortcuts") == true, "zero-match subtitle explains no shortcuts")
        expectEqual(zeroMatch.groups.flatMap(\.entries).count, 5, "zero-match preserves all 5 entries in place")

        // 5. Wire protocol NDJSON encode/decode & size cap
        let showMsg = PeekWireMessage.show(holdFn)
        let encodedLine = showMsg.encodeLine()
        expect(encodedLine != nil, "PeekWireMessage.show encodes to NDJSON line")
        if let line = encodedLine {
            expectEqual(line.last, 0x0A, "NDJSON line terminates with newline")
            let trimmed = Data(line.dropLast())
            expectEqual(PeekWireMessage.decodeLine(trimmed), showMsg, "PeekWireMessage.show round-trips cleanly")
        }
        expectEqual(PeekWireMessage.decodeLine(Data("{\"op\":\"hide\"}".utf8)), .hide, "decodes hide op")
        expectEqual(PeekWireMessage.decodeLine(Data("{\"op\":\"quit\"}".utf8)), .quit, "decodes quit op")
        let huge = Data(repeating: 0x41, count: PeekWireMessage.maxFrameBytes + 1)
        expectNil(PeekWireMessage.decodeLine(huge), "rejects oversized wire frame above maxFrameBytes")

        // 6. Terminal card formatter (zero ANSI)
        let card = PeekTerminalFormatter.format(pinned, config: sample.peek)
        expect(card.contains("Hotkeyd Shortcuts (5 shortcuts)"), "terminal card includes title and count")
        expect(card.contains("fn › Q"), "terminal card renders side-aware keycaps")
        expect(!card.contains("\u{001B}"), "terminal card contains zero ANSI escape codes")
    } catch {
        expect(false, "PeekModel / wire / terminal tests failed: \(error)")
    }

    // 7. End-to-end sandboxed CLI tests under HOTKEYD_HOME
    let selfPath = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let cliURL = selfPath.deletingLastPathComponent().appendingPathComponent("hotkeyd")
    guard fm.isExecutableFile(atPath: cliURL.path) else { return }

    let cliHome = root.appendingPathComponent("cli-peek-home")
    try? fm.createDirectory(at: cliHome, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

    func runPeekCLI(_ args: String) -> ShellResult {
        ShellRunner.run(
            command: "HOTKEYD_HOME='\(cliHome.path)' '\(cliURL.path)' \(args)",
            cwd: cliHome.path,
            timeoutMilliseconds: 10_000
        )
    }

    expectEqual(runPeekCLI("peek --help").exitCode, 0, "`hotkeyd peek --help` exits 0")
    expectEqual(runPeekCLI("peek status --help").exitCode, 0, "`hotkeyd peek status --help` exits 0")
    expectEqual(runPeekCLI("peek set --help").exitCode, 0, "`hotkeyd peek set --help` exits 0")

    // Seed sandbox config
    expectEqual(runPeekCLI("add fn+space 'open -a Terminal' --name Term").exitCode, 0, "seed fn+space shortcut")
    expectEqual(runPeekCLI("add fn:q 'open -a Safari' --name Safari").exitCode, 0, "seed fn:q shortcut")
    expectEqual(runPeekCLI("add lcmd 'open -a \"Google Chrome\"' --name Chrome").exitCode, 0, "seed lcmd shortcut")
    expectEqual(runPeekCLI("disable Chrome").exitCode, 0, "disable Chrome for showDisabled test")

    let statusDefault = runPeekCLI("peek status --json")
    expectEqual(statusDefault.exitCode, 0, "`hotkeyd peek status --json` exits 0")
    expect(statusDefault.stdout.contains("\"enabled\" : false"), "peek defaults to enabled=false (opt-in)")
    expect(statusDefault.stdout.contains("\"capsLockTriggerDormant\" : false"), "default triggers [fn] do not report dormant capsLock")
    expect(statusDefault.stdout.contains("\"delayMs\" : 450"), "peek status reports default 450ms delay")

    let termOut = runPeekCLI("peek --terminal")
    expectEqual(termOut.exitCode, 0, "`hotkeyd peek --terminal` exits 0")
    expect(termOut.stdout.contains("fn + Space"), "terminal card shows fn + Space")
    expect(termOut.stdout.contains("fn › Q"), "terminal card shows fn › Q")
    expect(!termOut.stdout.contains("Chrome"), "terminal card hides disabled Chrome by default")

    let termWithDisabled = runPeekCLI("peek --terminal --show-disabled --json")
    expectEqual(termWithDisabled.exitCode, 0, "`hotkeyd peek --terminal --show-disabled --json` exits 0")
    expect(termWithDisabled.stdout.contains("\"Chrome\""), "--show-disabled includes disabled shortcut in JSON")

    // Bare `hotkeyd peek` in sandbox refuses LaunchAgent signaling cleanly (exit 6)
    let sandboxToggle = runPeekCLI("peek --json")
    expectEqual(sandboxToggle.exitCode, 6, "bare `hotkeyd peek` under HOTKEYD_HOME exits 6 without touching live daemon")

    // `peek set` validation & persistence
    expectEqual(runPeekCLI("peek set --delay 250").exitCode, 4, "`peek set --delay 250` exits 4 (below 300ms floor)")
    expectEqual(runPeekCLI("peek set --delay bogus").exitCode, 2, "`peek set --delay bogus` exits 2")
    expectEqual(runPeekCLI("peek set --toggle fn+space").exitCode, 4, "`peek set --toggle fn+space` exits 4 on collision")
    expectEqual(runPeekCLI("peek set --toggle fn:q").exitCode, 4, "`peek set --toggle fn:q` exits 4 on sequence collision")
    expectEqual(runPeekCLI("peek set --toggle fn+/ --clear-toggle").exitCode, 2, "mutually exclusive --toggle and --clear-toggle exit 2")
    expectEqual(runPeekCLI("peek set --dim --no-dim").exitCode, 2, "mutually exclusive --dim and --no-dim exit 2")

    let setRes = runPeekCLI("peek set --triggers fn --delay 600 --toggle fn:/ --no-dim --show-disabled --json")
    expectEqual(setRes.exitCode, 0, "`hotkeyd peek set` with sequence toggle + --no-dim exits 0")
    expect(setRes.stdout.contains("\"delayMs\" : 600"), "peek set reports delayMs 600")
    expect(setRes.stdout.contains("\"toggle\" : \"fn > slash\""), "peek set canonicalizes fn:/ to fn > slash")
    expect(setRes.stdout.contains("\"dimUnmatched\" : false"), "peek set persists dimUnmatched=false")
    expect(setRes.stdout.contains("\"showDisabled\" : true"), "peek set persists showDisabled=true")

    let setModToggle = runPeekCLI("peek set --toggle rcmd --dim --json")
    expectEqual(setModToggle.exitCode, 0, "`hotkeyd peek set --toggle rcmd --dim` exits 0")
    expect(setModToggle.stdout.contains("\"toggle\" : \"rcmd\""), "peek set accepts bare modifier double-tap toggle")
    expect(setModToggle.stdout.contains("\"dimUnmatched\" : true"), "peek set --dim restores dimUnmatched=true")

    let disRes = runPeekCLI("peek disable --json")
    expectEqual(disRes.exitCode, 0, "`hotkeyd peek disable --json` exits 0")
    expect(disRes.stdout.contains("\"enabled\" : false"), "peek disable persists enabled=false")

    let enRes = runPeekCLI("peek enable --json")
    expectEqual(enRes.exitCode, 0, "`hotkeyd peek enable --json` exits 0")
    expect(enRes.stdout.contains("\"enabled\" : true"), "peek enable persists enabled=true")

    let resetRes = runPeekCLI("peek set --reset --json")
    expectEqual(resetRes.exitCode, 0, "`hotkeyd peek set --reset --json` exits 0")
    expect(resetRes.stdout.contains("\"isDefault\" : true"), "peek set --reset restores default config")
    let cfgAfterReset = (try? String(contentsOf: cliHome.appendingPathComponent(".hotkeyd"), encoding: .utf8)) ?? ""
    expect(!cfgAfterReset.contains("\"peek\""), "resetting peek omits default peek block from .hotkeyd")

    // Schema includes top-level `peek`
    let schemaRes = runPeekCLI("schema config")
    expectEqual(schemaRes.exitCode, 0, "`hotkeyd schema config` exits 0")
    expect(schemaRes.stdout.contains("\"peek\""), "config JSON schema documents optional peek block")

    // Hidden helper guards: rejects extra arguments & exits 0 cleanly on immediate stdin EOF
    let helperBadArg = runPeekCLI("__peek-overlay unexpected")
    expectEqual(helperBadArg.exitCode, 2, "`hotkeyd __peek-overlay` rejects unexpected arguments with exit 2")
    let helperEOF = ShellRunner.run(
        command: "HOTKEYD_HOME='\(cliHome.path)' '\(cliURL.path)' __peek-overlay < /dev/null",
        cwd: cliHome.path,
        timeoutMilliseconds: 5_000
    )
    expectEqual(helperEOF.exitCode, 0, "`hotkeyd __peek-overlay < /dev/null` exits 0 immediately on stdin EOF")
    expect(!helperEOF.timedOut, "`hotkeyd __peek-overlay` does not hang on stdin EOF")

    // 8. Searchable HUD: PeekSearchBuilder, frequency ranking, fuzzy matcher, searchToggle, and CLI
    do {
        let searchLogs = root.appendingPathComponent("search-logs")
        try? fm.createDirectory(at: searchLogs, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let logContent = """
        2026-11-21T01:00:00.000Z action shortcut=Screen OCR exit=0 40ms action=echo ocr
        2026-11-21T01:01:00.000Z action shortcut=Screen OCR exit=0 45ms action=echo ocr
        2026-11-21T01:02:00.000Z action shortcut=Screen OCR exit=0 42ms action=echo ocr
        2026-11-21T01:03:00.000Z action shortcut=Chrome exit=0 22ms action=open -a "Google Chrome"
        2026-11-21T01:04:00.000Z action shortcut=Chrome exit=0 20ms action=open -a "Google Chrome"
        """
        let logURL = searchLogs.appendingPathComponent("actions.log")
        try? Data((logContent + "\n").utf8).write(to: logURL)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)

        let searchCfg = Config(shortcuts: [
            Shortcut(keys: .combo(try KeyCombo.parse("fn+c")), tap: "echo \"$SELECTED_TEXT\"", name: "Append Clipboard"),
            Shortcut(keys: .modifier(.leftCommand), doubleTap: "open -a \"Google Chrome\"", name: "Chrome"),
            Shortcut(keys: .sequence(try KeySequence.parse("capsLock > o")), tap: "echo ocr", name: "Screen OCR", allowAccessibility: true),
            Shortcut(keys: .sequence(try KeySequence.parse("capsLock > s")), tap: "echo qr", name: "Screen QR Scan", allowAccessibility: true),
            Shortcut(keys: .combo(try KeyCombo.parse("fn+u")), tap: "open 'https://user:pw@www.example.com/app?secret=123'")
        ])

        let searchSnap = PeekSearchBuilder.buildSnapshot(from: searchCfg, logsDirectory: searchLogs)
        expectEqual(searchSnap.totalCount, 5, "PeekSearchBuilder expands all 5 enabled shortcuts")
        expectEqual(searchSnap.items.first?.label, "Screen OCR", "empty-query default order ranks most-used shortcut (Screen OCR, 3x) first")
        expectEqual(searchSnap.items.dropFirst().first?.label, "Chrome", "second most-used shortcut (Chrome, 2x) ranks second")

        // Strict one-way security flags (`runnableInHelper`, `statusTag`, `directKeyHint`)
        let ocrItem = searchSnap.items.first(where: { $0.label == "Screen OCR" })
        expectEqual(ocrItem?.runnableInHelper, false, "[AX] shortcut is NOT runnable in TCC-disclaimed helper")
        expectEqual(ocrItem?.statusTag, "AX", "[AX] shortcut carries AX statusTag")
        expect(ocrItem?.directKeyHint?.contains("Accessibility") == true, "[AX] shortcut carries direct-key hint")

        let selItem = searchSnap.items.first(where: { $0.label == "Append Clipboard" })
        expectEqual(selItem?.runnableInHelper, false, "SELECTED_TEXT shortcut is NOT runnable in TCC-disclaimed helper")
        expectEqual(selItem?.statusTag, "SEL", "SELECTED_TEXT shortcut carries SEL statusTag")

        let chromeItem = searchSnap.items.first(where: { $0.label == "Chrome" })
        expectEqual(chromeItem?.runnableInHelper, true, "normal native shortcut IS runnable in helper")
        expectNil(chromeItem?.statusTag, "normal shortcut has no warning tag")

        let urlItem = searchSnap.items.first(where: { $0.canonicalKeys == "fn+u" })
        expect(urlItem?.commandPreview.contains("secret") == false && urlItem?.commandPreview.contains("pw") == false, "commandPreview redacts URL userinfo and query secrets")

        // High #3 security tests: comprehensive secret redaction in PeekSearchBuilder & PeekLabeler
        let appWithSecretArgs = Shortcut(
            keys: .combo(try KeyCombo.parse("fn+a")),
            tap: "open -a \"Google Chrome\" --args \"https://alice:pw99@example.com/path?token=xyz#frag\""
        )
        let appArgLabel = PeekLabeler.label(for: appWithSecretArgs, command: appWithSecretArgs.activeCommand)
        let appArgPreview = PeekSearchBuilder.safeCommandPreview(appWithSecretArgs.activeCommand)
        expect(!appArgLabel.contains("pw99") && !appArgLabel.contains("xyz") && !appArgLabel.contains("frag"), "High #3: PeekLabeler redacts secrets in open -a --args URLs")
        expect(!appArgPreview.contains("pw99") && !appArgPreview.contains("xyz") && !appArgPreview.contains("frag"), "High #3: safeCommandPreview redacts secrets in open -a --args URLs")

        let httpPreview = PeekSearchBuilder.safeCommandPreview("open 'http://user:pw@intranet.local/app?key=123'")
        expect(httpPreview.hasPrefix("open http://intranet.local/app"), "High #3: safeCommandPreview preserves http:// scheme instead of spoofing https://")
        expect(!httpPreview.contains("pw") && !httpPreview.contains("123"), "High #3: safeCommandPreview strips http userinfo and query")

        let curlPreview = PeekSearchBuilder.safeCommandPreview("curl -H \"Authorization: Bearer eyJhbGciOi.payload.sig\" -u admin:supersecret \"https://api.example.com/v1?api_key=sk_live_12345\"")
        expect(!curlPreview.contains("eyJhbGciOi") && !curlPreview.contains("supersecret") && !curlPreview.contains("sk_live_12345"), "High #3: safeCommandPreview redacts Bearer JWT, -u credentials, and curl query secrets")

        let envPreview = PeekSearchBuilder.safeCommandPreview("API_KEY=sk-proj-secret123 DB_PASSWORD=hunter2 ./deploy.sh --token=tok_abc --secret mysecret")
        expect(!envPreview.contains("secret123") && !envPreview.contains("hunter2") && !envPreview.contains("tok_abc") && !envPreview.contains("mysecret"), "High #3: safeCommandPreview redacts inline secret env vars and --token/--secret flags")

        let customSchemePreview = PeekSearchBuilder.safeCommandPreview("open \"postgres://admin:s3cr3t@db.internal:5432/prod?sslmode=require\"")
        expect(customSchemePreview.contains("postgres://db.internal:5432/prod"), "High #3: custom scheme preserves host:port/path")
        expect(!customSchemePreview.contains("s3cr3t") && !customSchemePreview.contains("sslmode"), "High #3: custom scheme strips userinfo and query")

        let slackWebhook = PeekSearchBuilder.safeCommandPreview("curl -X POST https://hooks.slack.com/services/T000000/B000000/SECRETWEBHOOK999")
        expect(!slackWebhook.contains("SECRETWEBHOOK999"), "High #3: redacts Slack webhook token path segment")

        let multilinePreview = PeekSearchBuilder.safeCommandPreview("echo start\nexport SECRET=topsecret\ncurl -u a:b https://x.test")
        expectEqual(multilinePreview, "echo start …", "High #3: multi-line command truncates to first line and hides line 2+ secrets")

        let malformedURL = PeekLabeler.redactedURLLabel("https://alice:badpass@[invalid?tok=leak")
        expect(!malformedURL.contains("badpass") && !malformedURL.contains("leak"), "High #3: malformed URL fallback never echoes userinfo or query")

        let harmlessCmd = PeekSearchBuilder.safeCommandPreview("mkdir -p ~/Desktop/shots")
        expectEqual(harmlessCmd, "mkdir -p ~/Desktop/shots", "High #3: harmless mkdir -p command stays unredacted")

        // High #4 integration test: >36 KiB NDJSON frame + quit over pipe into `__peek-overlay`
        // verifies both >16 KiB multi-chunk pipe reading and Release ARC lifetime safety.
        let largeHideFrame = String(repeating: " ", count: 38_000) + "{\"op\":\"hide\"}\n{\"op\":\"quit\"}\n"
        let largeFrameFile = root.appendingPathComponent("large-wire.ndjson")
        try? Data(largeHideFrame.utf8).write(to: largeFrameFile)
        let helperLargePipe = ShellRunner.run(
            command: "HOTKEYD_HOME='\(cliHome.path)' '\(cliURL.path)' __peek-overlay < '\(largeFrameFile.path)'",
            cwd: cliHome.path,
            timeoutMilliseconds: 5_000
        )
        expectEqual(helperLargePipe.exitCode, 0, "High #4: `__peek-overlay` processes >36 KiB NDJSON frame + quit cleanly with exit 0")
        expect(!helperLargePipe.timedOut, "High #4: `__peek-overlay` does not stall or lose controller under >36 KiB pipe input")

        // Multi-token fuzzy search + alias matching
        let qrMatches = PeekSearchMatcher.filter(searchSnap.items, query: "qr")
        expectEqual(qrMatches.map(\.label), ["Screen QR Scan"], "fuzzy matcher finds Screen QR Scan for 'qr'")
        let capsMatches = PeekSearchMatcher.filter(searchSnap.items, query: "caps")
        expectEqual(capsMatches.count, 2, "key alias 'caps' matches both capsLock bindings")
        let multiToken = PeekSearchMatcher.filter(searchSnap.items, query: "scr ocr")
        expectEqual(multiToken.first?.label, "Screen OCR", "multi-token fuzzy query 'scr ocr' ranks Screen OCR first")
        let cmdMatch = PeekSearchMatcher.filter(searchSnap.items, query: "google")
        expectEqual(cmdMatch.first?.label, "Chrome", "command search 'google' finds Chrome")

        // `toggleSearch` wire message NDJSON round-trip
        let toggleSearchMsg = PeekWireMessage.toggleSearch(searchSnap)
        if let wireLine = toggleSearchMsg.encodeLine() {
            let trimmed = Data(wireLine.dropLast())
            expectEqual(PeekWireMessage.decodeLine(trimmed), toggleSearchMsg, "PeekWireMessage.toggleSearch round-trips cleanly")
        } else {
            expect(false, "PeekWireMessage.toggleSearch should encode cleanly")
        }

        // `searchToggle` config validation (rejects collision with toggle and with shortcuts)
        expectThrows("PeekConfig rejects searchToggle colliding with peek.toggle") {
            let seq = try KeySequence.parse("fn > s")
            let cfg = Config(shortcuts: [], peek: PeekConfig(enabled: true, toggle: .sequence(seq), searchToggle: .sequence(seq)))
            try cfg.validate()
        }
        expectThrows("PeekConfig rejects searchToggle colliding with enabled shortcut") {
            let combo = try KeyCombo.parse("fn+c")
            let cfg = Config(shortcuts: searchCfg.shortcuts, peek: PeekConfig(enabled: true, searchToggle: .combo(combo)))
            try cfg.validate()
        }
        let capsSearchCfg = Config(shortcuts: [], peek: PeekConfig(enabled: true, searchToggle: .sequence(try KeySequence.parse("capsLock > s"))))
        try capsSearchCfg.validate()
        expect(capsSearchCfg.requiresCapsLockRemap, "enabled capsLock searchToggle activates requiresCapsLockRemap")

        // Low #15: Search HUD carries exact `shortcut.displayName` in `logName` so unnamed
        // shortcuts log under canonical keys and climb frequency rank in `hotkeyd stats`
        expectEqual(chromeItem?.logName, "Chrome", "Low #15: named shortcut logName matches displayName")
        expectEqual(urlItem?.logName, "fn+u", "Low #15: unnamed shortcut logName is canonical key (not derived URL label)")

        // Medium #13: PeekSearchMatcher caps long queries & deduplicates repeated tokens cleanly
        let repeatedQuery = Array(repeating: "chrome", count: 40).joined(separator: " ")
        let cappedMatches = PeekSearchMatcher.filter(searchSnap.items, query: repeatedQuery)
        expectEqual(cappedMatches.first?.label, "Chrome", "Medium #13: bounded/deduplicated query still ranks Chrome first")

        // Medium #7: Non-runnable ([AX], [SEL], disabled) items never transmit rawCommand/cwd/timeout
        expectEqual(ocrItem?.rawCommand, "", "Medium #7: [AX] shortcut omits rawCommand over the wire")
        expectEqual(selItem?.rawCommand, "", "Medium #7: [SEL] shortcut omits rawCommand over the wire")
        expect(chromeItem?.rawCommand.isEmpty == false, "Medium #7: runnable shortcut retains rawCommand")

        // Medium #11: Side-agnostic peek.toggle / peek.searchToggle overlap validation & accurate errors
        do {
            let overlapMod = Config(shortcuts: [], peek: PeekConfig(enabled: true, toggle: .modifier(.command), searchToggle: .modifier(.leftCommand)))
            do {
                try overlapMod.validate()
                expect(false, "Medium #11: cmd toggle vs lcmd searchToggle must throw")
            } catch {
                expect(error.localizedDescription.contains("peek.searchToggle"), "Medium #11: searchToggle overlap error names peek.searchToggle")
            }
        }
        expectThrows("Medium #11: cmd > s toggle overlaps with lcmd > s enabled shortcut") {
            let cfg = Config(
                shortcuts: [Shortcut(keys: .sequence(try KeySequence.parse("lcmd > s")), tap: "echo hi", name: "LeftSeq")],
                peek: PeekConfig(enabled: true, toggle: .sequence(try KeySequence.parse("cmd > s")))
            )
            try cfg.validate()
        }
        expectThrows("Medium #11: cmd+k searchToggle overlaps with lcmd+k enabled shortcut") {
            let cfg = Config(
                shortcuts: [Shortcut(keys: .combo(try KeyCombo.parse("lcmd+k")), tap: "echo hi", name: "LeftCombo")],
                peek: PeekConfig(enabled: true, searchToggle: .combo(try KeyCombo.parse("cmd+k")))
            )
            try cfg.validate()
        }
        let nonOverlapSides = Config(
            shortcuts: [Shortcut(keys: .modifier(.leftCommand), doubleTap: "echo hi", name: "LeftCmd")],
            peek: PeekConfig(enabled: true, toggle: .modifier(.rightCommand), searchToggle: .modifier(.rightOption))
        )
        try nonOverlapSides.validate()

        // Medium #9: Defense-in-depth terminal sanitization in StrictModes, Log, and public formatters
        let hostileText = "ok\u{001B}[31m\u{009B}2J\u{202E}\u{2028}\u{2029}safe"
        let cleanTerm = StrictModes.sanitizeTerminalText(hostileText)
        let cleanLog = Log.sanitizeMessage(hostileText)
        expect(!cleanTerm.contains("\u{001B}") && !cleanTerm.contains("\u{202E}") && !cleanTerm.contains("\u{2028}") && !cleanTerm.contains("\u{2029}"), "Medium #9: StrictModes strips ESC, Bidi, and U+2028/U+2029")
        expect(!cleanLog.contains("\u{001B}") && !cleanLog.contains("\u{202E}") && !cleanLog.contains("\u{2028}") && !cleanLog.contains("\u{2029}"), "Medium #9: Log.sanitizeMessage strips ESC, Bidi, and U+2028/U+2029")

        let untrustedPeekSnap = PeekSnapshot(
            mode: .pinned,
            title: "Evil\u{001B}[31mTitle",
            subtitle: nil,
            activeModifierLabels: [],
            matchedCount: 1,
            totalCount: 1,
            dimUnmatched: false,
            groups: [PeekGroup(id: "g", title: "Grp\u{202E}X", entries: [
                PeekEntry(keyPills: ["fn"], keyDisplay: "fn\u{009B}2J", canonicalKeys: "fn", label: "Lbl\u{001B}]0;pwn\u{0007}", badges: ["AX\u{001B}"], isDoubleTap: false, enabled: true, matched: true)
            ], highlighted: true)]
        )
        let formattedUntrustedPeek = PeekTerminalFormatter.format(untrustedPeekSnap)
        expect(!formattedUntrustedPeek.contains("\u{001B}") && !formattedUntrustedPeek.contains("\u{009B}") && !formattedUntrustedPeek.contains("\u{202E}") && !formattedUntrustedPeek.contains("\u{0007}"), "Medium #9: PeekTerminalFormatter sanitizes untrusted snapshot fields")

        let untrustedSearchSnap = PeekSearchSnapshot(totalCount: 1, items: [
            PeekSearchItem(
                id: "1", slot: "tap", canonicalKeys: "fn+a", keyPills: ["fn", "A"],
                keyDisplay: "fn\u{001B}+A", keySearchAliases: "fn a",
                label: "Bad\u{001B}[31m\u{202E}Label", commandPreview: "echo ok", rawCommand: "",
                cwd: nil, timeoutMilliseconds: nil, usageCount: 0, configOrder: 0,
                enabled: true, allowAccessibility: false, usesSelectedText: false,
                runnableInHelper: false, directKeyHint: nil, statusTag: "AX\u{009B}"
            )
        ])
        let formattedUntrustedSearch = PeekSearchTerminalFormatter.format(untrustedSearchSnap, query: "")
        expect(!formattedUntrustedSearch.contains("\u{001B}") && !formattedUntrustedSearch.contains("\u{009B}") && !formattedUntrustedSearch.contains("\u{202E}"), "Medium #9: PeekSearchTerminalFormatter sanitizes untrusted snapshot fields")
    } catch {
        expect(false, "PeekSearch unit tests threw: \(error)")
    }

    // End-to-end sandboxed CLI tests for `--search`, `--query`, and `--search-toggle`
    expectEqual(runPeekCLI("peek --query foo").exitCode, 2, "`hotkeyd peek --query` without `--search --terminal` exits 2")
    expectEqual(runPeekCLI("peek --query ''").exitCode, 2, "Low #13: `hotkeyd peek --query ''` without `--search --terminal` exits 2")
    expectEqual(runPeekCLI("peek --show-disabled").exitCode, 2, "Low #13: `hotkeyd peek --show-disabled` without `--terminal` exits 2")
    let escErr = runPeekCLI("peek $'\\033[31mbadsub'")
    expectEqual(escErr.exitCode, 2, "Medium #9: invalid peek subcommand exits 2")
    expect(!escErr.stderr.contains("\u{001B}"), "Medium #9: stderr error output strips raw ESC sequences")
    expectEqual(runPeekCLI("peek --search --json").exitCode, 6, "`hotkeyd peek --search` under HOTKEYD_HOME refuses LaunchAgent with exit 6")
    let searchTerm = runPeekCLI("peek --search --terminal --query saf")
    expectEqual(searchTerm.exitCode, 0, "`hotkeyd peek --search --terminal --query saf` exits 0")
    expect(searchTerm.stdout.contains("Safari"), "offline terminal search finds Safari for 'saf'")
    expect(!searchTerm.stdout.contains("Term"), "offline terminal search filters out non-matching Term")
    let searchJSON = runPeekCLI("peek --search --terminal --query saf --json")
    expectEqual(searchJSON.exitCode, 0, "`hotkeyd peek --search --terminal --query saf --json` exits 0")
    expect(searchJSON.stdout.contains("\"matchedCount\" : 1"), "search terminal JSON reports matchedCount=1")

    // Medium #13: `=` flag parsing preserves empty values (`--query= --json` must not eat `--json`,
    // and `--search=` must reject empty boolean value with exit 2 instead of evaluating true)
    let emptyQueryJSON = runPeekCLI("peek --search --terminal --query= --json")
    expectEqual(emptyQueryJSON.exitCode, 0, "Medium #13: `--query= --json` exits 0 without consuming `--json`")
    expect(emptyQueryJSON.stdout.contains("\"matchedCount\""), "Medium #13: `--query= --json` still emits JSON envelope")
    let emptyBoolFlag = runPeekCLI("peek --search= --terminal")
    expectEqual(emptyBoolFlag.exitCode, 2, "Medium #13: `--search=` rejects empty boolean flag value with exit 2")

    expectEqual(runPeekCLI("peek set --search-toggle fn:s --clear-search-toggle").exitCode, 2, "mutually exclusive --search-toggle and --clear-search-toggle exit 2")
    let setSearchToggle = runPeekCLI("peek set --toggle fn:/ --search-toggle fn:s --json")
    expectEqual(setSearchToggle.exitCode, 0, "`hotkeyd peek set --toggle fn:/ --search-toggle fn:s` exits 0")
    expect(setSearchToggle.stdout.contains("\"searchToggle\" : \"fn > s\""), "peek set persists searchToggle canonically")
    expectEqual(runPeekCLI("peek set --search-toggle fn:/").exitCode, 4, "setting searchToggle equal to toggle exits 4")
    expectEqual(runPeekCLI("peek set --clear-search-toggle --json").exitCode, 0, "`--clear-search-toggle` clears searchToggle")
}

// MARK: - Run

let allSuites: [(name: String, run: () -> Void)] = [
    ("detector", testDetector),
    ("modifiers", testModifiers),
    ("config", testConfig),
    ("keyCombos", testKeyCombos),
    ("capsLock", testCapsLock),
    ("sideSpecificModifiers", testSideSpecificModifiers),
    ("comboConfig", testComboConfig),
    ("doubleTapKeys", testDoubleTapKeys),
    ("v01SecurityControls", testV01SecurityControls),
    ("unifiedSchemaAndFormatting", testUnifiedSchemaAndFormatting),
    ("codeTrustControls", testCodeTrustControls),
    ("strictModesAndAtomicSave", testStrictModesAndAtomicSave),
    ("processGroupTimeoutAndPipeBounds", testProcessGroupTimeoutAndPipeBounds),
    ("concurrencyAndEventGuards", testConcurrencyAndEventGuards),
    ("commandRegistryAndSchemas", testCommandRegistryAndSchemas),
    ("sequences", testSequences),
    ("selectedText", testSelectedText),
    ("appResolution", testAppResolution),
    ("criticalAndHighSecurityFixes", testCriticalAndHighSecurityFixes),
    ("uxAndAgentContractFixes", testUXAndAgentContractFixes),
    ("initOnboardingAndPrerequisites", testInitOnboardingAndPrerequisites),
    ("completionsAndManPage", testCompletionsAndManPage),
    ("stats", testStatsAnalyzerAndCLI),
    ("pauseResume", testPauseAndResume),
    ("peekOverlayAndCLI", testPeekOverlayAndCLI)
]

let cliArgs = Array(CommandLine.arguments.dropFirst())
var filterPattern: String?

if cliArgs.contains("--help") || cliArgs.contains("-h") {
    print("Usage: selftest [--list | --filter <substring> | <substring>]")
    exit(0)
}
if cliArgs.contains("--list") {
    for suite in allSuites {
        print(suite.name)
    }
    exit(0)
}
if !cliArgs.isEmpty {
    if cliArgs.count == 2 && cliArgs[0] == "--filter" {
        filterPattern = cliArgs[1]
    } else if cliArgs.count == 1 && !cliArgs[0].hasPrefix("-") {
        filterPattern = cliArgs[0]
    } else {
        FileHandle.standardError.write(Data("selftest: invalid arguments (expected --list or --filter <substring>)\n".utf8))
        exit(2)
    }
}

let selectedSuites: [(name: String, run: () -> Void)]
if let pattern = filterPattern?.lowercased(), !pattern.isEmpty {
    selectedSuites = allSuites.filter { $0.name.lowercased().contains(pattern) }
    if selectedSuites.isEmpty {
        let available = allSuites.map(\.name).joined(separator: ", ")
        FileHandle.standardError.write(Data("selftest: no suite matches '\(pattern)'. Available: \(available)\n".utf8))
        exit(2)
    }
} else {
    selectedSuites = allSuites
}

for suite in selectedSuites {
    suite.run()
}

if filterPattern != nil {
    let names = selectedSuites.map(\.name).joined(separator: ", ")
    print("ran \(selectedSuites.count)/\(allSuites.count) suite(s): \(names)")
}
print("\(checks) checks, \(failures) failure(s)")
if failures > 0 {
    exit(1)
}
print("all good")
