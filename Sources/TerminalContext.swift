import AppKit
import ApplicationServices

/// A snapshot of the terminal when the user ⌘-clicks: two and a half thousand characters of
/// text, taken from somewhere in whatever the Accessibility API hands over. `offset` slides
/// that window back through the scrollback without changing its size.
struct TerminalSnapshot {
    let appName: String
    /// True when the visible screen looks like an interactive Claude Code session.
    let claudeSession: Bool
    /// The visible screen plus whatever scrollback came with it, oldest first.
    let history: String
    /// Characters between the end of the history and the end of the window being sent.
    let offset: Int
    /// The window itself — resolved once, since reading it walks the string.
    let screen: String

    /// How much text goes in one request, and how far the ladder can climb. The first retry
    /// jumps `firstStep` windows back and every one after that doubles — 0, 3, 6, 12, 24, 48,
    /// 96, 192 windows — so eight rungs reach four hundred and eighty thousand characters back.
    /// The windows either side of the current one are skipped: they are usually a continuation
    /// of the same work, carrying the same text that got the request declined.
    static let windowLength = 2500
    static let firstStep = 3
    static let maxRungs = 8

    /// The furthest rung, in characters.
    static var deepestOffset: Int { (windowLength * firstStep) << (maxRungs - 2) }

    init(appName: String, claudeSession: Bool, history: String, offset: Int = 0) {
        self.appName = appName
        self.claudeSession = claudeSession
        self.history = history
        self.offset = offset
        self.screen = TerminalSnapshot.window(of: history, endingBack: offset)
    }

    var isEmpty: Bool { screen.trimmed.isEmpty }

    /// How far back the window sits, in windows. 0 is the text on screen now.
    var windowsBack: Int { offset / TerminalSnapshot.windowLength }

    /// The next rung: twice as far back as this one. A declined request is retried against
    /// this rather than against nothing — the word was clicked in a context, and the context
    /// that explains it is usually above whatever tripped the classifier. Nil once the
    /// scrollback runs out, or once the ladder has climbed as far as it goes.
    func steppedBack() -> TerminalSnapshot? {
        let next = offset == 0
            ? TerminalSnapshot.windowLength * TerminalSnapshot.firstStep
            : offset * 2
        guard next < history.count, next <= TerminalSnapshot.deepestOffset else { return nil }

        let stepped = TerminalSnapshot(
            appName: appName, claudeSession: claudeSession, history: history, offset: next)
        return stepped.isEmpty ? nil : stepped
    }

    /// One window of `history`, ending `back` characters before its end.
    static func window(of history: String, endingBack back: Int) -> String {
        guard back < history.count else { return "" }
        let end = history.index(history.endIndex, offsetBy: -back)
        let start = history.index(end, offsetBy: -windowLength, limitedBy: history.startIndex)
            ?? history.startIndex

        var window = history[start..<end]
        // Half a line at either edge reads as garbage, so trim to whole ones — except at the
        // ends of the history, where nothing was cut in the first place.
        if start != history.startIndex, let newline = window.firstIndex(of: "\n") {
            window = window[window.index(after: newline)...]
        }
        if end != history.endIndex, let newline = window.lastIndex(of: "\n") {
            window = window[..<newline]
        }
        return String(window)
    }
}

enum TerminalContext {

    /// Pulls the text of the frontmost terminal window via the Accessibility API: the visible
    /// screen, and whatever scrollback comes with it for the retry ladder to climb into.
    static func capture(maxHistory: Int = 220_000) -> TerminalSnapshot {
        let app = NSWorkspace.shared.frontmostApplication
        let name = app?.localizedName ?? "Terminal"
        let text = focusedText() ?? ""
        let history = text.count > maxHistory ? String(text.suffix(maxHistory)) : text

        return TerminalSnapshot(
            appName: name,
            claudeSession: looksLikeClaudeCode(String(history.suffix(6000))),
            history: history)
    }

    // MARK: - Accessibility traversal

    private static func focusedText() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID()
        else { return nil }

        let axElement = element as! AXUIElement
        if let value = stringValue(of: axElement), !value.trimmed.isEmpty { return value }

        // The focused element wasn't the text area — walk the window looking for one.
        var window: CFTypeRef?
        if AXUIElementCopyAttributeValue(axElement, kAXWindowAttribute as CFString, &window) == .success,
           let window, CFGetTypeID(window) == AXUIElementGetTypeID() {
            return searchForText(in: window as! AXUIElement, depth: 0)
        }
        return nil
    }

    private static func searchForText(in element: AXUIElement, depth: Int) -> String? {
        guard depth < 6 else { return nil }

        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        if let role = role as? String, role == kAXTextAreaRole || role == kAXStaticTextRole,
           let value = stringValue(of: element), value.count > 40 {
            return value
        }

        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let list = children as? [AXUIElement]
        else { return nil }

        for child in list.prefix(40) {
            if let found = searchForText(in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    private static func stringValue(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    // MARK: - Claude Code detection

    /// Heuristics for the Claude Code TUI: its box drawing, status line and hints.
    private static func looksLikeClaudeCode(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let markers = [
            "esc to interrupt",
            "? for shortcuts",
            "Claude Code",
            "⏵⏵ accept edits",
            "bypass permissions",
            "✻ Welcome to Claude",
            "/clear",
            "claude --",
        ]
        let lowered = text.lowercased()
        for marker in markers where lowered.contains(marker.lowercased()) { return true }
        // The prompt box plus a claude mention is a strong enough signal on its own.
        return (text.contains("╭─") || text.contains("│ >")) && lowered.contains("claude")
    }
}
