import Foundation

/// Finds the Anthropic API key.
///
/// A GUI app doesn't inherit the shell environment, so `~/.zshrc` (and friends) are
/// scanned for an `export ANTHROPIC_API_KEY=…` line. The environment still wins if set.
enum ApiKey {

    private static var cached: String??

    static func current() -> String? {
        if let cached, let value = cached { return value }
        let found = resolve()
        cached = .some(found)
        return found
    }

    static func reload() -> String? {
        cached = nil
        return current()
    }

    static var source: String = "not found"

    /// For the menu: before the first request nothing has been read, so say what is likely.
    static var displaySource: String {
        if cached != nil { return source }
        return hasStoredKey ? "pasted (Keychain), read on first use" : isLikelyAvailable ? "found, read on first use" : "not found"
    }

    /// Persist a key the user pasted into the app. It outranks the shell files, because
    /// pasting is a deliberate act and a forgotten rc-file export shouldn't shadow it.
    @discardableResult
    static func save(_ key: String) -> Bool {
        let trimmed = key.trimmed
        guard !trimmed.isEmpty else { return false }
        let ok = Keychain.write(trimmed)
        cached = nil
        _ = current()
        return ok
    }

    static func clearStored() {
        Keychain.delete()
        cached = nil
        _ = current()
    }

    static var hasStoredKey: Bool { Keychain.exists }

    /// Whether some key is there to be found, without reading the Keychain item itself.
    static var isLikelyAvailable: Bool {
        if let cached { return cached != nil }
        if Keychain.exists { return true }
        let env = ProcessInfo.processInfo.environment
        if ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"].contains(where: { !(env[$0] ?? "").trimmed.isEmpty }) {
            return true
        }
        return shellFileKey() != nil
    }

    private static func resolve() -> String? {
        for name in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"] {
            if let value = ProcessInfo.processInfo.environment[name], !value.trimmed.isEmpty {
                source = "environment (\(name))"
                return value.trimmed
            }
        }

        if let stored = Keychain.read() {
            source = "pasted (Keychain)"
            return stored
        }

        if let (key, file) = shellFileKey() {
            source = "~/\(file)"
            return key
        }

        source = "not found"
        return nil
    }

    private static func shellFileKey() -> (String, String)? {
        let home = NSHomeDirectory()
        let candidates = [".zshrc", ".zshenv", ".zprofile", ".zlogin", ".bash_profile", ".bashrc", ".profile"]
        for file in candidates {
            guard let contents = try? String(contentsOfFile: "\(home)/\(file)", encoding: .utf8) else { continue }
            if let key = extractKey(from: contents) { return (key, file) }
        }
        return nil
    }

    /// Matches `export ANTHROPIC_API_KEY="sk-…"`, `ANTHROPIC_API_KEY=sk-…`, single quotes, etc.
    /// The last assignment wins, mirroring how the shell would evaluate the file.
    private static func extractKey(from contents: String) -> String? {
        let pattern = #"(?m)^[^\S\n]*(?:export[^\S\n]+)?ANTHROPIC_(?:API_KEY|AUTH_TOKEN)[^\S\n]*=[^\S\n]*["']?([^"'\s#]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(contents.startIndex..<contents.endIndex, in: contents)
        let matches = regex.matches(in: contents, range: range)
        guard let last = matches.last, last.numberOfRanges > 1,
              let keyRange = Range(last.range(at: 1), in: contents)
        else { return nil }

        let key = String(contents[keyRange]).trimmed
        // Skip shell indirections like ANTHROPIC_API_KEY=$OTHER_VAR or `$(op read …)`.
        guard !key.hasPrefix("$"), key.count > 8 else { return nil }
        return key
    }
}
