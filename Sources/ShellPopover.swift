import AppKit

/// What the menu-bar icon opens: a field that takes a question or a command, a shortcuts card
/// shown until it is closed once, and the plan Claude made from the last line typed.
///
/// Return asks Claude; when the answer is a script, Return again (or Run) carries it out.
final class ShellPopover: NSViewController, NSTextFieldDelegate {

    var onShowSettings: ((NSView) -> Void)?
    /// The terminal screen captured when the popover opened, before this app took focus.
    var snapshot: TerminalSnapshot?

    private let width: CGFloat = 380
    private let padding: CGFloat = 12

    private var stack: NSStackView!
    private var shortcutsCard: NSView!
    private var field: NSTextField!
    private var resultLabel: NSTextField!
    private var scriptLabel: NSTextField!
    private var buttonRow: NSStackView!
    private var runButton: NSButton!
    private var settingsButton: NSButton!

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

        for view in stack.arrangedSubviews where view !== buttonRow {
            view.widthAnchor.constraint(equalToConstant: width - padding * 2).isActive = true
        }
        resultLabel.preferredMaxLayoutWidth = width - padding * 2
        scriptLabel.preferredMaxLayoutWidth = width - padding * 2

        view = stack
        refresh()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(field)
    }

    // MARK: - Pieces

    private func makeInputRow() -> NSView {
        // The icon doubles as the way back to the shortcuts card once it has been closed.
        let icon = NSButton(image: symbol("sparkles", size: 15), target: self, action: #selector(toggleShortcuts))
        icon.isBordered = false
        icon.contentTintColor = .controlAccentColor
        icon.toolTip = "Shortcuts"

        field = NSTextField()
        field.placeholderString = "e.g. close all windows but IntelliJ"
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

        let row = NSStackView(views: [icon, field, settingsButton])
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
            self.view.window?.makeFirstResponder(self.field)
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
                self.plan = nil
                self.field.stringValue = ""
                self.show(output.isEmpty ? "Done." : output)
            case .failure(let error):
                Log.event("command failed: \(error.localizedDescription)")
                if case .needsAccessibility? = error as? ShellCommand.CommandError {
                    AppDelegate.requestAccessibility()
                } else if case .notAuthorized? = error as? ShellCommand.CommandError {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                }
                self.show(error.localizedDescription, error: true)
            }
            self.view.window?.makeFirstResponder(self.field)
        }
    }

    @objc private func clearPlan() {
        plan = nil
        show("")
    }

    /// Typing after a plan was made means a new request, so the old plan stops being runnable.
    func controlTextDidChange(_ obj: Notification) {
        guard plan != nil, field.stringValue.trimmed != plannedInput else { return }
        plan = nil
        show("")
    }
}
