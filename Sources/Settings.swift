import AppKit
import Foundation

/// Small wrapper over UserDefaults so the menu items and the click watcher agree.
enum Settings {
    private static let d = UserDefaults.standard

    static var enabled: Bool {
        get { d.object(forKey: "enabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "enabled") }
    }

    /// When true, triple-clicks are only handled while a terminal emulator is frontmost.
    static var terminalOnly: Bool {
        get { d.object(forKey: "terminalOnly") as? Bool ?? true }
        set { d.set(newValue, forKey: "terminalOnly") }
    }

    /// Allow the ⌘C fallback when the Accessibility text API returns nothing.
    static var allowCopyFallback: Bool {
        get { d.object(forKey: "allowCopyFallback") as? Bool ?? true }
        set { d.set(newValue, forKey: "allowCopyFallback") }
    }

    /// Panel zoom, driven by ⌘+ / ⌘− and remembered between popups and launches.
    static var panelScale: CGFloat {
        get {
            let stored = d.object(forKey: "panelScale") as? Double ?? 1.0
            return CGFloat(min(max(stored, scaleRange.lowerBound), scaleRange.upperBound))
        }
        set {
            let clamped = min(max(Double(newValue), scaleRange.lowerBound), scaleRange.upperBound)
            d.set(clamped, forKey: "panelScale")
        }
    }

    static let scaleRange = 0.7...2.5
    static let scaleStep: CGFloat = 0.1

    /// Set once we've offered the paste-a-key dialog, so it isn't shown on every launch.
    static var didPromptForKey: Bool {
        get { d.bool(forKey: "didPromptForKey") }
        set { d.set(newValue, forKey: "didPromptForKey") }
    }

    /// Set once the shortcuts card in the menu-bar popover has been closed. The popover's
    /// sparkles icon flips it back.
    static var didDismissShortcuts: Bool {
        get { d.bool(forKey: "didDismissShortcuts") }
        set { d.set(newValue, forKey: "didDismissShortcuts") }
    }

    /// Show the menu-bar item as an input-shaped field rather than a bare icon.
    static var inlineInput: Bool {
        get { d.object(forKey: "inlineInput") as? Bool ?? true }
        set { d.set(newValue, forKey: "inlineInput") }
    }

    /// Send the word plus the visible terminal screen to the Anthropic API for a contextual answer.
    static var useClaude: Bool {
        get { d.object(forKey: "useClaude") as? Bool ?? true }
        set { d.set(newValue, forKey: "useClaude") }
    }

    static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp-Preview",
        "net.kovidgoyal.kitty",
        "io.alacritty",
        "org.alacritty",
        "com.github.wez.wezterm",
        "com.mitchellh.ghostty",
        "co.zeit.hyper",
        "com.raphaelamorim.rio",
        "com.tabby.app",
        "org.tabby",
    ]

    static func isTerminal(bundleID: String?, name: String?) -> Bool {
        if let id = bundleID, terminalBundleIDs.contains(id) { return true }
        if let n = name?.lowercased(), n.contains("term") || n.contains("shell") { return true }
        return false
    }
}
