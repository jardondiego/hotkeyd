import AppKit
import ApplicationServices
import Carbon
import Foundation

/// Non-destructive Accessibility reader for the frontmost application's current text selection.
///
/// Used by `ShellRunner` when a shortcut command references `SELECTED_TEXT` so child shell
/// processes can keep `allowAccessibility == false` (disclaiming TCC responsibility) while still
/// operating on highlighted text. Never synthesizes `Cmd+C` and never mutates `NSPasteboard`.
public enum SelectionReader {
    /// Upper bound (256 KiB) so `SELECTED_TEXT` inside `envp` can never push `posix_spawn` past
    /// Darwin's 1 MiB `ARG_MAX` (`E2BIG`) limit.
    public static let maxSelectedTextUTF8Bytes = 262_144

    /// Per-call Mach IPC timeout (seconds) so an unresponsive frontmost app cannot stall a worker.
    private static let axMessagingTimeoutSeconds: Float = 0.25

    /// Overall wall-clock budget (seconds) for the retry loop so hung or slow apps never starve
    /// shortcut workers.
    private static let totalReadBudgetSeconds: Double = 0.45

    public enum SelectionStatus: String, Sendable, Equatable {
        case ok
        case empty
        case secure
        case disabled
        case untrusted
    }

    public struct SelectionResult: Sendable, Equatable {
        public let text: String
        public let status: SelectionStatus

        public init(text: String, status: SelectionStatus) {
            self.text = text
            self.status = status
        }
    }

    public struct TargetApp: Sendable, Equatable {
        public let pid: pid_t
        public let bundleIdentifier: String?

        public init(pid: pid_t, bundleIdentifier: String?) {
            self.pid = pid
            self.bundleIdentifier = bundleIdentifier
        }
    }

    /// Returns `true` when a shell command string references `SELECTED_TEXT`.
    public static func commandUsesSelectedText(_ command: String) -> Bool {
        command.contains("SELECTED_TEXT")
    }

    /// Preserves exact whitespace, indentation, and newlines while stripping embedded NUL bytes
    /// (which would truncate C `envp` strings) and capping length on a UTF-8 grapheme/scalar boundary.
    public static func sanitize(_ raw: String, maxUTF8Bytes: Int = maxSelectedTextUTF8Bytes) -> String {
        guard maxUTF8Bytes > 0, !raw.isEmpty else { return "" }
        let withoutNul = raw.contains("\0") ? raw.replacingOccurrences(of: "\0", with: "") : raw
        guard !withoutNul.isEmpty else { return "" }
        if withoutNul.utf8.count <= maxUTF8Bytes {
            return withoutNul
        }

        var result = ""
        result.reserveCapacity(maxUTF8Bytes)
        var usedBytes = 0
        for ch in withoutNul {
            let width = ch.utf8.count
            if usedBytes + width <= maxUTF8Bytes {
                result.append(ch)
                usedBytes += width
            } else {
                if usedBytes == 0 {
                    for scalar in ch.unicodeScalars {
                        let scalarWidth = UTF8.width(scalar)
                        if usedBytes + scalarWidth > maxUTF8Bytes {
                            break
                        }
                        result.unicodeScalars.append(scalar)
                        usedBytes += scalarWidth
                    }
                }
                break
            }
        }
        return result
    }

    /// Reads the frontmost application's selected text via macOS Accessibility APIs, returning `""`
    /// when nothing is selected, Secure Event Input or `AXSecureTextField` is active, or
    /// Accessibility permission is unavailable.
    public static func readSelectedText(target: TargetApp? = nil) -> String {
        readSelectedTextResult(target: target).text
    }

    /// Reads the frontmost application's selected text and distinguishes why it may be empty
    /// (`ok`, `empty`, `secure`, `untrusted`) so shortcuts can surface actionable feedback.
    public static func readSelectedTextResult(target: TargetApp? = nil) -> SelectionResult {
        guard AXIsProcessTrusted() else {
            return SelectionResult(text: "", status: .untrusted)
        }
        guard !IsSecureEventInputEnabled() else {
            return SelectionResult(text: "", status: .secure)
        }
        guard let resolvedTarget = target ?? resolveFrontmostTarget(), resolvedTarget.pid > 0 else {
            return SelectionResult(text: "", status: .empty)
        }
        // Never self-probe hotkeyd's own process or system authentication UI agents.
        guard resolvedTarget.pid != getpid() else {
            return SelectionResult(text: "", status: .empty)
        }
        let bundleID = (resolvedTarget.bundleIdentifier ?? "").lowercased()
        let forbiddenBundleIDs: Set<String> = [
            "com.apple.securityagent",
            "com.apple.loginwindow",
            "com.apple.coreservices.uiagent",
            "com.apple.authorizationhost"
        ]
        if forbiddenBundleIDs.contains(bundleID) {
            return SelectionResult(text: "", status: .secure)
        }

        let appEl = AXUIElementCreateApplication(resolvedTarget.pid)
        AXUIElementSetMessagingTimeout(appEl, axMessagingTimeoutSeconds)
        _ = roleOf(appEl)
        _ = AXUIElementSetAttributeValue(
            appEl,
            "AXManualAccessibility" as CFString,
            kCFBooleanTrue
        )

        let coldPollSubstrings = [
            "chrome", "chromium", "code", "electron", "brave", "arc", "edgemac",
            "slack", "discord", "notion", "obsidian", "cursor", "windsurf",
            "vivaldi", "linear", "zen", "zed"
        ]
        let needsColdPoll = coldPollSubstrings.contains { bundleID.contains($0) }
        let maxAttempts = needsColdPoll ? 12 : 2
        let deadline = CFAbsoluteTimeGetCurrent() + totalReadBudgetSeconds

        for attempt in 0..<maxAttempts {
            if IsSecureEventInputEnabled() {
                return SelectionResult(text: "", status: .secure)
            }
            var sawWebArea = false
            let probe = probeSelectionOnce(appEl, sawWebArea: &sawWebArea)
            if probe.secure {
                return SelectionResult(text: "", status: .secure)
            }
            if let text = probe.text {
                let sanitized = sanitize(text)
                if !sanitized.isEmpty {
                    return SelectionResult(text: sanitized, status: .ok)
                }
            }
            if sawWebArea {
                break
            }
            if attempt + 1 < maxAttempts {
                let remaining = deadline - CFAbsoluteTimeGetCurrent()
                guard remaining > 0.01 else { break }
                Thread.sleep(forTimeInterval: min(0.025, remaining))
            }
        }
        return SelectionResult(text: "", status: .empty)
    }

    /// Resolves the live frontmost application via HIServices (`kAXFocusedApplicationAttribute`)
    /// and WindowServer (`CGWindowListCopyWindowInfo` layer 0) so headless `dispatchMain()` daemons
    /// never suffer from stale `NSWorkspace.frontmostApplication` caches.
    public static func resolveFrontmostTarget() -> TargetApp? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, axMessagingTimeoutSeconds)
        var focusedAppRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedApplicationAttribute as CFString,
            &focusedAppRef
        ) == .success,
           let focusedApp = asAXUIElement(focusedAppRef) {
            var pid: pid_t = 0
            if AXUIElementGetPid(focusedApp, &pid) == .success, pid > 0 {
                let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
                return TargetApp(pid: pid, bundleIdentifier: bundleID)
            }
        }

        if let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]],
           let topWindow = windowList.first(where: { ($0[kCGWindowLayer as String] as? Int) == 0 }),
           let pid = topWindow[kCGWindowOwnerPID as String] as? pid_t,
           pid > 0 {
            let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            return TargetApp(pid: pid, bundleIdentifier: bundleID)
        }

        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier > 0 {
            return TargetApp(
                pid: front.processIdentifier,
                bundleIdentifier: front.bundleIdentifier
            )
        }
        return nil
    }

    // MARK: - AX Tree Probing

    private static func asAXUIElement(_ ref: CFTypeRef?) -> AXUIElement? {
        guard let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return Unmanaged<AXUIElement>.fromOpaque(Unmanaged.passUnretained(ref).toOpaque()).takeUnretainedValue()
    }

    private static func asAXValue(_ ref: CFTypeRef?) -> AXValue? {
        guard let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        return Unmanaged<AXValue>.fromOpaque(Unmanaged.passUnretained(ref).toOpaque()).takeUnretainedValue()
    }

    private static func strAttr(_ el: AXUIElement, _ attr: String) -> String? {
        var val: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &val) == .success,
              let s = val as? String else {
            return nil
        }
        return s
    }

    private static func roleOf(_ el: AXUIElement) -> String {
        strAttr(el, kAXRoleAttribute as String) ?? ""
    }

    private static func parentAttr(_ el: AXUIElement) -> AXUIElement? {
        var val: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &val) == .success else {
            return nil
        }
        return asAXUIElement(val)
    }

    private static func childrenAttr(_ el: AXUIElement, maxCount: CFIndex = 64) -> [AXUIElement] {
        var valuesRef: CFArray?
        guard AXUIElementCopyAttributeValues(
            el,
            kAXChildrenAttribute as CFString,
            0,
            maxCount,
            &valuesRef
        ) == .success,
              let rawArray = valuesRef as? [AnyObject] else {
            return []
        }
        return rawArray.compactMap { asAXUIElement($0) }
    }

    private static func isSecureElement(_ start: AXUIElement) -> Bool {
        var cur: AXUIElement? = start
        for _ in 0..<12 {
            guard let el = cur else { break }
            let role = roleOf(el)
            let subrole = strAttr(el, kAXSubroleAttribute as String) ?? ""
            if role == "AXSecureTextField" || subrole == "AXSecureTextField" {
                return true
            }
            cur = parentAttr(el)
        }
        return false
    }

    private static func readElementSelection(_ el: AXUIElement) -> String? {
        if let selected = strAttr(el, kAXSelectedTextAttribute as String) {
            let cleaned = selected.contains("\0")
                ? selected.replacingOccurrences(of: "\0", with: "")
                : selected
            if !cleaned.isEmpty {
                return cleaned
            }
        }

        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, "AXSelectedTextMarkerRange" as CFString, &rangeRef) == .success,
           let range = rangeRef {
            var strRef: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                el,
                "AXStringForTextMarkerRange" as CFString,
                range,
                &strRef
            ) == .success,
               let selected = strRef as? String {
                let cleaned = selected.contains("\0")
                    ? selected.replacingOccurrences(of: "\0", with: "")
                    : selected
                if !cleaned.isEmpty {
                    return cleaned
                }
            }
        }
        return nil
    }

    private static func activeWindow(_ appEl: AXUIElement) -> AXUIElement? {
        var winRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
           let win = asAXUIElement(winRef) {
            return win
        }
        if AXUIElementCopyAttributeValue(appEl, kAXMainWindowAttribute as CFString, &winRef) == .success,
           let win = asAXUIElement(winRef) {
            return win
        }
        return nil
    }

    private static func windowFrame(_ win: AXUIElement) -> (CGPoint, CGSize)? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posVal = asAXValue(posRef),
              let sizeVal = asAXValue(sizeRef) else {
            return nil
        }
        var pt = CGPoint.zero
        var sz = CGSize.zero
        guard AXValueGetValue(posVal, .cgPoint, &pt),
              AXValueGetValue(sizeVal, .cgSize, &sz),
              sz.width > 40,
              sz.height > 40 else {
            return nil
        }
        return (pt, sz)
    }

    private static func probeSelectionOnce(
        _ appEl: AXUIElement,
        sawWebArea: inout Bool
    ) -> (text: String?, secure: Bool) {
        var focRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &focRef) == .success,
           let foc = asAXUIElement(focRef) {
            if isSecureElement(foc) {
                return (nil, true)
            }
            var cur: AXUIElement? = foc
            for _ in 0..<6 {
                guard let el = cur else { break }
                if roleOf(el) == "AXWebArea" {
                    sawWebArea = true
                }
                if let sel = readElementSelection(el) {
                    return (sel, false)
                }
                cur = parentAttr(el)
            }
        }

        if let win = activeWindow(appEl), let (pos, sz) = windowFrame(win) {
            var probePoints: [(Float, Float)] = []
            if let mouse = CGEvent(source: nil)?.location,
               mouse.x >= pos.x + 4, mouse.x <= pos.x + sz.width - 4,
               mouse.y >= pos.y + 4, mouse.y <= pos.y + sz.height - 4 {
                probePoints.append((Float(mouse.x), Float(mouse.y)))
            }
            let defaultY = Float(pos.y + sz.height * 0.55)
            for xf: CGFloat in [0.50, 0.30, 0.70] {
                probePoints.append((Float(pos.x + sz.width * xf), defaultY))
            }
            for (x, y) in probePoints {
                var hitRef: AXUIElement?
                if AXUIElementCopyElementAtPosition(appEl, x, y, &hitRef) == .success,
                   let hit = hitRef {
                    AXUIElementSetMessagingTimeout(hit, axMessagingTimeoutSeconds)
                    let r = roleOf(hit) // Sonoma/Sequoia+ wake on RenderWidgetHostViewCocoa
                    if isSecureElement(hit) {
                        return (nil, true)
                    }
                    if r == "AXScrollArea" {
                        for child in childrenAttr(hit) where roleOf(child) == "AXWebArea" {
                            sawWebArea = true
                            if let sel = readElementSelection(child) {
                                return (sel, false)
                            }
                        }
                    }
                    var cur: AXUIElement? = hit
                    for _ in 0..<12 {
                        guard let el = cur else { break }
                        let cr = roleOf(el)
                        if cr == "AXWebArea" {
                            sawWebArea = true
                        }
                        if let sel = readElementSelection(el) {
                            return (sel, false)
                        }
                        if cr == "AXWebArea" {
                            break
                        }
                        cur = parentAttr(el)
                    }
                }
            }
        }

        return (nil, false)
    }
}
