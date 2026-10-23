import AppKit

/// What the menu-bar icon opens: a field that takes a question or a command, a shortcuts card
/// shown until it is closed once, the plan made from the last line typed, and the commands
/// that have run before.
///
/// Return asks Claude; when the answer is a script, Return again (or Run) carries it out. A
/// line that has run before skips Claude and reuses its saved script.
final class ShellPopover: NSViewController, NSTextFieldDelegate {

    var onShowSettings: ((NSView) -> Void)?
    /// Asked to bring the popover up, for a shortcut run that needs to show an error.
    var onNeedsShowing: (() -> Void)?
    /// The terminal screen captured when the popover opened, before this app took focus.
    var snapshot: TerminalSnapshot?

    private let width: CGFloat = 380
    private let padding: CGFloat = 12

    private var stack: NSStackView!
    private var shortcutsCard: NSView!
    /// The field being typed into: the popover's own, or the one living in the menu bar.
    private var field: NSTextField!
    private var ownField: NSTextField!
    private var rowSpacer: NSView!
    private var resultLabel: NSTextField!
    private var scriptLabel: NSTextField!
    private var buttonRow: NSStackView!
    private var runButton: NSButton!
    private var settingsButton: NSButton!
    private var recentHeader: NSTextField!
    private var recentList: NSStackView!

    /// The history item whose shortcut button is waiting for a key combination.
    private var recording: UUID?
    private var recordMonitor: Any?

    private var plan: ShellPlan?
    /// The line the current plan was made from, so Return runs it only while it still matches.
    private var plannedInput = ""
    private var busy = false

    // MARK: - Lifecycle

    override func loadView() {
        stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: padding, left: padding, bottom: padding, right: padding)

        shortcutsCard = makeShortcutsCard()
        stack.addArrangedSubview(shortcutsCard)
        stack.addArrangedSubview(makeInputRow())

        resultLabel = NSTextField(wrappingLabelWithString: "")
        resultLabel.font = .systemFont(ofSize: 12.5)
        resultLabel.isSelectable = true
        stack.addArrangedSubview(resultLabel)

        scriptLabel = NSTextField(wrappingLabelWithString: "")
        scriptLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        scriptLabel.textColor = .secondaryLabelColor
        scriptLabel.isSelectable = true
        scriptLabel.maximumNumberOfLines = 14
        scriptLabel.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(scriptLabel)

        runButton = NSButton(title: "Run", target: self, action: #selector(runPlan))
        runButton.bezelStyle = .rounded
        runButton.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(clearPlan))
        cancel.bezelStyle = .rounded
        buttonRow = NSStackView(views: [cancel, runButton])
        buttonRow.spacing = 8
        stack.addArrangedSubview(buttonRow)

        recentHeader = NSTextField(labelWithString: "Recent")
        recentHeader.font = .systemFont(ofSize: 11, weight: .semibold)
        recentHeader.textColor = .secondaryLabelColor
        stack.addArrangedSubview(recentHeader)

        recentList = NSStackView()
        recentList.orientation = .vertical
        recentList.alignment = .leading
        recentList.spacing = 2
        stack.addArrangedSubview(recentList)

        for view in stack.arrangedSubviews where view !== buttonRow {
            view.widthAnchor.constraint(equalToConstant: width - padding * 2).isActive = true
        }
        resultLabel.preferredMaxLayoutWidth = width - padding * 2
        scriptLabel.preferredMaxLayoutWidth = width - padding * 2

        view = stack
        rebuildRecent()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        rebuildRecent()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        stopRecording()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        focusField()
    }

    /// Types into `external` — the menu-bar field — instead of the popover's own field, or back
    /// into the popover's own when nil.
    func useField(_ external: NSTextField?) {
        _ = view
        let target = external ?? ownField!
        if field !== target {
            target.stringValue = field.stringValue
        }
        field = target
        field.delegate = self
        field.target = self
        field.action = #selector(submit)
        ownField.isHidden = external != nil
        rowSpacer.isHidden = external == nil
    }

    private func focusField() {
        field.window?.makeFirstResponder(field)
    }

    // MARK: - Pieces

    private func makeInputRow() -> NSView {
        // The icon doubles as the way back to the shortcuts card once it has been closed.
        let icon = NSButton(image: symbol("sparkles", size: 15), target: self, action: #selector(toggleShortcuts))
        icon.isBordered = false
        icon.contentTintColor = .controlAccentColor
        icon.toolTip = "Shortcuts"

        field = NSTextField()
        ownField = field
        field.placeholderString = "e.g. close all windows"
        field.font = .systemFont(ofSize: 13)
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.delegate = self
        field.target = self
        field.action = #selector(submit)
        field.cell?.sendsActionOnEndEditing = false

        settingsButton = NSButton(image: symbol("gearshape", size: 13), target: self, action: #selector(showSettings))
        settingsButton.isBordered = false
        settingsButton.contentTintColor = .secondaryLabelColor
        settingsButton.toolTip = "Settings"

        // Stands in for the field when typing happens in the menu bar, keeping the gear right.
        rowSpacer = NSView()
        rowSpacer.isHidden = true
        rowSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        let row = NSStackView(views: [icon, field, rowSpacer, settingsButton])
        row.spacing = 6
        row.alignment = .centerY
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    private func makeShortcutsCard() -> NSView {
        let title = NSTextField(labelWithString: "Shortcuts")
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor

        let close = NSButton(image: symbol("xmark", size: 9), target: self, action: #selector(dismissShortcuts))
        close.isBordered = false
        close.contentTintColor = .tertiaryLabelColor
        close.toolTip = "Close — the ✦ icon brings this back"

        let header = NSStackView(views: [title, NSView(), close])
        header.distribution = .fill

        let rows: [(String, String)] = [
            ("↩", "Ask, or plan a command"),
            ("↩ again", "Run the planned command"),
            ("⌘-click", "Explain a word in your terminal"),
            ("⌘-click in panel", "Follow a word in the answer"),
            ("⌘+  ⌘−", "Resize the answer panel"),
            ("Esc", "Dismiss the panel or this popover"),
            ("Set shortcut", "Run a recent command from anywhere"),
            ("Right-click icon", "Settings"),
        ]
        let grid = NSGridView(views: rows.map { key, text in
            let keyLabel = NSTextField(labelWithString: key)
            keyLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .medium)
            let textLabel = NSTextField(labelWithString: text)
            textLabel.font = .systemFont(ofSize: 11)
            textLabel.textColor = .secondaryLabelColor
            return [keyLabel, textLabel]
        })
        grid.rowSpacing = 3
        grid.columnSpacing = 12

        let card = NSStackView(views: [header, grid])
        card.orientation = .vertical
        card.alignment = .leading
        card.spacing = 6
        card.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        card.wantsLayer = true
        card.layer?.cornerRadius = 8
        card.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.12).cgColor
        header.widthAnchor.constraint(equalTo: card.widthAnchor, constant: -20).isActive = true
        return card
    }

    private func symbol(_ name: String, size: CGFloat) -> NSImage {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
        return image.withSymbolConfiguration(.init(pointSize: size, weight: .medium)) ?? image
    }

    // MARK: - State

    private func refresh() {
        shortcutsCard.isHidden = Settings.didDismissShortcuts
        resultLabel.isHidden = resultLabel.stringValue.isEmpty
        scriptLabel.isHidden = plan?.script == nil
        buttonRow.isHidden = plan?.script == nil || busy
        runButton.isEnabled = !busy
        field.isEnabled = !busy
        recentHeader.isHidden = recentList.arrangedSubviews.isEmpty
        recentList.isHidden = recentList.arrangedSubviews.isEmpty
        preferredContentSize = stack.fittingSize
    }

    private func show(_ text: String, error: Bool = false) {
        resultLabel.stringValue = text
        resultLabel.textColor = error ? .systemRed : .labelColor
        refresh()
    }

    // MARK: - Actions

    @objc private func toggleShortcuts() {
        Settings.didDismissShortcuts.toggle()
        refresh()
    }

    @objc private func dismissShortcuts() {
        Settings.didDismissShortcuts = true
        refresh()
    }

    @objc private func showSettings() {
        onShowSettings?(settingsButton)
    }

    /// Return in the field: a new line is sent to Claude; the line that is already planned runs.
    @objc private func submit() {
        let input = field.stringValue.trimmed
        guard !input.isEmpty, !busy else { return }
        if plan?.script != nil, input == plannedInput {
            runPlan()
            return
        }

        // A line that has run before is already a script: no need to ask Claude again.
        if let saved = ShellHistory.match(input) {
            plan = saved.plan
            plannedInput = input
            scriptLabel.stringValue = saved.script
            show("\(saved.summary)\n\nSaved script — press ↩ to run.")
            return
        }

        plan = nil
        busy = true
        show("Thinking…")
        resultLabel.textColor = .secondaryLabelColor

        ShellCommand.plan(input, snapshot: snapshot) { [weak self] result in
            guard let self else { return }
            self.busy = false
            switch result {
            case .success(let plan):
                Log.event("planned \(plan.script == nil ? "answer" : plan.language.rawValue)")
                self.plan = plan
                self.plannedInput = input
                self.scriptLabel.stringValue = plan.script ?? ""
                self.show(plan.script == nil ? plan.summary : "\(plan.summary)\n\nPress ↩ to run.")
            case .failure(let error):
                Log.event("planning failed: \(error.localizedDescription)")
                self.show(error.localizedDescription, error: true)
            }
            self.focusField()
        }
    }

    @objc private func runPlan() {
        guard let plan, plan.script != nil, !busy else { return }
        busy = true
        show("Running…")

        ShellCommand.run(plan) { [weak self] result in
            guard let self else { return }
            self.busy = false
            switch result {
            case .success(let output):
                Log.event("command ran")
                ShellHistory.record(input: self.plannedInput, plan: plan)
                self.plan = nil
                self.field.stringValue = ""
                self.show(output.isEmpty ? "Done." : output)
            case .failure(let error):
                self.report(error)
            }
            self.focusField()
        }
    }

    /// Runs a saved command as it ran before — from its row, or from its global shortcut while
    /// the popover is closed. Only a failure brings the popover up.
    func runSaved(_ id: UUID) {
        guard let item = ShellHistory.items.first(where: { $0.id == id }), !busy else { return }
        busy = true
        if view.window?.isVisible == true { show("Running “\(item.input)”…") }

        ShellCommand.run(item.plan) { [weak self] result in
            guard let self else { return }
            self.busy = false
            switch result {
            case .success(let output):
                Log.event("saved command ran")
                ShellHistory.touch(id)
                self.plan = nil
                self.show(output.isEmpty ? "Done: \(item.input)" : output)
            case .failure(let error):
                self.onNeedsShowing?()
                self.report(error)
            }
        }
    }

    private func report(_ error: Error) {
        Log.event("command failed: \(error.localizedDescription)")
        if case .needsAccessibility? = error as? ShellCommand.CommandError {
            AppDelegate.requestAccessibility()
        } else if case .notAuthorized? = error as? ShellCommand.CommandError {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
        }
        show(error.localizedDescription, error: true)
    }

    // MARK: - Recent commands

    private func rebuildRecent() {
        guard isViewLoaded else { return }
        recentList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for item in ShellHistory.items.prefix(8) {
            recentList.addArrangedSubview(recentRow(item))
        }
        refresh()
    }

    private func recentRow(_ item: HistoryItem) -> NSView {
        let run = RowButton(title: item.input, target: self, action: #selector(recentTapped(_:)))
        run.identifier = NSUserInterfaceItemIdentifier(item.id.uuidString)
        run.toolTip = item.summary
        run.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        run.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let title = recording == item.id ? "Press keys…" : item.shortcut?.display ?? "Set shortcut"
        let shortcut = NSButton(title: title, target: self, action: #selector(shortcutTapped(_:)))
        shortcut.identifier = run.identifier
        shortcut.bezelStyle = .inline
        shortcut.controlSize = .small
        shortcut.font = item.shortcut == nil && recording != item.id
            ? .systemFont(ofSize: 10) : .monospacedSystemFont(ofSize: 10, weight: .medium)
        shortcut.toolTip = "Run this from anywhere with a key combination. ⌫ clears it, Esc cancels."
        shortcut.setContentHuggingPriority(.required, for: .horizontal)

        let remove = NSButton(image: symbol("xmark", size: 8), target: self, action: #selector(removeTapped(_:)))
        remove.identifier = run.identifier
        remove.isBordered = false
        remove.contentTintColor = .tertiaryLabelColor
        remove.toolTip = "Forget this command"
        remove.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [run, shortcut, remove])
        row.spacing = 6
        row.alignment = .centerY
        row.widthAnchor.constraint(equalToConstant: width - padding * 2).isActive = true
        return row
    }

    private func itemID(_ sender: NSView) -> UUID? {
        sender.identifier.flatMap { UUID(uuidString: $0.rawValue) }
    }

    @objc private func recentTapped(_ sender: NSButton) {
        guard let id = itemID(sender) else { return }
        stopRecording()
        runSaved(id)
    }

    @objc private func removeTapped(_ sender: NSButton) {
        guard let id = itemID(sender) else { return }
        if recording == id { stopRecording() }
        ShellHistory.remove(id)
    }

    /// Waits for the next key combination typed into the popover and binds it to the row.
    @objc private func shortcutTapped(_ sender: NSButton) {
        guard let id = itemID(sender) else { return }
        if recording == id {
            stopRecording()
            return
        }
        stopRecording()
        recording = id
        recordMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let id = self.recording else { return event }
            switch Int(event.keyCode) {
            case 53:  // esc
                self.stopRecording()
            case 51, 117:  // delete, forward delete
                self.stopRecording()
                ShellHistory.setShortcut(nil, for: id)
            default:
                guard let combo = GlobalHotKeys.combo(from: event) else {
                    NSSound.beep()  // needs ⌘, ⌃ or ⌥
                    return nil
                }
                self.stopRecording()
                ShellHistory.setShortcut(combo, for: id)
            }
            return nil
        }
        rebuildRecent()
    }

    private func stopRecording() {
        if let recordMonitor { NSEvent.removeMonitor(recordMonitor) }
        recordMonitor = nil
        guard recording != nil else { return }
        recording = nil
        rebuildRecent()
    }

    /// Called when the history changes anywhere, so the list stays current.
    func historyChanged() {
        rebuildRecent()
    }

    @objc private func clearPlan() {
        plan = nil
        show("")
    }

    /// Esc in the field. A text field's editor treats Esc as "complete", so it never reaches
    /// the window and has to be caught here.
    var onEscape: (() -> Void)?

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        if recording != nil {
            stopRecording()
        } else {
            onEscape?()
        }
        return true
    }

    /// Typing after a plan was made means a new request, so the old plan stops being runnable.
    func controlTextDidChange(_ obj: Notification) {
        guard plan != nil, field.stringValue.trimmed != plannedInput else { return }
        plan = nil
        show("")
    }
}

/// A borderless, left-aligned button for one recent command that highlights under the pointer.
private final class RowButton: NSButton {
    init(title: String, target: AnyObject, action: Selector) {
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        alignment = .left
        lineBreakMode = .byTruncatingTail
        font = .systemFont(ofSize: 12)
        wantsLayer = true
        layer?.cornerRadius = 5
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
    }
}
