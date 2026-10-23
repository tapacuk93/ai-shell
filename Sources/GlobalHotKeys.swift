import AppKit
import Carbon.HIToolbox

/// System-wide shortcuts for saved commands, through Carbon's `RegisterEventHotKey`.
/// Unlike an event tap it needs no permission at all, which keeps permissions lazy.
final class GlobalHotKeys {

    var onPressed: ((UUID) -> Void)?

    private var refs: [EventHotKeyRef] = []
    private var ids: [UInt32: UUID] = [:]
    private var handler: EventHandlerRef?

    /// Replaces every registration with one per history item that has a shortcut.
    func register(_ items: [HistoryItem]) {
        installHandler()
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        ids.removeAll()

        for (index, item) in items.enumerated() {
            guard let combo = item.shortcut else { continue }
            let number = UInt32(index + 1)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                combo.keyCode, combo.carbonModifiers,
                EventHotKeyID(signature: GlobalHotKeys.signature, id: number),
                GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
                ids[number] = item.id
            } else {
                Log.event("could not register \(combo.display) (\(status)) — taken by another app?")
            }
        }
    }

    private static let signature: OSType = 0x4149_5348  // 'AISH'

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var hotKey = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            let me = Unmanaged<GlobalHotKeys>.fromOpaque(context).takeUnretainedValue()
            if let id = me.ids[hotKey.id] { me.onPressed?(id) }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    // MARK: - Recording

    /// The combination a key-down describes, or nil when it has no ⌘, ⌃ or ⌥ — a bare key or
    /// ⇧-key would fire while typing anywhere.
    static func combo(from event: NSEvent) -> KeyCombo? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .control, .option]).isEmpty else { return nil }

        var carbon: UInt32 = 0
        var display = ""
        if flags.contains(.control) { carbon |= UInt32(controlKey); display += "⌃" }
        if flags.contains(.option) { carbon |= UInt32(optionKey); display += "⌥" }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey); display += "⇧" }
        if flags.contains(.command) { carbon |= UInt32(cmdKey); display += "⌘" }
        display += keyName(event)
        return KeyCombo(keyCode: UInt32(event.keyCode), carbonModifiers: carbon, display: display)
    }

    private static func keyName(_ event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default:
            return (event.charactersIgnoringModifiers ?? "?").uppercased()
        }
    }
}
