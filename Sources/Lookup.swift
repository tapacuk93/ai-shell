import Foundation
import CoreServices

struct Definition {
    let term: String
    let kind: String      // "command", "abbreviation", … shown as a badge
    let text: String
    let source: String    // where the explanation came from
}

/// Resolves a token to an explanation, cheapest and most readable source first.
enum Lookup {

    static func define(_ token: String, completion: @escaping (Definition) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = define(token)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// The glossary layer on its own. It is an in-memory table, so unlike `whatis`, the
    /// macOS Dictionary and `which` — each of which spawns a process or can block — it costs
    /// nothing, and can ground Claude's answer without delaying the request.
    static func hint(for token: String) -> String? {
        let word = token.trimmed
        if let entry = Glossary.entry(for: word) { return entry.text }
        if let flag = Tokenizer.normalizedFlag(word), let entry = Glossary.entry(for: flag) { return entry.text }
        return nil
    }

    static func define(_ token: String) -> Definition {
        let word = token.trimmed

        // 1. Curated glossary — the nicest wording, and it knows abbreviations.
        if let entry = Glossary.entry(for: word) {
            return Definition(term: word, kind: entry.kind, text: entry.text, source: "glossary")
        }

        // 2. A flag like --amend: explain it as an option and point at the man page.
        if let flag = Tokenizer.normalizedFlag(word) {
            if let entry = Glossary.entry(for: flag) {
                return Definition(term: word, kind: "option", text: entry.text, source: "glossary")
            }
            return Definition(
                term: word,
                kind: "option",
                text: "A command-line option (flag). A single dash usually introduces short flags that can be bundled "
                    + "(`-la` = `-l -a`); a double dash introduces one long name (`--all`). Check the command's man page for what this one does.",
                source: "heuristic")
        }

        // 3. Man page one-liner.
        if let summary = whatis(word) {
            return Definition(term: word, kind: "man page", text: summary, source: "whatis(1)")
        }

        // 4. macOS Dictionary — handles ordinary English words.
        if let definition = dictionaryDefinition(word) {
            return Definition(term: word, kind: "dictionary", text: definition, source: "macOS Dictionary")
        }

        // 5. Is it at least an executable on PATH?
        if let path = which(word) {
            return Definition(
                term: word,
                kind: "executable",
                text: "An executable at \(path). No man page description is installed for it — try `\(word) --help`.",
                source: "PATH")
        }

        // 6. Shape-based guesses.
        if let guess = heuristic(word) { return guess }

        return Definition(
            term: word,
            kind: "unknown",
            text: "No definition found in the built-in glossary, man pages or the macOS Dictionary.",
            source: "—")
    }

    // MARK: - Sources

    private static func whatis(_ word: String) -> String? {
        guard word.range(of: "^[A-Za-z0-9._+-]{1,40}$", options: .regularExpression) != nil else { return nil }
        guard let output = Shell.run("/usr/bin/whatis", [word]) else { return nil }

        // `whatis` also matches on description text, so a plain English word can pull up an
        // unrelated man page. Only accept a line whose *name* list contains the exact word.
        let lines = output.split(separator: "\n").map(String.init)
            .filter { score(line: $0, for: word) > 0 }
        let ranked = lines.sorted { a, b in
            score(line: a, for: word) > score(line: b, for: word)
        }
        for line in ranked {
            guard let range = line.range(of: " - ") else { continue }
            let names = String(line[line.startIndex..<range.lowerBound]).trimmed
            let description = String(line[range.upperBound...]).trimmed
            guard !description.isEmpty, !description.lowercased().contains("nothing appropriate") else { continue }
            let section = names.range(of: "\\((\\w+)\\)", options: .regularExpression).map { String(names[$0]) } ?? ""
            return "\(description.prefix(1).capitalized)\(description.dropFirst()). \(section.isEmpty ? "" : "man page \(section).")".trimmed
        }
        return nil
    }

    private static func score(line: String, for word: String) -> Int {
        let head = line.components(separatedBy: " - ").first ?? line
        let names = head.components(separatedBy: ",").map {
            $0.trimmed.replacingOccurrences(of: "\\(.*\\)", with: "", options: .regularExpression)
        }
        guard let index = names.firstIndex(of: word) else { return 0 }
        return 100 - index
    }

    private static func dictionaryDefinition(_ word: String) -> String? {
        guard word.range(of: "^[A-Za-z][A-Za-z'-]{1,30}$", options: .regularExpression) != nil else { return nil }
        let text = word as CFString
        let range = CFRangeMake(0, CFStringGetLength(text))
        guard let result = DCSCopyTextDefinition(nil, text, range) else { return nil }
        let definition = result.takeRetainedValue() as String
        let cleaned = definition
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmed
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(600))
    }

    private static func which(_ word: String) -> String? {
        guard word.range(of: "^[A-Za-z0-9._+-]{1,40}$", options: .regularExpression) != nil else { return nil }
        guard let output = Shell.run("/usr/bin/which", [word]) else { return nil }
        let path = output.trimmed
        return path.hasPrefix("/") ? path : nil
    }

    private static func heuristic(_ word: String) -> Definition? {
        if word.hasPrefix("/") || word.hasPrefix("~/") || word.contains("/") {
            return Definition(term: word, kind: "path", text: "A filesystem path. `ls -l` inspects it, `file` reports what kind of thing it is.", source: "heuristic")
        }
        if word.hasPrefix("$") {
            let name = String(word.dropFirst())
            let value = ProcessInfo.processInfo.environment[name]
            let current = value.map { "\n\nCurrent value: \($0)" } ?? ""
            return Definition(term: word, kind: "variable", text: "A shell variable reference — the shell substitutes \(name)'s value here.\(current)", source: "heuristic")
        }
        if word.uppercased() == word, word.count >= 2, word.allSatisfy({ $0.isUppercase || $0 == "_" || $0.isNumber }) {
            return Definition(term: word, kind: "variable", text: "Looks like an environment variable name — by convention they're uppercase. `echo $\(word)` prints its value, `env` lists them all.", source: "heuristic")
        }
        if word.contains(".") , let ext = word.split(separator: ".").last, ext.count <= 5 {
            return Definition(term: word, kind: "file", text: "Looks like a filename with a .\(ext) extension.", source: "heuristic")
        }
        return nil
    }
}

/// Runs a short-lived helper process with a hard timeout.
enum Shell {
    static func run(_ launchPath: String, _ arguments: [String], timeout: TimeInterval = 2.0) -> String? {
        guard FileManager.default.isExecutableFile(atPath: launchPath) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { return nil }

        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        guard let text = String(data: data, encoding: .utf8), !text.trimmed.isEmpty else { return nil }
        return text
    }

    /// A GUI app inherits a bare PATH, so add the usual places tools and man pages live.
    private static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let extraPaths = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/sbin",
                          "/usr/bin", "/bin", "/usr/sbin", "/sbin", "\(home)/.local/bin", "\(home)/bin"]
        var path = env["PATH"].map { $0.split(separator: ":").map(String.init) } ?? []
        for p in extraPaths where !path.contains(p) { path.append(p) }
        env["PATH"] = path.joined(separator: ":")

        let extraMan = ["/opt/homebrew/share/man", "/usr/local/share/man", "/usr/share/man", "/Library/Developer/CommandLineTools/usr/share/man"]
        var manPath = env["MANPATH"].map { $0.split(separator: ":").map(String.init) } ?? []
        for p in extraMan where !manPath.contains(p) && FileManager.default.fileExists(atPath: p) { manPath.append(p) }
        env["MANPATH"] = manPath.joined(separator: ":")
        return env
    }()
}
