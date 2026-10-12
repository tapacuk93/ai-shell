import AppKit
import ApplicationServices

/// A snapshot of the terminal when the user ⌘-clicks: a couple of thousand characters of text,
/// taken from somewhere in whatever the Accessibility API hands over. `offset` slides that
/// window back through the scrollback; `length` grows it in place.
struct TerminalSnapshot {
    let appName: String
    /// True when the visible screen looks like an interactive Claude Code session.
    let claudeSession: Bool
    /// The visible screen plus whatever scrollback came with it, oldest first.
    let history: String
    /// Characters between the end of the history and the end of the window being sent.
    let offset: Int
    /// How much text this window holds. A declined request is retried with it doubled.
    let length: Int
    /// The window itself — resolved once, since reading it walks the string.
    let screen: String

    /// How much text the first request carries, and how far it can grow: a declined request is
    /// retried with the window doubled in place — 2.5k, 5k, 10k, 20k characters — before the
    /// ladder starts stepping back through the scrollback.
    static let windowLength = 2500
    static let maxWindowLength = 20_000

    /// How the step-back ladder climbs once the window has stopped growing. The first rung
    /// jumps `firstStep` windows back and every one after that doubles — 0, 3, 6, 12, 24, 48,
    /// 96, 192 windows. The windows either side of the current one are skipped: they are
    /// usually a continuation of the same work, carrying the text that got the request
    /// declined in the first place.
    static let firstStep = 3
    static let maxRungs = 8

    /// The furthest rung this window can reach, in characters.
    var deepestOffset: Int { (length * TerminalSnapshot.firstStep) << (TerminalSnapshot.maxRungs - 2) }

    init(
        appName: String,
        claudeSession: Bool,
        history: String,
        offset: Int = 0,
        length: Int = TerminalSnapshot.windowLength
    ) {
        self.appName = appName
        self.claudeSession = claudeSession
        self.history = history
        self.offset = offset
        self.length = length
        self.screen = TerminalSnapshot.window(of: history, endingBack: offset, length: length)
    }

    var isEmpty: Bool { screen.trimmed.isEmpty }

    /// How far back the window sits, in windows. 0 is the text on screen now.
    var windowsBack: Int { offset / length }

    /// The same spot, seen through twice as much text. A refusal is about the request as a
    /// whole, and a window that stops mid-exchange can leave the clicked word looking like
    /// the security-shaped text around it — so the first answer to a decline is more context,
    /// not older context. Nil once the window has grown as far as it goes, or once it already
    /// covers everything behind it.
    func enlarged() -> TerminalSnapshot? {
        guard length < TerminalSnapshot.maxWindowLength else { return nil }
        let next = min(length * 2, TerminalSnapshot.maxWindowLength)
        guard offset + length < history.count else { return nil }

        return TerminalSnapshot(
            appName: appName, claudeSession: claudeSession, history: history,
            offset: offset, length: next)
    }

    /// The next rung: twice as far back as this one. A declined request is retried against
    /// this rather than against nothing — the word was clicked in a context, and the context
    /// that explains it is usually above whatever tripped the classifier. Nil once the
    /// scrollback runs out, or once the ladder has climbed as far as it goes.
    func steppedBack() -> TerminalSnapshot? {
        let next = offset == 0 ? length * TerminalSnapshot.firstStep : offset * 2
        guard next < history.count, next <= deepestOffset else { return nil }

        let stepped = TerminalSnapshot(
            appName: appName, claudeSession: claudeSession, history: history,
            offset: next, length: length)
        return stepped.isEmpty ? nil : stepped
    }

    /// One window of `history`, `length` characters long, ending `back` characters before its
    /// end.
    static func window(of history: String, endingBack back: Int, length: Int) -> String {
        guard back < history.count else { return "" }
        let end = history.index(history.endIndex, offsetBy: -back)
        let start = history.index(end, offsetBy: -length, limitedBy: history.startIndex)
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
