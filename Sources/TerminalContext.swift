import AppKit
import ApplicationServices

/// A snapshot of the terminal when the user ⌘-clicks: the visible screen, plus each earlier
/// screenful of whatever scrollback the Accessibility API hands over.
struct TerminalSnapshot {
    let appName: String
    /// True when the visible screen looks like an interactive Claude Code session.
    let claudeSession: Bool
    /// Newest first — `screens[0]` is what is on screen now.
    let screens: [String]
    /// Which of them is being sent. 0 is the visible screen.
    let screensBack: Int

    var screen: String { screensBack < screens.count ? screens[screensBack] : "" }
    var isEmpty: Bool { screen.trimmed.isEmpty }

    /// One screenful further back, or nil once the scrollback runs out. A declined request is
    /// retried against this rather than against nothing: the word was clicked in a context,
    /// and the context that explains it is usually just above whatever tripped the classifier.
    func steppedBack() -> TerminalSnapshot? {
        let next = screensBack + 1
        guard next < screens.count else { return nil }
        return TerminalSnapshot(appName: appName, claudeSession: claudeSession, screens: screens, screensBack: next)
    }
}

enum TerminalContext {

    /// Pulls the visible text of the frontmost terminal window via the Accessibility API,
    /// sliced into screenfuls from the end so a declined request can step back through them.
    static func capture(screenLength: Int = 6000, maxScreens: Int = 5) -> TerminalSnapshot {
        let app = NSWorkspace.shared.frontmostApplication
        let name = app?.localizedName ?? "Terminal"
        let text = focusedText() ?? ""

        var screens: [String] = []
        var remaining = Substring(text)
        while !remaining.isEmpty, screens.count < maxScreens {
            var chunk = remaining.suffix(screenLength)
            remaining = remaining.dropLast(chunk.count)
            // A window that opens mid-line reads as garbage, so start it at the next one.
            if !remaining.isEmpty, let newline = chunk.firstIndex(of: "\n") {
                chunk = chunk[chunk.index(after: newline)...]
            }
            let window = String(chunk)
            guard !window.trimmed.isEmpty else { continue }
            screens.append(window)
        }

        return TerminalSnapshot(
            appName: name,
            claudeSession: looksLikeClaudeCode(screens.first ?? ""),
            screens: screens,
            screensBack: 0)
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
