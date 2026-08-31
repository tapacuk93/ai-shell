import AppKit

/// Borderless floating panel that shows the definition next to the cursor.
/// Non-activating, so the terminal keeps focus and keystrokes keep going there.
///
/// Every metric below is expressed at scale 1.0 and multiplied by `Settings.panelScale`,
/// which ⌘+ / ⌘− adjust and which persists between launches.
final class DefinitionPanel: NSObject {

    private var panel: NSPanel?
    private var container: NSVisualEffectView!
    private var termLabel: NSTextField!
    private var badgeLabel: NSTextField!
    private var sourceLabel: NSTextField!
    private var bodyLabel: NSTextField!
    private var chipsView: NSView!

    private var monitors: [Any] = []

    private var tokens: [String] = []
    var onTokenSelected: ((String) -> Void)?

    private var scale: CGFloat { Settings.panelScale }
    private var width: CGFloat { 420 * scale }
    private var padding: CGFloat { 14 * scale }

    // MARK: - Public

    /// The waiting state, shown while the answer is on its way. A `nil` point leaves the
    /// panel where it is, which is what a chip tap wants.
    func showLoading(term: String, message: String, tokens: [String], at point: NSPoint?) {
        show(term: term, badge: "…", source: "", body: message, dimmed: true, tokens: tokens, at: point)
    }

    /// The panel has a single body: Claude's answer, or — when Claude can't answer — the
    /// offline definition standing in for it.
    func show(term: String, badge: String, source: String, body: String,
              dimmed: Bool = false, tokens: [String], at point: NSPoint?) {
        build()
        self.tokens = tokens
        termLabel.stringValue = term
        badgeLabel.stringValue = " \(badge.uppercased()) "
        sourceLabel.stringValue = source
        bodyLabel.stringValue = body
        bodyLabel.textColor = dimmed ? .secondaryLabelColor : .labelColor
        rebuildChips()
        layoutContents(keepingTopLeft: true)
        if let point { position(at: point) }
        present()
    }

    /// ⌘+ / ⌘− while the panel is showing.
    func adjustScale(by delta: CGFloat) {
        guard isVisible else { return }
        let previous = Settings.panelScale
        Settings.panelScale = previous + delta
        guard Settings.panelScale != previous else { return }  // already at a limit

        applyFonts()
        rebuildChips()
        layoutContents(keepingTopLeft: true)
    }

    func hide() {
        removeMonitors()
        panel?.orderOut(nil)
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    // MARK: - Construction

    private func build() {
        guard panel == nil else { return }

        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: 120))
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.separatorColor.cgColor
        container = effect

        termLabel = NSTextField(labelWithString: "")
        termLabel.lineBreakMode = .byTruncatingTail

        badgeLabel = NSTextField(labelWithString: "")
        badgeLabel.textColor = .secondaryLabelColor
        badgeLabel.wantsLayer = true
        badgeLabel.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.25).cgColor
        badgeLabel.alignment = .center

        sourceLabel = NSTextField(labelWithString: "")
        sourceLabel.textColor = .tertiaryLabelColor
        sourceLabel.alignment = .right

        bodyLabel = NSTextField(wrappingLabelWithString: "")
        bodyLabel.textColor = .labelColor
        bodyLabel.isSelectable = true

        chipsView = NSView()

        for view in [termLabel, badgeLabel, sourceLabel, bodyLabel, chipsView] as [NSView] {
            effect.addSubview(view)
        }

        let panel = NSPanel(
            contentRect: effect.bounds,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.contentView = effect
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .utilityWindow
        // Drag the panel by its background or header to move it out of the way. The body
        // label stays selectable, so a drag starting on it selects text instead.
        // Moving it is free — the panel has no dismissal timer to disturb.
        panel.isMovableByWindowBackground = true
        self.panel = panel

        applyFonts()
    }

    /// Re-derives every font and corner radius from the current scale.
    private func applyFonts() {
        termLabel.font = .monospacedSystemFont(ofSize: 15 * scale, weight: .semibold)
        badgeLabel.font = .systemFont(ofSize: 10 * scale, weight: .semibold)
        badgeLabel.layer?.cornerRadius = 4 * scale
        sourceLabel.font = .systemFont(ofSize: 10 * scale)
        bodyLabel.font = .systemFont(ofSize: 12.5 * scale)
        container.layer?.cornerRadius = 12 * scale
    }

    // MARK: - Content

    private func rebuildChips() {
        chipsView.subviews.forEach { $0.removeFromSuperview() }
        let others = tokens.filter { $0.lowercased() != termLabel.stringValue.lowercased() }
        guard !others.isEmpty else {
            chipsView.frame.size = .zero
            return
        }

        var x: CGFloat = 0
        var y: CGFloat = 0
        let maxWidth = width - padding * 2
        let rowHeight = 20 * scale

        for token in others.prefix(12) {
            let chip = ChipButton(title: token, scale: scale, target: self, action: #selector(chipTapped(_:)))
            chip.sizeToFit()
            var frame = chip.frame
            frame.size.width = min(frame.width + 14 * scale, maxWidth)
            frame.size.height = rowHeight - 2 * scale
            if x + frame.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight
            }
            frame.origin = NSPoint(x: x, y: y)
            chip.frame = frame
            chipsView.addSubview(chip)
            x += frame.width + 5 * scale
        }

        // Flip rows so the first chip ends up on the top row (AppKit origin is bottom-left).
        let totalHeight = y + rowHeight
        for chip in chipsView.subviews {
            chip.frame.origin.y = totalHeight - chip.frame.origin.y - rowHeight
        }
        chipsView.frame.size = NSSize(width: maxWidth, height: totalHeight)
    }

    @objc private func chipTapped(_ sender: NSButton) {
        onTokenSelected?(sender.title)
    }

    private func layoutContents(keepingTopLeft: Bool) {
        let contentWidth = width - padding * 2

        let badgeSize = badgeLabel.intrinsicContentSize
        let badgeWidth = badgeSize.width + 6 * scale
        let sourceWidth = min(sourceLabel.intrinsicContentSize.width + 2 * scale, 165 * scale)
        let termWidth = max(60 * scale, contentWidth - badgeWidth - sourceWidth - 12 * scale)

        bodyLabel.preferredMaxLayoutWidth = contentWidth
        let bodyHeight = bodyLabel.sizeThatFits(NSSize(width: contentWidth, height: .greatestFiniteMagnitude)).height

        let chipsHeight = chipsView.subviews.isEmpty ? 0 : chipsView.frame.height + 10 * scale
        let headerHeight = 20 * scale
        let totalHeight = padding + headerHeight + 8 * scale + bodyHeight + chipsHeight + padding

        var y = totalHeight - padding - headerHeight
        termLabel.frame = NSRect(x: padding, y: y, width: termWidth, height: headerHeight)
        badgeLabel.frame = NSRect(x: padding + termWidth + 6 * scale, y: y + 3 * scale, width: badgeWidth, height: 14 * scale)
        sourceLabel.frame = NSRect(x: width - padding - sourceWidth, y: y + 2 * scale, width: sourceWidth, height: 14 * scale)

        y -= 8 * scale + bodyHeight
        bodyLabel.frame = NSRect(x: padding, y: y, width: contentWidth, height: bodyHeight)

        if chipsHeight > 0 {
            chipsView.frame.origin = NSPoint(x: padding, y: padding)
        }

        guard let panel else { return }
        var frame = panel.frame
        let topLeft = NSPoint(x: frame.minX, y: frame.maxY)
        frame.size = NSSize(width: width, height: totalHeight)
        if keepingTopLeft, panel.isVisible {
            frame.origin = NSPoint(x: topLeft.x, y: topLeft.y - totalHeight)
        }
        panel.setFrame(constrained(frame, near: nil), display: true)
        container.frame = NSRect(origin: .zero, size: frame.size)
    }

    private func position(at point: NSPoint) {
        guard let panel else { return }
        let size = panel.frame.size
        let visible = visibleArea(near: point, frame: panel.frame)

        // Below-right of the pointer by default; flip to the other side when that would run
        // past an edge, so the panel never covers the word it is describing.
        var origin = NSPoint(x: point.x + 12, y: point.y - size.height - 12)
        if origin.x + size.width > visible.maxX - margin { origin.x = point.x - size.width - 12 }
        if origin.y < visible.minY + margin { origin.y = point.y + 18 }

        panel.setFrame(constrained(NSRect(origin: origin, size: size), near: point), display: true)
    }

    private let margin: CGFloat = 8

    /// The usable area of the screen the panel belongs to. `visibleFrame` already excludes
    /// the menu bar and the Dock, whichever edge the Dock happens to be on.
    private func visibleArea(near anchor: NSPoint?, frame: NSRect) -> NSRect {
        let screen: NSScreen?
        if let anchor, let containing = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) {
            screen = containing
        } else {
            // No anchor: whichever screen the panel currently overlaps most.
            screen = NSScreen.screens.max { a, b in
                a.frame.intersection(frame).area < b.frame.intersection(frame).area
            } ?? NSScreen.main
        }
        return screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    /// Pulls a frame back inside the visible area. Applied to every placement — the initial
    /// position, a ⌘+ resize, and the growth that happens when Claude's answer arrives — so
    /// the panel can never end up off an edge or under the Dock.
    private func constrained(_ frame: NSRect, near anchor: NSPoint?) -> NSRect {
        let visible = visibleArea(near: anchor, frame: frame)
        var result = frame

        let maxX = max(visible.maxX - result.width - margin, visible.minX + margin)
        result.origin.x = min(max(result.origin.x, visible.minX + margin), maxX)

        let maxY = max(visible.maxY - result.height - margin, visible.minY + margin)
        result.origin.y = min(max(result.origin.y, visible.minY + margin), maxY)

        // Taller than the screen (a long Claude answer at a large zoom): keep the top edge
        // on screen so the word and its definition stay readable.
        if result.height > visible.height - margin * 2 {
            result.origin.y = visible.maxY - result.height - margin
        }
        return result
    }

    private func present() {
        guard let panel else { return }
        panel.orderFrontRegardless()
        installMonitors()
    }

    // MARK: - Dismissal

    /// The panel stays up until it is dismissed deliberately: a click outside it, or Esc.
    /// It does not time out, and typing or scrolling in the terminal leaves it alone, so it
    /// can be read while you keep working.
    private func installMonitors() {
        guard monitors.isEmpty else { return }
        // Global monitors never see this app's own events, so anything here is a click
        // somewhere else — including on the terminal underneath.
        let outside = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            self?.hide()
        }
        let inside = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            guard let self else { return event }

            if event.type == .keyDown {
                if event.keyCode == 53 { self.hide(); return nil } // esc
                return event
            }

            // ⌘-click inside the panel looks up that word too, so you can follow a term from
            // the answer without going back to the terminal.
            guard event.window === self.panel,
                  event.modifierFlags.contains(.command),
                  let word = self.word(at: event.locationInWindow)
            else { return event }

            self.onTokenSelected?(word)
            return nil
        }
        monitors = [outside, inside].compactMap { $0 }
    }

    private func removeMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    // MARK: - Hit-testing the panel's own text

    /// Which word sits under `windowPoint` in one of the panel's labels, if any.
    private func word(at windowPoint: NSPoint) -> String? {
        for field in [bodyLabel, termLabel].compactMap({ $0 }) where !field.isHidden {
            let local = field.convert(windowPoint, from: nil)
            guard field.bounds.contains(local) else { continue }
            guard let index = characterIndex(in: field, at: local),
                  let hit = WordAtPoint.word(in: field.stringValue, at: index)
            else { continue }
            return hit.word
        }
        return nil
    }

    /// Lays the label's text out again through TextKit to find the character under a point.
    /// `NSTextField` has no public API for this, so the layout is reproduced to match.
    private func characterIndex(in field: NSTextField, at point: NSPoint) -> Int? {
        let storage = NSTextStorage(attributedString: field.attributedStringValue)
        let container = NSTextContainer(size: NSSize(width: field.bounds.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 2   // NSTextField's own inset
        container.maximumNumberOfLines = field.maximumNumberOfLines

        let manager = NSLayoutManager()
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)

        // Text lays out top-down; NSTextField is not a flipped view, so mirror the y axis.
        let flipped = field.isFlipped ? point : NSPoint(x: point.x, y: field.bounds.height - point.y)

        let index = manager.characterIndex(
            for: flipped, in: container, fractionOfDistanceBetweenInsertionPoints: nil)
        return index < storage.length ? index : nil
    }
}

private extension NSRect {
    /// Zero for the empty rect `intersection` returns when two frames don't overlap.
    var area: CGFloat { isEmpty ? 0 : width * height }
}

/// Small pill button used for the other words on the clicked line.
final class ChipButton: NSButton {
    init(title: String, scale: CGFloat, target: AnyObject?, action: Selector) {
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        wantsLayer = true
        font = .monospacedSystemFont(ofSize: 10.5 * scale, weight: .medium)
        contentTintColor = .secondaryLabelColor
        layer?.cornerRadius = 5 * scale
        layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.22).cgColor
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.22).cgColor
    }
}
