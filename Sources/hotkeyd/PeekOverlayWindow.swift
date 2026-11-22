import AppKit
import Carbon
import Darwin
import Foundation
import HotkeydCore
import QuartzCore

/// Hidden internal entrypoint (`hotkeyd __peek-overlay`) spawned lazily by the daemon as a
/// TCC-disclaimed `.accessory` helper process. Reads bounded NDJSON `PeekWireMessage` frames from
/// `stdin`, renders both the non-activating monochrome bento peek overlay AND the interactive
/// Spotlight Search HUD (with strict one-way isolation — zero reverse pipe into the daemon),
/// and exits cleanly on `stdin` EOF or after 15 minutes idle while hidden.
func commandInternalPeekOverlay(_ arguments: [String]) throws {
    if !arguments.isEmpty {
        throw CLIError(
            message: "`__peek-overlay` is an internal daemon helper and takes no arguments",
            code: 2
        )
    }
    guard isatty(STDIN_FILENO) == 0 else {
        throw CLIError(
            message: "`__peek-overlay` is an internal helper driven by the daemon over stdin",
            code: 2,
            hint: "use `hotkeyd peek` to toggle the overlay or `hotkeyd peek --terminal` for CLI output"
        )
    }

    // Defense-in-depth: helper is already TCC-disclaimed via posix_spawn, and additionally locks
    // out Accessibility delegation so it can never launch privileged [AX] commands.
    ShellRunner.disallowAccessibilityDelegation = true

    // Move the daemon->helper pipe off STDIN_FILENO onto a private CLOEXEC descriptor and point
    // STDIN_FILENO at /dev/null so no AppKit/system subprocess can ever inherit fd 0.
    let privatePipeFD = fcntl(STDIN_FILENO, F_DUPFD_CLOEXEC, 3)
    let inputFD: Int32
    if privatePipeFD >= 0 {
        inputFD = privatePipeFD
        let devNull = open("/dev/null", O_RDONLY | O_CLOEXEC)
        if devNull >= 0 {
            _ = dup2(devNull, STDIN_FILENO)
            close(devNull)
        }
    } else {
        inputFD = STDIN_FILENO
    }

    // Start draining stdin before AppKit finishes initializing so >16 KiB frames written right
    // after lazy spawn never stall waiting on `NSApplication.shared`, and keep `controller`
    // strongly alive across `app.run()` under Release ARC optimization.
    let controller = PeekOverlayWindowController(inputFD: inputFD)
    controller.startReadingStdin()

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    installMinimalEditMenu(on: app)
    withExtendedLifetime(controller) {
        app.run()
    }
}

/// Installs a minimal Edit menu on the `.accessory` helper so standard Cocoa text-editing key
/// equivalents (`⌘V`, `⌘A`, `⌘X`, `⌘C`, `⌘Z`, `⇧⌘Z`) work natively inside the Search HUD field.
private func installMinimalEditMenu(on app: NSApplication) {
    let mainMenu = NSMenu()
    let editRoot = NSMenuItem()
    mainMenu.addItem(editRoot)

    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    redoItem.keyEquivalentModifierMask = [.command, .shift]
    editMenu.addItem(redoItem)
    editMenu.addItem(.separator())
    editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editRoot.submenu = editMenu

    app.mainMenu = mainMenu
}

// MARK: - Appearance & Flipped Scroll Helpers

private extension NSView {
    var isDarkAppearance: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Panels & Monochrome Glass Components

private final class NonActivatingHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class SearchHUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class BorderedVisualEffectView: NSVisualEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = 20
        layer?.masksToBounds = true
        layer?.borderWidth = 1.0
        updateDynamicRim()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateDynamicRim()
    }

    override func layout() {
        super.layout()
        updateDynamicRim()
    }

    private func updateDynamicRim() {
        let dark = isDarkAppearance
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.layer?.borderColor = dark
                ? NSColor.white.withAlphaComponent(0.16).cgColor
                : NSColor.black.withAlphaComponent(0.11).cgColor
        }
    }
}

private final class BentoGroupCardView: NSView {
    private let elevated: Bool

    init(elevated: Bool) {
        self.elevated = elevated
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = 12
        layer?.borderWidth = 1.0
        translatesAutoresizingMaskIntoConstraints = false
        updateDynamicSurface()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateDynamicSurface()
    }

    override func layout() {
        super.layout()
        updateDynamicSurface()
    }

    private func updateDynamicSurface() {
        let dark = isDarkAppearance
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if self.elevated {
                self.layer?.backgroundColor = dark
                    ? NSColor.white.withAlphaComponent(0.075).cgColor
                    : NSColor.white.withAlphaComponent(0.52).cgColor
                self.layer?.borderColor = dark
                    ? NSColor.white.withAlphaComponent(0.17).cgColor
                    : NSColor.black.withAlphaComponent(0.12).cgColor
            } else {
                self.layer?.backgroundColor = dark
                    ? NSColor.white.withAlphaComponent(0.032).cgColor
                    : NSColor.black.withAlphaComponent(0.030).cgColor
                self.layer?.borderColor = dark
                    ? NSColor.white.withAlphaComponent(0.075).cgColor
                    : NSColor.black.withAlphaComponent(0.065).cgColor
            }
        }
    }
}

private class SpotlightRowView: NSView {
    var isHighlightedRow: Bool {
        didSet {
            layer?.borderWidth = isHighlightedRow ? 0.75 : 0.0
            updateDynamicSurface()
        }
    }

    init(highlighted: Bool) {
        self.isHighlightedRow = highlighted
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = 8
        layer?.borderWidth = highlighted ? 0.75 : 0.0
        translatesAutoresizingMaskIntoConstraints = false
        updateDynamicSurface()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateDynamicSurface()
    }

    override func layout() {
        super.layout()
        updateDynamicSurface()
    }

    private func updateDynamicSurface() {
        let dark = isDarkAppearance
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if self.isHighlightedRow {
                self.layer?.backgroundColor = dark
                    ? NSColor.white.withAlphaComponent(0.11).cgColor
                    : NSColor.white.withAlphaComponent(0.72).cgColor
                self.layer?.borderColor = dark
                    ? NSColor.white.withAlphaComponent(0.16).cgColor
                    : NSColor.black.withAlphaComponent(0.10).cgColor
            } else {
                self.layer?.backgroundColor = NSColor.clear.cgColor
                self.layer?.borderColor = nil
            }
        }
    }
}

private final class InteractiveSearchRowView: SpotlightRowView {
    let rowIndex: Int
    private let labelField: NSTextField
    private let onSelect: (Int) -> Void
    private let onActivate: (Int) -> Void

    init(
        index: Int,
        item: PeekSearchItem,
        selected: Bool,
        onSelect: @escaping (Int) -> Void,
        onActivate: @escaping (Int) -> Void
    ) {
        self.rowIndex = index
        self.onSelect = onSelect
        self.onActivate = onActivate
        self.labelField = NSTextField(labelWithString: item.label)
        super.init(highlighted: selected)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false

        labelField.font = NSFont.systemFont(ofSize: 13.5, weight: selected ? .medium : .regular)
        labelField.textColor = item.enabled ? .labelColor : .tertiaryLabelColor
        labelField.lineBreakMode = .byTruncatingTail
        labelField.maximumNumberOfLines = 1
        labelField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labelField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        row.addArrangedSubview(labelField)

        if let tag = item.statusTag {
            row.addArrangedSubview(KeycapPillView(text: tag, style: .disabledTag))
        }

        let pillsStack = NSStackView()
        pillsStack.orientation = .horizontal
        pillsStack.alignment = .centerY
        pillsStack.spacing = 4
        pillsStack.translatesAutoresizingMaskIntoConstraints = false
        pillsStack.setContentHuggingPriority(.required, for: .horizontal)
        pillsStack.setContentCompressionResistancePriority(.required, for: .horizontal)

        for token in item.keyPills {
            if token == "›" {
                let arrow = NSTextField(labelWithString: "›")
                arrow.font = NSFont.systemFont(ofSize: 12, weight: .medium)
                arrow.textColor = .tertiaryLabelColor
                pillsStack.addArrangedSubview(arrow)
            } else if token == "2×" {
                pillsStack.addArrangedSubview(KeycapPillView(text: "2×", style: .doubleTap))
            } else {
                pillsStack.addArrangedSubview(KeycapPillView(text: token, style: .keycap))
            }
        }
        row.addArrangedSubview(pillsStack)

        addSubview(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 36),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func setSelected(_ selected: Bool) {
        isHighlightedRow = selected
        labelField.font = NSFont.systemFont(ofSize: 13.5, weight: selected ? .medium : .regular)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onActivate(rowIndex)
        } else if event.clickCount == 1 {
            onSelect(rowIndex)
        }
    }
}

private enum PillStyle {
    case keycap
    case headerKeycap
    case doubleTap
    case miniKey
    case statusPill
    case disabledTag
}

private final class KeycapPillView: NSView {
    private let label: NSTextField
    private let style: PillStyle

    init(text: String, style: PillStyle) {
        self.style = style
        self.label = NSTextField(labelWithString: text)
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false

        let fontSize: CGFloat
        let weight: NSFont.Weight
        let cornerRadius: CGFloat
        let borderWidth: CGFloat
        let hPad: CGFloat
        let fixedHeight: CGFloat
        let minWidth: CGFloat

        switch style {
        case .keycap:
            fontSize = 11.5
            weight = .medium
            cornerRadius = 6.0
            borderWidth = 0.75
            hPad = 6.5
            fixedHeight = 22.0
            minWidth = 22.0
        case .headerKeycap:
            fontSize = 12.0
            weight = .semibold
            cornerRadius = 6.5
            borderWidth = 0.75
            hPad = 8.0
            fixedHeight = 24.0
            minWidth = 26.0
        case .doubleTap:
            fontSize = 10.5
            weight = .semibold
            cornerRadius = 6.0
            borderWidth = 0.75
            hPad = 5.5
            fixedHeight = 22.0
            minWidth = 22.0
        case .miniKey:
            fontSize = 10.0
            weight = .medium
            cornerRadius = 4.5
            borderWidth = 0.75
            hPad = 5.5
            fixedHeight = 18.0
            minWidth = 20.0
        case .statusPill:
            fontSize = 10.5
            weight = .medium
            cornerRadius = 9.5
            borderWidth = 0.0
            hPad = 8.5
            fixedHeight = 19.0
            minWidth = 20.0
        case .disabledTag:
            fontSize = 9.5
            weight = .semibold
            cornerRadius = 4.5
            borderWidth = 0.5
            hPad = 5.0
            fixedHeight = 16.0
            minWidth = 20.0
        }

        layer?.cornerRadius = cornerRadius
        layer?.borderWidth = borderWidth

        label.font = NSFont.systemFont(ofSize: fontSize, weight: weight)
        label.alignment = .center
        label.lineBreakMode = .byClipping
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: fixedHeight),
            widthAnchor.constraint(greaterThanOrEqualToConstant: minWidth),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: hPad),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -hPad),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        updateDynamicColors()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateDynamicColors()
    }

    private func updateDynamicColors() {
        let dark = isDarkAppearance
        effectiveAppearance.performAsCurrentDrawingAppearance {
            switch self.style {
            case .keycap:
                self.label.textColor = .labelColor
                self.layer?.backgroundColor = dark
                    ? NSColor.white.withAlphaComponent(0.115).cgColor
                    : NSColor.white.withAlphaComponent(0.80).cgColor
                self.layer?.borderColor = dark
                    ? NSColor.white.withAlphaComponent(0.20).cgColor
                    : NSColor.black.withAlphaComponent(0.13).cgColor

            case .headerKeycap:
                self.label.textColor = .labelColor
                self.layer?.backgroundColor = dark
                    ? NSColor.white.withAlphaComponent(0.16).cgColor
                    : NSColor.white.withAlphaComponent(0.92).cgColor
                self.layer?.borderColor = dark
                    ? NSColor.white.withAlphaComponent(0.26).cgColor
                    : NSColor.black.withAlphaComponent(0.17).cgColor

            case .doubleTap:
                self.label.textColor = .secondaryLabelColor
                self.layer?.backgroundColor = dark
                    ? NSColor.white.withAlphaComponent(0.06).cgColor
                    : NSColor.white.withAlphaComponent(0.45).cgColor
                self.layer?.borderColor = dark
                    ? NSColor.white.withAlphaComponent(0.13).cgColor
                    : NSColor.black.withAlphaComponent(0.10).cgColor

            case .miniKey:
                self.label.textColor = .secondaryLabelColor
                self.layer?.backgroundColor = dark
                    ? NSColor.white.withAlphaComponent(0.08).cgColor
                    : NSColor.white.withAlphaComponent(0.58).cgColor
                self.layer?.borderColor = dark
                    ? NSColor.white.withAlphaComponent(0.15).cgColor
                    : NSColor.black.withAlphaComponent(0.11).cgColor

            case .statusPill:
                self.label.textColor = .secondaryLabelColor
                self.layer?.backgroundColor = dark
                    ? NSColor.white.withAlphaComponent(0.075).cgColor
                    : NSColor.black.withAlphaComponent(0.055).cgColor
                self.layer?.borderColor = nil

            case .disabledTag:
                self.label.textColor = .secondaryLabelColor
                self.layer?.backgroundColor = dark
                    ? NSColor.white.withAlphaComponent(0.055).cgColor
                    : NSColor.black.withAlphaComponent(0.045).cgColor
                self.layer?.borderColor = dark
                    ? NSColor.white.withAlphaComponent(0.12).cgColor
                    : NSColor.black.withAlphaComponent(0.09).cgColor
            }
        }
    }
}

private final class HairlineDividerView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 1.0).isActive = true
        updateColor()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColor()
    }

    private func updateColor() {
        let dark = isDarkAppearance
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.layer?.backgroundColor = dark
                ? NSColor.white.withAlphaComponent(0.09).cgColor
                : NSColor.black.withAlphaComponent(0.08).cgColor
        }
    }
}

// MARK: - Unified Overlay Controller (Bento Peek + Spotlight Search)

private final class PeekOverlayWindowController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    private static let idleExitSeconds: TimeInterval = 15 * 60
    private static let searchPanelWidth: CGFloat = 600
    private static let searchListMaxHeight: CGFloat = 324
    private static let maxRenderedSearchRows = 50

    // Non-activating Peek Panel state
    private var peekPanel: NonActivatingHUDPanel?
    private var peekEffectView: BorderedVisualEffectView?
    private var isPeekVisible = false
    private var peekTransitionGeneration: UInt64 = 0

    // Interactive Spotlight Search Panel state
    private var searchPanel: SearchHUDPanel?
    private var searchEffectView: BorderedVisualEffectView?
    private var searchField: NSTextField?
    private var searchCountContainer: NSView?
    private var searchScrollView: NSScrollView?
    private var searchDocumentView: FlippedDocumentView?
    private var searchRowsStack: NSStackView?
    private var searchPreviewLabel: NSTextField?
    private var searchHintsStack: NSStackView?
    private var searchRowViews: [InteractiveSearchRowView] = []
    private var searchAllItems: [PeekSearchItem] = []
    private var searchFilteredItems: [PeekSearchItem] = []
    private var searchSelectedIndex: Int = 0
    private var isSearchVisible = false
    private var suppressResignHide = false
    private var searchKeyMonitor: Any?
    private var feedbackResetWorkItem: DispatchWorkItem?

    private let inputFD: Int32
    private var idleTimer: DispatchSourceTimer?

    init(inputFD: Int32 = STDIN_FILENO) {
        self.inputFD = inputFD
        super.init()
    }

    func startReadingStdin() {
        let readerThread = Thread { [weak self] in
            self?.readStdinLoop()
        }
        readerThread.name = "io.github.jardondiego.hotkeyd.peek-stdin"
        readerThread.qualityOfService = .userInteractive
        readerThread.start()
    }

    private func readStdinLoop() {
        var lineBuffer = Data()
        var oversized = false
        var chunk = [UInt8](repeating: 0, count: 8192)

        while true {
            let count = chunk.withUnsafeMutableBytes { raw -> ssize_t in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.read(inputFD, base, raw.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                break
            }
            if count == 0 {
                // Pipe EOF: daemon exited or crashed -> exit immediately (zero orphans).
                break
            }

            for i in 0..<count {
                let byte = chunk[i]
                if byte == 0x0A { // '\n'
                    if !oversized && !lineBuffer.isEmpty {
                        let frameData = lineBuffer
                        if let message = PeekWireMessage.decodeLine(frameData) {
                            DispatchQueue.main.async { [weak self] in
                                self?.handle(message)
                            }
                        }
                    }
                    lineBuffer.removeAll(keepingCapacity: true)
                    oversized = false
                } else if !oversized {
                    if lineBuffer.count < PeekWireMessage.maxFrameBytes {
                        lineBuffer.append(byte)
                    } else {
                        oversized = true
                        lineBuffer.removeAll(keepingCapacity: false)
                    }
                }
            }
        }

        DispatchQueue.main.async {
            self.terminateCleanly()
        }
    }

    private func handle(_ message: PeekWireMessage) {
        switch message {
        case .show(let snapshot):
            if isSearchVisible {
                // Restore the previously active app when transitioning out of active Search HUD
                // (e.g. mid-query `fn`-hold) so the user is never stranded in a windowless accessory app.
                hideSearch(restorePreviousApp: NSApp.isActive)
            }
            showPeek(snapshot)

        case .toggleSearch(let searchSnapshot):
            if IsSecureEventInputEnabled() {
                if isPeekVisible { hidePeekImmediate() }
                if isSearchVisible { hideSearch(restorePreviousApp: false) }
                return
            }
            if isSearchVisible {
                hideSearch(restorePreviousApp: true)
            } else {
                if isPeekVisible {
                    hidePeekImmediate()
                }
                showSearch(searchSnapshot)
            }

        case .hide:
            if isPeekVisible {
                hidePeek()
            }
            if isSearchVisible {
                hideSearch(restorePreviousApp: false)
            }

        case .quit:
            terminateCleanly()
        }
    }

    private func terminateCleanly() {
        cancelIdleTimer()
        removeSearchKeyMonitor()
        feedbackResetWorkItem?.cancel()
        searchAllItems.removeAll(keepingCapacity: false)
        searchFilteredItems.removeAll(keepingCapacity: false)
        peekPanel?.orderOut(nil)
        searchPanel?.orderOut(nil)
        Log.flush()
        if inputFD != STDIN_FILENO && inputFD >= 0 {
            close(inputFD)
        }
        exit(0)
    }

    private func cancelIdleTimer() {
        idleTimer?.cancel()
        idleTimer = nil
    }

    private func armIdleTimerIfHidden() {
        guard !isPeekVisible && !isSearchVisible else { return }
        cancelIdleTimer()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.idleExitSeconds, leeway: .seconds(15))
        timer.setEventHandler { [weak self] in
            guard let self, !self.isPeekVisible, !self.isSearchVisible else { return }
            if ShellRunner.currentInFlightCount > 0 {
                // Defer exit while a Search-launched shell command is still running so its
                // timeout killer and actions.log completion record stay intact.
                self.armIdleTimerIfHidden()
                return
            }
            self.terminateCleanly()
        }
        timer.resume()
        idleTimer = timer
    }

    private func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouse) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    // MARK: - Non-Activating Bento Peek Panel

    private func ensurePeekPanel() -> (NonActivatingHUDPanel, BorderedVisualEffectView) {
        if let peekPanel, let peekEffectView {
            return (peekPanel, peekEffectView)
        }
        let created = NonActivatingHUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 340),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        created.isFloatingPanel = true
        created.level = .floating
        created.isOpaque = false
        created.backgroundColor = .clear
        created.hasShadow = true
        created.hidesOnDeactivate = false
        created.ignoresMouseEvents = true
        created.isMovable = false
        created.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]

        let visual = BorderedVisualEffectView(frame: created.contentRect(forFrameRect: created.frame))
        visual.autoresizingMask = [.width, .height]
        created.contentView = visual

        self.peekPanel = created
        self.peekEffectView = visual
        return (created, visual)
    }

    private func showPeek(_ snapshot: PeekSnapshot) {
        guard !IsSecureEventInputEnabled() else {
            hidePeekImmediate()
            return
        }
        cancelIdleTimer()
        peekTransitionGeneration &+= 1
        let (panel, visual) = ensurePeekPanel()

        let contentView = buildPeekContentView(for: snapshot)
        visual.subviews.forEach { $0.removeFromSuperview() }

        let targetScreen = screenUnderMouse()
        let visibleFrame = targetScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let maxPanelWidth = min(1040, max(460, floor(visibleFrame.width * 0.84)))
        let maxPanelHeight = min(760, max(260, floor(visibleFrame.height * 0.78)))

        contentView.translatesAutoresizingMaskIntoConstraints = false
        visual.addSubview(contentView)
        let bottomConstraint = contentView.bottomAnchor.constraint(equalTo: visual.bottomAnchor, constant: -16)
        bottomConstraint.priority = .defaultHigh
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: visual.leadingAnchor, constant: 22),
            contentView.trailingAnchor.constraint(equalTo: visual.trailingAnchor, constant: -22),
            contentView.topAnchor.constraint(equalTo: visual.topAnchor, constant: 18),
            bottomConstraint
        ])

        visual.layoutSubtreeIfNeeded()
        let fitting = contentView.fittingSize
        let computedWidth = min(maxPanelWidth, max(380, ceil(fitting.width + 44)))
        let computedHeight = min(maxPanelHeight, max(132, ceil(fitting.height + 34)))

        // Lock panel geometry while already visible in pinned mode so spotlighting modifiers
        // produces zero pixel shift / layout jump.
        let frame: NSRect
        if isPeekVisible && snapshot.mode == .pinned
            && panel.frame.width >= computedWidth
            && panel.frame.height >= computedHeight {
            frame = panel.frame
        } else {
            let originX = floor(visibleFrame.midX - computedWidth / 2.0)
            let originY = floor(visibleFrame.midY - computedHeight / 2.0)
            frame = NSRect(x: originX, y: originY, width: computedWidth, height: computedHeight)
        }
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()

        // If a prior Search HUD dismissal called `NSApp.hide(nil)`, unhide without stealing focus
        // so the non-activating Bento Peek panel renders reliably.
        if NSApp.isHidden {
            NSApp.unhideWithoutActivation()
        }

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !isPeekVisible {
            isPeekVisible = true
            if reduceMotion {
                panel.alphaValue = 1.0
                panel.orderFrontRegardless()
            } else {
                panel.alphaValue = 0.0
                panel.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.10
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().alphaValue = 1.0
                }
            }
        } else {
            panel.alphaValue = 1.0
            panel.orderFrontRegardless()
        }
    }

    private func hidePeekImmediate() {
        peekTransitionGeneration &+= 1
        isPeekVisible = false
        peekPanel?.orderOut(nil)
    }

    private func hidePeek() {
        peekTransitionGeneration &+= 1
        let gen = peekTransitionGeneration
        guard isPeekVisible, let panel = peekPanel else {
            armIdleTimerIfHidden()
            return
        }
        isPeekVisible = false
        armIdleTimerIfHidden()

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.orderOut(nil)
            return
        }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.09
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            guard let self, self.peekTransitionGeneration == gen else { return }
            self.peekPanel?.orderOut(nil)
        })
    }

    // MARK: - Interactive Spotlight Search Panel

    private func ensureSearchPanel() -> SearchHUDPanel {
        if let searchPanel {
            return searchPanel
        }
        let panel = SearchHUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.searchPanelWidth, height: 420),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.isMovable = false
        panel.delegate = self
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle
        ]

        let visual = BorderedVisualEffectView(frame: panel.contentRect(forFrameRect: panel.frame))
        visual.autoresizingMask = [.width, .height]
        panel.contentView = visual

        // Build persistent Spotlight skeleton inside `visual`
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false
        visual.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: visual.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: visual.trailingAnchor),
            root.topAnchor.constraint(equalTo: visual.topAnchor),
            root.bottomAnchor.constraint(equalTo: visual.bottomAnchor)
        ])

        // 1. Top search bar
        let headerWrap = NSView()
        headerWrap.translatesAutoresizingMaskIntoConstraints = false
        let headerStack = NSStackView()
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = 10
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        if let iconImage = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search") {
            let iconConfig = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            let iconView = NSImageView(image: iconImage.withSymbolConfiguration(iconConfig) ?? iconImage)
            iconView.contentTintColor = .secondaryLabelColor
            iconView.setContentHuggingPriority(.required, for: .horizontal)
            headerStack.addArrangedSubview(iconView)
        }

        let input = NSTextField()
        input.placeholderString = "Search shortcuts…"
        input.font = NSFont.systemFont(ofSize: 16, weight: .regular)
        input.textColor = .labelColor
        input.isBezeled = false
        input.isBordered = false
        input.drawsBackground = false
        input.focusRingType = .none
        input.lineBreakMode = .byTruncatingTail
        input.usesSingleLineMode = true
        input.delegate = self
        input.setContentHuggingPriority(.defaultLow, for: .horizontal)
        input.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        headerStack.addArrangedSubview(input)

        let countHost = NSView()
        countHost.translatesAutoresizingMaskIntoConstraints = false
        countHost.setContentHuggingPriority(.required, for: .horizontal)
        headerStack.addArrangedSubview(countHost)

        headerWrap.addSubview(headerStack)
        NSLayoutConstraint.activate([
            headerWrap.heightAnchor.constraint(equalToConstant: 52),
            headerStack.leadingAnchor.constraint(equalTo: headerWrap.leadingAnchor, constant: 18),
            headerStack.trailingAnchor.constraint(equalTo: headerWrap.trailingAnchor, constant: -16),
            headerStack.centerYAnchor.constraint(equalTo: headerWrap.centerYAnchor)
        ])
        root.addArrangedSubview(headerWrap)
        headerWrap.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        let topDivider = HairlineDividerView()
        root.addArrangedSubview(topDivider)
        topDivider.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        // 2. Scrollable vertical results list
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let docView = FlippedDocumentView()
        docView.translatesAutoresizingMaskIntoConstraints = false

        let rowsStack = NSStackView()
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 2
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        docView.addSubview(rowsStack)
        NSLayoutConstraint.activate([
            rowsStack.leadingAnchor.constraint(equalTo: docView.leadingAnchor, constant: 10),
            rowsStack.trailingAnchor.constraint(equalTo: docView.trailingAnchor, constant: -10),
            rowsStack.topAnchor.constraint(equalTo: docView.topAnchor, constant: 8),
            rowsStack.bottomAnchor.constraint(equalTo: docView.bottomAnchor, constant: -8)
        ])
        scroll.documentView = docView
        docView.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true

        root.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        let bottomDivider = HairlineDividerView()
        root.addArrangedSubview(bottomDivider)
        bottomDivider.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        // 3. Bottom command preview + keycap action hints bar
        let footerWrap = NSView()
        footerWrap.translatesAutoresizingMaskIntoConstraints = false
        let footerStack = NSStackView()
        footerStack.orientation = .vertical
        footerStack.alignment = .leading
        footerStack.spacing = 6
        footerStack.translatesAutoresizingMaskIntoConstraints = false

        let previewField = NSTextField(labelWithString: "")
        previewField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        previewField.textColor = .secondaryLabelColor
        previewField.lineBreakMode = .byTruncatingTail
        previewField.maximumNumberOfLines = 1
        previewField.translatesAutoresizingMaskIntoConstraints = false
        footerStack.addArrangedSubview(previewField)
        previewField.widthAnchor.constraint(equalTo: footerStack.widthAnchor).isActive = true

        let hintsStack = NSStackView()
        hintsStack.orientation = .horizontal
        hintsStack.alignment = .centerY
        hintsStack.spacing = 6
        hintsStack.translatesAutoresizingMaskIntoConstraints = false
        footerStack.addArrangedSubview(hintsStack)

        footerWrap.addSubview(footerStack)
        NSLayoutConstraint.activate([
            footerWrap.heightAnchor.constraint(equalToConstant: 56),
            footerStack.leadingAnchor.constraint(equalTo: footerWrap.leadingAnchor, constant: 18),
            footerStack.trailingAnchor.constraint(equalTo: footerWrap.trailingAnchor, constant: -18),
            footerStack.centerYAnchor.constraint(equalTo: footerWrap.centerYAnchor)
        ])
        root.addArrangedSubview(footerWrap)
        footerWrap.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        self.searchPanel = panel
        self.searchEffectView = visual
        self.searchField = input
        self.searchCountContainer = countHost
        self.searchScrollView = scroll
        self.searchDocumentView = docView
        self.searchRowsStack = rowsStack
        self.searchPreviewLabel = previewField
        self.searchHintsStack = hintsStack
        return panel
    }

    private func showSearch(_ snapshot: PeekSearchSnapshot) {
        guard !IsSecureEventInputEnabled() else {
            hideSearch(restorePreviousApp: false)
            return
        }
        cancelIdleTimer()
        feedbackResetWorkItem?.cancel()
        feedbackResetWorkItem = nil

        let panel = ensureSearchPanel()
        searchAllItems = snapshot.items
        searchFilteredItems = snapshot.items
        searchSelectedIndex = 0
        searchField?.stringValue = ""

        rebuildSearchResultsUI(query: "")
        layoutAndPositionSearchPanel(panel)

        suppressResignHide = true
        isSearchVisible = true
        installSearchKeyMonitor()

        NSApp.activate(ignoringOtherApps: true)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion {
            panel.alphaValue = 1.0
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.alphaValue = 0.0
            panel.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.10
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1.0
            }
        }
        if let field = searchField {
            panel.makeFirstResponder(field)
        }
        DispatchQueue.main.async { [weak self] in
            self?.suppressResignHide = false
        }
    }

    private func layoutAndPositionSearchPanel(_ panel: SearchHUDPanel) {
        let targetScreen = screenUnderMouse()
        let visibleFrame = targetScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)

        let rowCount = max(1, min(searchFilteredItems.count, 8))
        let desiredListHeight = min(Self.searchListMaxHeight, CGFloat(rowCount) * 38.0 + 18.0)
        // Header (52) + dividers (2) + list + footer (56)
        let totalHeight = min(floor(visibleFrame.height * 0.72), 110.0 + desiredListHeight)
        let totalWidth = min(Self.searchPanelWidth, floor(visibleFrame.width * 0.88))

        let originX = floor(visibleFrame.midX - totalWidth / 2.0)
        // Optical Spotlight placement slightly above vertical center
        let originY = floor(visibleFrame.midY - totalHeight / 2.0 + visibleFrame.height * 0.06)
        let clampedY = max(visibleFrame.minY + 24, min(originY, visibleFrame.maxY - totalHeight - 24))

        panel.setFrame(NSRect(x: originX, y: clampedY, width: totalWidth, height: totalHeight), display: true)
        panel.invalidateShadow()
    }

    private func hideSearch(restorePreviousApp: Bool) {
        guard isSearchVisible else { return }
        isSearchVisible = false
        suppressResignHide = true
        removeSearchKeyMonitor()
        feedbackResetWorkItem?.cancel()
        feedbackResetWorkItem = nil
        searchPanel?.orderOut(nil)
        // Clear plaintext commands & query from helper RAM immediately on dismiss.
        searchAllItems.removeAll(keepingCapacity: false)
        searchFilteredItems.removeAll(keepingCapacity: false)
        searchRowViews.removeAll(keepingCapacity: false)
        searchField?.stringValue = ""
        searchPreviewLabel?.stringValue = ""
        if restorePreviousApp {
            NSApp.hide(nil)
        }
        suppressResignHide = false
        armIdleTimerIfHidden()
    }

    private func rebuildSearchResultsUI(query: String) {
        guard let rowsStack = searchRowsStack else { return }

        // Update count pill
        if let countHost = searchCountContainer {
            countHost.subviews.forEach { $0.removeFromSuperview() }
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let countText: String
            if trimmed.isEmpty {
                countText = searchAllItems.count == 1 ? "1 shortcut" : "\(searchAllItems.count) shortcuts"
            } else {
                countText = "\(searchFilteredItems.count) of \(searchAllItems.count)"
            }
            let pill = KeycapPillView(text: countText, style: .statusPill)
            countHost.addSubview(pill)
            NSLayoutConstraint.activate([
                pill.leadingAnchor.constraint(equalTo: countHost.leadingAnchor),
                pill.trailingAnchor.constraint(equalTo: countHost.trailingAnchor),
                pill.topAnchor.constraint(equalTo: countHost.topAnchor),
                pill.bottomAnchor.constraint(equalTo: countHost.bottomAnchor)
            ])
        }

        // Rebuild rows
        for view in rowsStack.arrangedSubviews {
            rowsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        searchRowViews.removeAll()

        if searchFilteredItems.isEmpty {
            let emptyWrap = NSView()
            emptyWrap.translatesAutoresizingMaskIntoConstraints = false
            let emptyLabel = NSTextField(labelWithString: searchAllItems.isEmpty
                ? "No shortcuts configured yet. Add one with hotkeyd add."
                : "No matching shortcuts.")
            emptyLabel.font = NSFont.systemFont(ofSize: 13, weight: .regular)
            emptyLabel.textColor = .tertiaryLabelColor
            emptyLabel.translatesAutoresizingMaskIntoConstraints = false
            emptyWrap.addSubview(emptyLabel)
            NSLayoutConstraint.activate([
                emptyWrap.heightAnchor.constraint(equalToConstant: 44),
                emptyLabel.leadingAnchor.constraint(equalTo: emptyWrap.leadingAnchor, constant: 10),
                emptyLabel.centerYAnchor.constraint(equalTo: emptyWrap.centerYAnchor)
            ])
            rowsStack.addArrangedSubview(emptyWrap)
            emptyWrap.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        } else {
            let visibleCount = min(searchFilteredItems.count, Self.maxRenderedSearchRows)
            searchSelectedIndex = max(0, min(searchSelectedIndex, visibleCount - 1))
            for index in 0..<visibleCount {
                let item = searchFilteredItems[index]
                let row = InteractiveSearchRowView(
                    index: index,
                    item: item,
                    selected: index == searchSelectedIndex,
                    onSelect: { [weak self] idx in
                        self?.selectSearchRow(idx)
                    },
                    onActivate: { [weak self] idx in
                        self?.selectSearchRow(idx)
                        self?.activateSelectedSearchItem()
                    }
                )
                rowsStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
                searchRowViews.append(row)
            }
            if searchFilteredItems.count > visibleCount {
                let overflowWrap = NSView()
                overflowWrap.translatesAutoresizingMaskIntoConstraints = false
                let overflowLabel = NSTextField(labelWithString: "Showing top \(visibleCount) of \(searchFilteredItems.count) matches — keep typing to narrow")
                overflowLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
                overflowLabel.textColor = .tertiaryLabelColor
                overflowLabel.translatesAutoresizingMaskIntoConstraints = false
                overflowWrap.addSubview(overflowLabel)
                NSLayoutConstraint.activate([
                    overflowWrap.heightAnchor.constraint(equalToConstant: 28),
                    overflowLabel.leadingAnchor.constraint(equalTo: overflowWrap.leadingAnchor, constant: 10),
                    overflowLabel.centerYAnchor.constraint(equalTo: overflowWrap.centerYAnchor)
                ])
                rowsStack.addArrangedSubview(overflowWrap)
                overflowWrap.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            }
        }

        updateSearchFooterPreview(flashMessage: nil)
        scrollSelectedSearchRowIntoView()
    }

    private func selectSearchRow(_ newIndex: Int) {
        guard !searchRowViews.isEmpty else { return }
        let clamped = max(0, min(newIndex, searchRowViews.count - 1))
        if clamped != searchSelectedIndex {
            if searchSelectedIndex < searchRowViews.count {
                searchRowViews[searchSelectedIndex].setSelected(false)
            }
            searchSelectedIndex = clamped
            if searchSelectedIndex < searchRowViews.count {
                searchRowViews[searchSelectedIndex].setSelected(true)
            }
        }
        feedbackResetWorkItem?.cancel()
        feedbackResetWorkItem = nil
        updateSearchFooterPreview(flashMessage: nil)
        scrollSelectedSearchRowIntoView()
    }

    private func scrollSelectedSearchRowIntoView() {
        guard searchSelectedIndex < searchRowViews.count else { return }
        let row = searchRowViews[searchSelectedIndex]
        searchDocumentView?.layoutSubtreeIfNeeded()
        row.scrollToVisible(row.bounds.insetBy(dx: 0, dy: -6))
    }

    private func updateSearchFooterPreview(flashMessage: String?) {
        guard let previewLabel = searchPreviewLabel, let hintsStack = searchHintsStack else { return }

        let selected: PeekSearchItem? = (searchSelectedIndex < searchFilteredItems.count)
            ? searchFilteredItems[searchSelectedIndex]
            : nil

        if let flashMessage {
            previewLabel.textColor = .labelColor
            previewLabel.stringValue = flashMessage
        } else if let selected {
            previewLabel.textColor = .secondaryLabelColor
            // Recompute preview from `rawCommand` locally when present so a direct `__peek-overlay`
            // caller cannot spoof a benign preview for a different command.
            let renderedPreview = selected.rawCommand.isEmpty
                ? StrictModes.sanitizeTerminalText(selected.commandPreview, limit: 110)
                : PeekSearchBuilder.safeCommandPreview(selected.rawCommand)
            previewLabel.stringValue = renderedPreview
        } else {
            previewLabel.textColor = .tertiaryLabelColor
            previewLabel.stringValue = ""
        }

        for view in hintsStack.arrangedSubviews {
            hintsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        func addHint(_ text: String, secondary: Bool = false) {
            let f = NSTextField(labelWithString: text)
            f.font = NSFont.systemFont(ofSize: 10.5, weight: .regular)
            f.textColor = secondary ? .secondaryLabelColor : .tertiaryLabelColor
            hintsStack.addArrangedSubview(f)
        }
        func addDot() {
            let d = NSTextField(labelWithString: "·")
            d.font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
            d.textColor = .quaternaryLabelColor
            hintsStack.addArrangedSubview(d)
        }

        if let selected {
            if selected.runnableInHelper {
                hintsStack.addArrangedSubview(KeycapPillView(text: "↩", style: .miniKey))
                addHint("Run", secondary: true)
            } else {
                addHint("Press \(selected.keyDisplay) directly", secondary: true)
            }
            addDot()
            hintsStack.addArrangedSubview(KeycapPillView(text: "⌘C", style: .miniKey))
            addHint("Copy keys")
            addDot()
            hintsStack.addArrangedSubview(KeycapPillView(text: "⌘⇧C", style: .miniKey))
            addHint("Copy cmd")
            addDot()
        }
        hintsStack.addArrangedSubview(KeycapPillView(text: "Esc", style: .miniKey))
        addHint("Close")
    }

    private func flashSearchNotice(_ text: String) {
        feedbackResetWorkItem?.cancel()
        updateSearchFooterPreview(flashMessage: text)
        let work = DispatchWorkItem { [weak self] in
            self?.updateSearchFooterPreview(flashMessage: nil)
        }
        feedbackResetWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }

    private func activateSelectedSearchItem() {
        guard isSearchVisible else { return }
        guard !IsSecureEventInputEnabled() else {
            hideSearch(restorePreviousApp: false)
            return
        }
        guard PauseState.loadActive(from: Paths.pauseState, pruneExpired: false) == nil else {
            hideSearch(restorePreviousApp: false)
            return
        }
        guard searchSelectedIndex < searchFilteredItems.count else { return }
        let item = searchFilteredItems[searchSelectedIndex]

        // Strict one-way security gate: never execute [AX], SELECTED_TEXT, or disabled bindings
        // from the helper; independently re-check `rawCommand` rather than trusting only wire flags.
        guard item.runnableInHelper,
              item.enabled,
              !item.allowAccessibility,
              !item.usesSelectedText,
              !SelectionReader.commandUsesSelectedText(item.rawCommand) else {
            let hint = item.directKeyHint ?? "Press \(item.keyDisplay) directly"
            flashSearchNotice(hint)
            return
        }

        guard !item.rawCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !item.rawCommand.contains("\0") else {
            flashSearchNotice("Shortcut has an empty or invalid command")
            return
        }

        // Native NSWorkspace launches activate their target app directly; avoid racing WindowServer
        // by only restoring the previous app for non-native shell commands.
        let isNativeLaunch = Action.migratedFromShellCommand(item.rawCommand) != nil
        hideSearch(restorePreviousApp: !isNativeLaunch)
        let action = Action.shell(
            command: item.rawCommand,
            cwd: item.cwd,
            timeoutMilliseconds: item.timeoutMilliseconds
        )
        ShellRunner.spawn(
            name: item.logName,
            action: action,
            allowAccessibility: false,
            selectionTarget: nil
        )
    }

    private func copySelectedKeys() {
        guard isSearchVisible, searchSelectedIndex < searchFilteredItems.count else { return }
        let item = searchFilteredItems[searchSelectedIndex]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.canonicalKeys, forType: .string)
        flashSearchNotice("Copied keys: \(item.canonicalKeys)")
    }

    private func copySelectedCommand() {
        guard isSearchVisible, searchSelectedIndex < searchFilteredItems.count else { return }
        let item = searchFilteredItems[searchSelectedIndex]
        let isPreviewFallback = item.rawCommand.isEmpty
        let textToCopy = isPreviewFallback ? item.commandPreview : item.rawCommand
        let containsRedactedSecret = !isPreviewFallback
            && PeekLabeler.redactCommandPreview(textToCopy, limit: 4096)
                != StrictModes.sanitizeTerminalText(textToCopy, limit: 4096)

        let pb = NSPasteboard.general
        pb.prepareForNewContents(with: .currentHostOnly)
        let pbItem = NSPasteboardItem()
        pbItem.setString(textToCopy, forType: .string)
        pbItem.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        if containsRedactedSecret {
            pbItem.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        }
        pb.writeObjects([pbItem])
        if containsRedactedSecret {
            flashSearchNotice("Copied command (concealed, local-only)")
        } else if isPreviewFallback {
            flashSearchNotice("Copied command preview (local-only)")
        } else {
            flashSearchNotice("Copied command (local-only)")
        }
    }

    private func installSearchKeyMonitor() {
        removeSearchKeyMonitor()
        searchKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isSearchVisible else { return event }
            let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
            let keyChar = event.charactersIgnoringModifiers?.lowercased() ?? ""

            // Esc closes Search immediately on first press (unless an IME composition is active).
            if event.keyCode == 53 && mods.isEmpty {
                if let editor = self.searchField?.currentEditor() as? NSTextView, editor.hasMarkedText() {
                    return event
                }
                self.hideSearch(restorePreviousApp: true)
                return nil
            }
            // Ctrl-N / Ctrl-P navigation (layout-independent via charactersIgnoringModifiers)
            if mods == [.control] && keyChar == "n" {
                self.selectSearchRow(self.searchSelectedIndex + 1)
                return nil
            }
            if mods == [.control] && keyChar == "p" {
                self.selectSearchRow(self.searchSelectedIndex - 1)
                return nil
            }
            // Cmd+Shift+C copies underlying command (layout-independent)
            if mods == [.command, .shift] && keyChar == "c" {
                self.copySelectedCommand()
                return nil
            }
            // Cmd+C copies canonical shortcut keys (unless text is actively highlighted in search input)
            if mods == [.command] && keyChar == "c" {
                let hasSelectedQueryText: Bool
                if let editor = self.searchField?.currentEditor() {
                    hasSelectedQueryText = editor.selectedRange.length > 0
                } else {
                    hasSelectedQueryText = false
                }
                if !hasSelectedQueryText {
                    self.copySelectedKeys()
                    return nil
                }
            }
            return event
        }
    }

    private func removeSearchKeyMonitor() {
        if let monitor = searchKeyMonitor {
            NSEvent.removeMonitor(monitor)
            searchKeyMonitor = nil
        }
    }

    // MARK: - NSWindowDelegate & NSTextFieldDelegate

    func windowDidResignKey(_ notification: Notification) {
        guard !suppressResignHide, isSearchVisible else { return }
        hideSearch(restorePreviousApp: false)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard isSearchVisible, let field = searchField else { return }
        let query = field.stringValue
        searchFilteredItems = PeekSearchMatcher.filter(searchAllItems, query: query)
        searchSelectedIndex = 0
        rebuildSearchResultsUI(query: query)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard isSearchVisible else { return false }
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            selectSearchRow(searchSelectedIndex + 1)
            return true
        }
        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            selectSearchRow(searchSelectedIndex - 1)
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            activateSelectedSearchItem()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            hideSearch(restorePreviousApp: true)
            return true
        }
        return false
    }

    // MARK: - Bento Peek View Construction

    private func buildPeekContentView(for snapshot: PeekSnapshot) -> NSView {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.translatesAutoresizingMaskIntoConstraints = false

        let headerRow = buildPeekHeaderRow(for: snapshot)
        root.addArrangedSubview(headerRow)
        headerRow.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        if snapshot.groups.isEmpty {
            let emptyCard = BentoGroupCardView(elevated: false)
            let emptyLabel = NSTextField(labelWithString: "No shortcuts configured yet. Add one with `hotkeyd add`.")
            emptyLabel.font = NSFont.systemFont(ofSize: 13, weight: .regular)
            emptyLabel.textColor = .secondaryLabelColor
            emptyLabel.translatesAutoresizingMaskIntoConstraints = false
            emptyCard.addSubview(emptyLabel)
            NSLayoutConstraint.activate([
                emptyLabel.leadingAnchor.constraint(equalTo: emptyCard.leadingAnchor, constant: 14),
                emptyLabel.trailingAnchor.constraint(equalTo: emptyCard.trailingAnchor, constant: -14),
                emptyLabel.topAnchor.constraint(equalTo: emptyCard.topAnchor, constant: 12),
                emptyLabel.bottomAnchor.constraint(equalTo: emptyCard.bottomAnchor, constant: -12)
            ])
            root.addArrangedSubview(emptyCard)
            emptyCard.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        } else {
            let columnsView = buildBalancedColumns(for: snapshot)
            root.addArrangedSubview(columnsView)
            columnsView.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        }

        let footerDivider = HairlineDividerView()
        root.addArrangedSubview(footerDivider)
        footerDivider.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        let footerRow = buildPeekFooterRow(for: snapshot)
        root.addArrangedSubview(footerRow)
        footerRow.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        return root
    }

    private func buildPeekHeaderRow(for snapshot: PeekSnapshot) -> NSView {
        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 8
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        let spotlightActive = snapshot.mode == .pinned && !snapshot.activeModifierLabels.isEmpty

        if spotlightActive {
            let prefix = NSTextField(labelWithString: "Related to")
            prefix.font = NSFont.systemFont(ofSize: 13.5, weight: .medium)
            prefix.textColor = .secondaryLabelColor
            headerRow.addArrangedSubview(prefix)

            for (idx, modLabel) in snapshot.activeModifierLabels.enumerated() {
                if idx > 0 {
                    let plus = NSTextField(labelWithString: "+")
                    plus.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
                    plus.textColor = .tertiaryLabelColor
                    headerRow.addArrangedSubview(plus)
                }
                headerRow.addArrangedSubview(KeycapPillView(text: modLabel, style: .headerKeycap))
            }
            headerRow.addArrangedSubview(KeycapPillView(text: "Pinned", style: .statusPill))
        } else {
            let titleField = NSTextField(labelWithString: "Shortcuts")
            titleField.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
            titleField.textColor = .labelColor
            headerRow.addArrangedSubview(titleField)
            if snapshot.mode == .pinned {
                headerRow.addArrangedSubview(KeycapPillView(text: "Pinned", style: .statusPill))
            }
        }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerRow.addArrangedSubview(spacer)

        let countText: String
        if spotlightActive {
            countText = "\(snapshot.matchedCount) matching · \(snapshot.totalCount) total"
        } else {
            countText = snapshot.totalCount == 1 ? "1 shortcut" : "\(snapshot.totalCount) shortcuts"
        }
        headerRow.addArrangedSubview(KeycapPillView(text: countText, style: .statusPill))

        return headerRow
    }

    private func buildPeekFooterRow(for snapshot: PeekSnapshot) -> NSView {
        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 6
        footer.translatesAutoresizingMaskIntoConstraints = false

        func addHintText(_ text: String, secondary: Bool = false) {
            let field = NSTextField(labelWithString: text)
            field.font = NSFont.systemFont(ofSize: 11, weight: .regular)
            field.textColor = secondary ? .secondaryLabelColor : .tertiaryLabelColor
            footer.addArrangedSubview(field)
        }

        func addDot() {
            let dot = NSTextField(labelWithString: "·")
            dot.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            dot.textColor = .quaternaryLabelColor
            footer.addArrangedSubview(dot)
        }

        if snapshot.totalCount == 0 {
            addHintText("Add shortcuts with hotkeyd add")
            return footer
        }

        if snapshot.mode == .pinned {
            if snapshot.activeModifierLabels.isEmpty {
                footer.addArrangedSubview(KeycapPillView(text: "Esc", style: .miniKey))
                addHintText("Close", secondary: true)
                addDot()
                footer.addArrangedSubview(KeycapPillView(text: "/", style: .miniKey))
                addHintText("Search", secondary: true)
                addDot()
                addHintText("Hold any modifier to show related shortcuts", secondary: true)
            } else {
                if snapshot.matchedCount == 0 {
                    let mods = snapshot.activeModifierLabels.joined(separator: " + ")
                    addHintText("No shortcuts for \(mods)", secondary: true)
                    addDot()
                }
                addHintText("Release to show all", secondary: true)
                if snapshot.matchedCount > 0 {
                    addDot()
                    addHintText("Press key to run")
                }
                addDot()
                footer.addArrangedSubview(KeycapPillView(text: "Esc", style: .miniKey))
                addHintText("Close")
            }
        } else {
            footer.addArrangedSubview(KeycapPillView(text: "Tab", style: .miniKey))
            addHintText("Pin", secondary: true)
            addDot()
            addHintText("Release")
            if let triggerLabel = snapshot.activeModifierLabels.first {
                footer.addArrangedSubview(KeycapPillView(text: triggerLabel, style: .miniKey))
            }
            addHintText("to hide")
            addDot()
            addHintText("Press key to run")
        }

        return footer
    }

    private func buildBalancedColumns(for snapshot: PeekSnapshot) -> NSView {
        let groups = snapshot.groups
        let totalWeight = groups.reduce(0) { $0 + $1.entries.count + 2 }
        let desiredColumns: Int
        if totalWeight <= 14 {
            desiredColumns = 1
        } else if totalWeight <= 34 {
            desiredColumns = 2
        } else {
            desiredColumns = 3
        }
        let columnCount = max(1, min(desiredColumns, groups.count))

        var buckets: [[PeekGroup]] = Array(repeating: [], count: columnCount)
        var weights: [Int] = Array(repeating: 0, count: columnCount)

        for group in groups {
            let targetIndex = weights.enumerated().min(by: { $0.element < $1.element })?.offset ?? 0
            buckets[targetIndex].append(group)
            weights[targetIndex] += group.entries.count + 2
        }

        let horizontal = NSStackView()
        horizontal.orientation = .horizontal
        horizontal.alignment = .top
        horizontal.spacing = 12
        horizontal.distribution = .fillEqually
        horizontal.translatesAutoresizingMaskIntoConstraints = false

        let spotlightActive = snapshot.mode == .pinned && !snapshot.activeModifierLabels.isEmpty
        let minColumnWidth: CGFloat = columnCount == 1 ? 340 : (columnCount == 2 ? 280 : 255)

        for bucket in buckets where !bucket.isEmpty {
            let column = NSStackView()
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 12
            column.translatesAutoresizingMaskIntoConstraints = false
            column.widthAnchor.constraint(greaterThanOrEqualToConstant: minColumnWidth).isActive = true

            for group in bucket {
                let card = buildGroupCard(
                    group,
                    spotlightActive: spotlightActive,
                    dimUnmatched: snapshot.dimUnmatched
                )
                column.addArrangedSubview(card)
                card.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            }
            horizontal.addArrangedSubview(column)
        }
        return horizontal
    }

    private func buildGroupCard(
        _ group: PeekGroup,
        spotlightActive: Bool,
        dimUnmatched: Bool
    ) -> NSView {
        let elevated = spotlightActive && group.highlighted
        let card = BentoGroupCardView(elevated: elevated)
        if spotlightActive && !group.highlighted {
            card.alphaValue = dimUnmatched ? 0.30 : 0.78
        } else {
            card.alphaValue = 1.0
        }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false

        let header = NSTextField(labelWithString: "")
        let headerColor: NSColor = elevated ? .labelColor : .secondaryLabelColor
        header.attributedStringValue = NSAttributedString(
            string: group.title.uppercased(),
            attributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
                .foregroundColor: headerColor,
                .kern: 0.75
            ]
        )
        let headerContainer = NSView()
        headerContainer.translatesAutoresizingMaskIntoConstraints = false
        header.translatesAutoresizingMaskIntoConstraints = false
        headerContainer.addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor, constant: 6),
            header.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor, constant: -6),
            header.topAnchor.constraint(equalTo: headerContainer.topAnchor),
            header.bottomAnchor.constraint(equalTo: headerContainer.bottomAnchor)
        ])
        stack.addArrangedSubview(headerContainer)
        headerContainer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.setCustomSpacing(7, after: headerContainer)

        for entry in group.entries {
            let row = buildPeekEntryRow(
                entry,
                spotlightActive: spotlightActive,
                dimUnmatched: dimUnmatched
            )
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 7),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -7),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 11),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -9)
        ])
        return card
    }

    private func buildPeekEntryRow(
        _ entry: PeekEntry,
        spotlightActive: Bool,
        dimUnmatched: Bool
    ) -> NSView {
        let isSpotlightMatch = spotlightActive && entry.matched
        let container = SpotlightRowView(highlighted: isSpotlightMatch)
        if spotlightActive && !entry.matched {
            container.alphaValue = dimUnmatched ? 0.28 : 0.72
        } else {
            container.alphaValue = 1.0
        }

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 22).isActive = true

        let leftStack = NSStackView()
        leftStack.orientation = .horizontal
        leftStack.alignment = .centerY
        leftStack.spacing = 6
        leftStack.translatesAutoresizingMaskIntoConstraints = false
        leftStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        leftStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let labelField = NSTextField(labelWithString: entry.label)
        labelField.font = NSFont.systemFont(ofSize: 13, weight: isSpotlightMatch ? .medium : .regular)
        labelField.textColor = entry.enabled ? .labelColor : .tertiaryLabelColor
        labelField.lineBreakMode = .byTruncatingTail
        labelField.maximumNumberOfLines = 1
        labelField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labelField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        leftStack.addArrangedSubview(labelField)

        if !entry.enabled {
            leftStack.addArrangedSubview(KeycapPillView(text: "off", style: .disabledTag))
        }

        let pillsStack = NSStackView()
        pillsStack.orientation = .horizontal
        pillsStack.alignment = .centerY
        pillsStack.spacing = 4
        pillsStack.translatesAutoresizingMaskIntoConstraints = false
        pillsStack.setContentHuggingPriority(.required, for: .horizontal)
        pillsStack.setContentCompressionResistancePriority(.required, for: .horizontal)

        for token in entry.keyPills {
            if token == "›" {
                let arrow = NSTextField(labelWithString: "›")
                arrow.font = NSFont.systemFont(ofSize: 12, weight: .medium)
                arrow.textColor = .tertiaryLabelColor
                pillsStack.addArrangedSubview(arrow)
            } else if token == "2×" {
                pillsStack.addArrangedSubview(KeycapPillView(text: "2×", style: .doubleTap))
            } else {
                pillsStack.addArrangedSubview(KeycapPillView(text: token, style: .keycap))
            }
        }

        row.addArrangedSubview(leftStack)
        row.addArrangedSubview(pillsStack)

        container.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            row.topAnchor.constraint(equalTo: container.topAnchor, constant: 2.5),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2.5)
        ])
        return container
    }
}
