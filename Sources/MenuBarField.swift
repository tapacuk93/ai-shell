import AppKit

/// A real text field living in the menu bar.
///
/// A status item's own window can't become key — on current macOS it is drawn by another
/// process — so a field placed in it shows a caret but never receives typing. Instead the status
/// item only reserves the space, and this borderless panel sits exactly over it, one level
/// above the menu bar. The panel is non-activating: typing goes to it while the app you were
/// using stays frontmost, which is what commands like "close all windows but this" are about.
final class MenuBarField: NSObject, NSWindowDelegate {

    static let width: CGFloat = 230

    let field = NSTextField()
    /// A click on the field, or `focus()`. Fired on every click, not only when the panel
    /// becomes key: after Esc hands the keyboard back, the panel can still be this app's key
    /// window, and a click on it then changes nothing AppKit would report.
    var onFocus: (() -> Void)?
    /// Esc in the field.
    var onCancel: (() -> Void)?

    private let statusItem: NSStatusItem
    private let panel: KeyPanel
    private let pill = NSView()
    private var timer: Timer?

    init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: MenuBarField.width, height: 24),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()

        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.onCancel?() }
        panel.onMouseDown = { [weak self] in self?.onFocus?() }

        let content = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        panel.contentView = content

        // A quiet rounded fill rather than a bezel, so it reads as part of the menu bar.
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 6
        content.addSubview(pill)

        let icon = NSImageView(image: NSImage(systemSymbolName: "sparkles", accessibilityDescription: "AI Shell")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium)) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        icon.frame = NSRect(x: 7, y: 0, width: 14, height: 22)
        icon.autoresizingMask = [.minYMargin, .maxYMargin]
        pill.addSubview(icon)

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.placeholderString = "e.g. close all windows"
        field.cell?.sendsActionOnEndEditing = false
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        pill.addSubview(field)

        statusItem.length = MenuBarField.width
        statusItem.button?.image = nil
        statusItem.button?.title = ""

        layout()
        updateColors()
        panel.orderFrontRegardless()
        track()
    }

    func remove() {
        timer?.invalidate()
        panel.orderOut(nil)
    }

    /// Takes keyboard focus without activating the app.
    func focus() {
        sync()
        panel.allowsKey = true
        panel.makeKey()
        panel.makeFirstResponder(field)
        onFocus?()
    }

    /// Gives up keyboard focus. Ordering the panel out and back is the public way to stop
    /// being key without making some other window of this app key instead.
    func blur() {
        panel.allowsKey = false
        panel.orderOut(nil)
        panel.orderFrontRegardless()
        updateColors()
    }

    /// Where popovers hang from.
    var anchorView: NSView { pill }

    var hasFocus: Bool { panel.isKeyWindow }

    // MARK: - Placement

    private func layout() {
        let height: CGFloat = 22
        let frame = panel.contentView?.bounds ?? .zero
        pill.frame = NSRect(x: 2, y: (frame.height - height) / 2, width: frame.width - 4, height: height)
        field.frame = NSRect(x: 24, y: 3, width: pill.frame.width - 30, height: 17)
    }

    /// The status item can move whenever another item appears or goes, and the menu bar hides
    /// in full-screen apps; the panel follows. Polling is the only signal available, since the
    /// item's window isn't ours to observe.
    private func track() {
        sync()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.sync() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func screensChanged() { sync() }

    private func sync() {
        guard let button = statusItem.button, let window = button.window else { return }
        let target = window.convertToScreen(button.convert(button.bounds, to: nil))
        // Occlusion says nothing here — the item's window is drawn by another process — so
        // only the item's own visibility and size count.
        let visible = statusItem.isVisible && window.isVisible && target.width > 0
        if visible != panel.isVisible {
            visible ? panel.orderFrontRegardless() : panel.orderOut(nil)
        }
        if panel.frame != target {
            panel.setFrame(target, display: true)
            layout()
        }
        if panel.appearance?.name != button.effectiveAppearance.name {
            panel.appearance = button.effectiveAppearance
            updateColors()
        }
    }

    private func updateColors() {
        panel.contentView?.effectiveAppearance.performAsCurrentDrawingAppearance {
            pill.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(hasFocus ? 0.14 : 0.08).cgColor
        }
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        updateColors()
    }

    func windowDidResignKey(_ notification: Notification) {
        panel.allowsKey = false
        updateColors()
    }
}

/// A borderless panel that takes keyboard focus, but only when asked: from a click on it, or
/// from `focus()`. Left to itself AppKit makes it key the moment it is first shown — before it
/// has even moved into the menu bar — which would open the popover at launch.
private final class KeyPanel: NSPanel {
    var onCancel: (() -> Void)?
    var onMouseDown: (() -> Void)?
    var allowsKey = false

    override var canBecomeKey: Bool { allowsKey }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, !allowsKey {
            allowsKey = true
            makeKey()
        }
        super.sendEvent(event)
        if event.type == .leftMouseDown { onMouseDown?() }
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
