import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private let watcher = ClickWatcher()
    private let hotkeys = ScaleHotkeys()
    private let panel = DefinitionPanel()

    // Context for the current popup, so chips can be re-looked-up without re-reading the screen.
    private var currentLine = ""
    private var currentSnapshot = TerminalSnapshot(appName: "", claudeSession: false, history: "")
    private var requestID = 0

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildStatusItem()

        panel.onTokenSelected = { [weak self] token in
            self?.define(token: token, line: self?.currentLine ?? token, at: nil)
        }

        watcher.onGesture = { [weak self] in
            self?.handleGesture()
        }

        hotkeys.isActive = { [weak self] in self?.panel.isVisible ?? false }
        hotkeys.onZoomIn = { [weak self] in self?.panel.adjustScale(by: Settings.scaleStep) }
        hotkeys.onZoomOut = { [weak self] in self?.panel.adjustScale(by: -Settings.scaleStep) }

        _ = ApiKey.current()

        if requestAccessibility() {
            startWatching()
        } else {
            // The permission dialog is modal to the user, not to us — poll until granted.
            waitForAccessibility()
        }

        // Offer the paste dialog once when there's nothing to authenticate with.
        if Settings.useClaude, ApiKey.current() == nil, !Settings.didPromptForKey {
            Settings.didPromptForKey = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.showKeyPrompt()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        watcher.stop()
        hotkeys.stop()
    }

    // MARK: - Permissions

    @discardableResult
    private func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private func waitForAccessibility() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            if AXIsProcessTrusted() {
                self.startWatching()
                self.refreshMenu()
            } else {
                self.waitForAccessibility()
            }
        }
    }

    private func startWatching() {
        if !watcher.start() {
            Log.event("failed to start the click monitor — check Accessibility permission")
        }
        if !hotkeys.start() {
            Log.event("failed to start the ⌘+/⌘− tap")
        }
        refreshMenu()
    }

    // MARK: - Status item

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "text.book.closed", accessibilityDescription: "TermDefine")
            button.image?.isTemplate = true
        }
        statusItem.menu = NSMenu()
        refreshMenu()
    }

    /// Repopulate on open so the trackpad diagnostic reflects the current state.
    /// The menu object is reused — replacing `statusItem.menu` mid-open would break it.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        populate(menu)
    }

    private func refreshMenu() {
        let menu = statusItem.menu ?? NSMenu()
        menu.removeAllItems()
        populate(menu)
        menu.delegate = self
        statusItem.menu = menu
    }

    private func populate(_ menu: NSMenu) {

        let status = NSMenuItem(
            title: AXIsProcessTrusted()
                ? "⌘-click a word in your terminal"
                : "Waiting for Accessibility permission…",
            action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        if !watcher.isRunning {
            let warning = NSMenuItem(
                title: "Not listening — grant Accessibility, then reopen this menu",
                action: nil, keyEquivalent: "")
            warning.isEnabled = false
            menu.addItem(warning)
        }

        menu.addItem(.separator())

        menu.addItem(toggle("Enabled", selector: #selector(toggleEnabled), on: Settings.enabled))
        menu.addItem(toggle("Terminal apps only", selector: #selector(toggleTerminalOnly), on: Settings.terminalOnly))
        menu.addItem(toggle("Use ⌘C when needed", selector: #selector(toggleCopyFallback), on: Settings.allowCopyFallback))

        menu.addItem(.separator())
        menu.addItem(toggle("Explain with Claude", selector: #selector(toggleClaude), on: Settings.useClaude))

        let keyItem = NSMenuItem(title: "API key: \(ApiKey.source)", action: nil, keyEquivalent: "")
        keyItem.isEnabled = false
        menu.addItem(keyItem)
        menu.addItem(NSMenuItem(
            title: ApiKey.hasStoredKey ? "Replace API key…" : "Set API key…",
            action: #selector(promptForKey), keyEquivalent: ""))
        if ApiKey.hasStoredKey {
            menu.addItem(NSMenuItem(title: "Remove pasted key", action: #selector(removeKey), keyEquivalent: ""))
        }
        menu.addItem(NSMenuItem(title: "Reload API key", action: #selector(reloadKey), keyEquivalent: ""))

        if !AXIsProcessTrusted() {
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: "Open Accessibility Settings…", action: #selector(openAccessibility), keyEquivalent: ""))
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit TermDefine", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        for item in menu.items where item.action != nil && item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
    }

    private func toggle(_ title: String, selector: Selector, on: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.state = on ? .on : .off
        return item
    }

    @objc private func toggleEnabled() {
        Settings.enabled.toggle()
        refreshMenu()
    }

    @objc private func toggleTerminalOnly() {
        Settings.terminalOnly.toggle()
        refreshMenu()
    }

    @objc private func toggleCopyFallback() {
        Settings.allowCopyFallback.toggle()
        refreshMenu()
    }

    @objc private func toggleClaude() {
        Settings.useClaude.toggle()
        refreshMenu()
    }

    @objc private func reloadKey() {
        _ = ApiKey.reload()
        refreshMenu()
    }

    @objc private func removeKey() {
        ApiKey.clearStored()
        refreshMenu()
    }

    @objc private func promptForKey() {
        showKeyPrompt()
    }

    /// Paste-a-key dialog, for when there's no `ANTHROPIC_API_KEY` in the environment or shell files.
    private func showKeyPrompt() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Anthropic API key"
        alert.informativeText = ApiKey.current() == nil
            ? "No ANTHROPIC_API_KEY was found in your environment or shell files. "
                + "Paste a key to enable the “In this terminal” explanations. "
                + "It's stored in your Keychain, not in a preferences file."
            : "Currently using: \(ApiKey.source). Paste a key to replace it — "
                + "a pasted key takes precedence over your shell files."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "sk-ant-…"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let value = field.stringValue.trimmed
        guard !value.isEmpty else { return }

        let saved = ApiKey.save(value)
        refreshMenu()

        if !saved {
            let failure = NSAlert()
            failure.messageText = "Could not save the key"
            failure.informativeText = "Writing to the Keychain failed. Try again, or export ANTHROPIC_API_KEY in ~/.zshrc instead."
            failure.runModal()
        }
    }

    @objc private func openAccessibility() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - The main flow

    /// True when the app under the cursor is one we should react to.
    static func frontmostIsEligible() -> Bool {
        guard Settings.terminalOnly else { return true }
        let app = NSWorkspace.shared.frontmostApplication
        return Settings.isTerminal(bundleID: app?.bundleIdentifier, name: app?.localizedName)
    }

    private func handleGesture() {
        guard Settings.enabled, AppDelegate.frontmostIsEligible() else {
            Log.event("⌘-click ignored (disabled, or frontmost app is not a terminal)")
            return
        }
        Log.event("⌘-click in \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")

        let point = NSEvent.mouseLocation

        // Preferred path: ask the terminal what character is under the pointer. Touches
        // nothing, and works inside TUIs like Claude Code where mouse reporting means a
        // synthetic click would be forwarded to the program instead of selecting text.
        if let hit = WordAtPoint.read(at: AppDelegate.flipped(point)) {
            Log.event("accessibility path: word=\(hit.word)")
            present(word: hit.word, line: hit.line, at: point)
            return
        }
        Log.event("accessibility path found nothing — falling back to synthetic click")

        // Fallback for terminals that don't answer parameterized text queries: select the
        // word with a synthetic click and read the selection back.
        SelectionReader.selectWord(at: AppDelegate.flipped(point))

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            SelectionReader.read { text in
                guard let self, let text, !text.trimmed.isEmpty else {
                    Log.event("fallback also found no text — nothing to show")
                    return
                }
                Log.event("fallback path: selection=\(text.prefix(40))")
                let tokens = Tokenizer.tokens(in: text)
                let primary = Tokenizer.primary(from: tokens) ?? text.trimmed
                self.present(word: primary, line: text, at: point, tokens: tokens)
            }
        }
    }

    private func present(word: String, line: String, at point: NSPoint, tokens: [String]? = nil) {
        // Terminals hide the pointer the moment a key goes down — including the ⌥ being held
        // right now — so bring it back as soon as we have something to show.
        SelectionReader.restoreCursor()

        currentSnapshot = TerminalContext.capture()
        currentLine = line

        define(token: word, line: line, at: point, tokens: tokens ?? Tokenizer.tokens(in: line))
    }

    /// AppKit screen coordinates (bottom-left origin) → Quartz event coordinates (top-left).
    private static func flipped(_ point: NSPoint) -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    /// The panel shows one thing: Claude's reading of the word on this screen. The offline
    /// chain is kept only for when there is no answer to show — no key, the toggle off, or a
    /// failed request — so a ⌘-click is never met with an empty popup.
    private func define(token: String, line: String, at point: NSPoint?, tokens: [String]? = nil) {
        requestID += 1
        let id = requestID
        let chips = tokens ?? Tokenizer.tokens(in: line)

        guard Settings.useClaude, ApiKey.current() != nil else {
            Log.event("no Claude for \(token) (useClaude=\(Settings.useClaude), key=\(ApiKey.current() != nil))")
            defineOffline(token: token, chips: chips, at: point, note: nil)
            return
        }

        panel.showLoading(term: token, message: "Asking Claude…", tokens: chips, at: point)

        // Only the glossary feeds the prompt: it is a table lookup, whereas the rest of the
        // offline chain would put a process launch in front of every request.
        ClaudeClient.explain(
            token: token,
            line: line,
            hint: Lookup.hint(for: token),
            snapshot: currentSnapshot
        ) { [weak self] result in
            guard let self, id == self.requestID else { return }
            switch result {
            case .success(let answer):
                Log.event("claude explained \(token) (\(answer.text.count) chars, \(answer.charactersBack) back)")
                self.panel.show(
                    term: token,
                    badge: "claude",
                    source: AppDelegate.sourceLabel(for: answer),
                    body: answer.text, tokens: chips, at: nil)
            case .failure(let error):
                Log.event("claude failed: \(error.localizedDescription) — falling back offline")
                self.defineOffline(token: token, chips: chips, at: nil, note: error.localizedDescription)
            }
        }
    }

    /// An answer read off older scrollback looks identical to one read off the current screen,
    /// and the difference is the whole point of the app — so the header names the distance.
    private static func sourceLabel(for answer: ClaudeClient.Answer) -> String {
        guard answer.usedScreen else { return "no screen context" }
        guard answer.charactersBack > 0 else { return ClaudeClient.model }
        return "\(answer.charactersBack / 1000)k chars earlier"
    }

    private func defineOffline(token: String, chips: [String], at point: NSPoint?, note: String?) {
        let id = requestID
        panel.showLoading(term: token, message: "Looking up…", tokens: chips, at: point)

        Lookup.define(token) { [weak self] definition in
            guard let self, id == self.requestID else { return }
            Log.event("defined \(token) offline via \(definition.source)")
            self.panel.show(
                term: definition.term,
                badge: definition.kind,
                source: definition.source,
                body: note.map { "\(definition.text)\n\n\($0)" } ?? definition.text,
                tokens: chips,
                at: nil)
        }
    }
}
