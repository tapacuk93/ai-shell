import AppKit

/// A global key combination, stored as the Carbon key code and modifier mask that
/// `RegisterEventHotKey` wants, plus how to print it.
struct KeyCombo: Codable, Equatable {
    let keyCode: UInt32
    let carbonModifiers: UInt32
    let display: String
}

/// A command that has run once, with the script that ran. Running it again — from the list,
/// by typing the same line, or by its shortcut — reuses the script instead of asking Claude.
struct HistoryItem: Codable, Identifiable {
    let id: UUID
    let input: String
    let summary: String
    let script: String
    let language: String
    var lastRun: Date
    var shortcut: KeyCombo?

    var plan: ShellPlan {
        ShellPlan(summary: summary, script: script,
                  language: ShellPlan.Language(rawValue: language) ?? .applescript)
    }
}

/// The executed commands, newest first, kept in UserDefaults.
enum ShellHistory {
    private static let key = "shellHistory"
    private static let limit = 30

    /// Fired after every change, so the popover list and the registered hotkeys follow.
    static var onChange: (() -> Void)?

    static var items: [HistoryItem] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
            return (try? JSONDecoder().decode([HistoryItem].self, from: data)) ?? []
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key)
            onChange?()
        }
    }

    /// A line typed again matches regardless of case and surrounding spaces.
    static func match(_ input: String) -> HistoryItem? {
        let wanted = normalized(input)
        return items.first { normalized($0.input) == wanted }
    }

    /// Records a successful run. The same line run again moves to the top and keeps its shortcut.
    static func record(input: String, plan: ShellPlan) {
        guard let script = plan.script else { return }
        var list = items
        let existing = list.firstIndex { normalized($0.input) == normalized(input) }
        let shortcut = existing.flatMap { list[$0].shortcut }
        let id = existing.map { list[$0].id } ?? UUID()
        if let existing { list.remove(at: existing) }

        list.insert(HistoryItem(id: id, input: input, summary: plan.summary, script: script,
                                language: plan.language.rawValue, lastRun: Date(), shortcut: shortcut), at: 0)
        // Items with a shortcut are never pushed out by the limit.
        while list.count > limit, let last = list.lastIndex(where: { $0.shortcut == nil }) {
            list.remove(at: last)
        }
        items = list
    }

    static func touch(_ id: UUID) {
        update(id) { $0.lastRun = Date() }
    }

    static func setShortcut(_ combo: KeyCombo?, for id: UUID) {
        var list = items
        // One combination, one command: taking it from another item clears it there.
        if let combo {
            for i in list.indices where list[i].shortcut == combo { list[i].shortcut = nil }
        }
        if let i = list.firstIndex(where: { $0.id == id }) { list[i].shortcut = combo }
        items = list
    }

    static func remove(_ id: UUID) {
        items = items.filter { $0.id != id }
    }

    private static func update(_ id: UUID, _ change: (inout HistoryItem) -> Void) {
        var list = items
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        change(&list[i])
        items = list
    }

    private static func normalized(_ s: String) -> String {
        s.trimmed.lowercased().replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}
