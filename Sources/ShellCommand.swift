import AppKit

/// What Claude makes of a line typed into the menu-bar field: either an answer to show, or a
/// script that carries out a command like "close all windows but IntelliJ".
struct ShellPlan {
    enum Language: String { case applescript, shell }

    /// One sentence: the answer itself, or what the script is about to do.
    let summary: String
    /// Nil when the line was a question rather than something to do.
    let script: String?
    let language: Language
}

enum ShellCommand {

    /// The command path wants a script that works first time more than it wants speed, so it
    /// runs on the current Opus with thinking left on, at low effort.
    static let model = "claude-opus-5-5"

    enum CommandError: LocalizedError {
        case refused
        case failed(String)
        /// macOS blocked an Apple Event. The prompt comes up the first time a target is
        /// scripted; once it has been answered "no", only System Settings can change it.
        case notAuthorized(String)
        /// UI scripting through System Events needs Accessibility, which is asked for on demand.
        case needsAccessibility

        var errorDescription: String? {
            switch self {
            case .refused:
                return "Claude declined to plan this one."
            case .failed(let message):
                return message
            case .notAuthorized(let message):
                return "Not allowed to control that app yet. Allow it under Privacy & Security → Automation, then run again.\n\(message)"
            case .needsAccessibility:
                return "Controlling windows needs Accessibility access. Grant it in the dialog, then run again."
            }
        }
    }

    // MARK: - Planning

    static func plan(_ input: String, snapshot: TerminalSnapshot?,
                     completion: @escaping (Result<ShellPlan, Error>) -> Void) {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 8000,
            "output_config": [
                "effort": "low",
                "format": ["type": "json_schema", "schema": schema],
            ],
            "fallbacks": "default",
            "system": systemPrompt,
            "messages": [["role": "user", "content": userPrompt(input, snapshot: snapshot)]],
        ]

        ClaudeClient.post(body, beta: "server-side-fallback-2026-07-01", timeout: 60) { result in
            switch result {
            case .failure(let error):
                if case .refused? = error as? ClaudeClient.ClientError {
                    completion(.failure(CommandError.refused))
                } else {
                    completion(.failure(error))
                }
            case .success(let text):
                guard let data = text.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let summary = json["summary"] as? String
                else {
                    completion(.failure(ClaudeClient.ClientError.malformed))
                    return
                }
                let script = (json["script"] as? String)?.trimmed
                completion(.success(ShellPlan(
                    summary: summary,
                    script: json["kind"] as? String == "run" && script?.isEmpty == false ? script : nil,
                    language: ShellPlan.Language(rawValue: json["language"] as? String ?? "") ?? .applescript)))
            }
        }
    }

    private static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "kind": ["type": "string", "enum": ["run", "answer"]],
            "summary": ["type": "string"],
            "language": ["type": "string", "enum": ["applescript", "shell"]],
            "script": ["type": "string"],
        ],
        "required": ["kind", "summary", "language", "script"],
        "additionalProperties": false,
    ]

    private static let systemPrompt = """
    You are the command line of a macOS menu-bar app called AI Shell. The user types a \
    request in plain language and you turn it into a script that carries it out on their \
    Mac, or answer it if it is a question. The user reviews your summary and script and \
    presses Return to run it, so the summary must say exactly what will happen.

    Reply with kind "run" and a script for anything that acts on the Mac: windows, apps, \
    files, settings, the clipboard. Reply with kind "answer", an empty script and the answer \
    in summary for questions; answers are 1–4 sentences of plain prose, no markdown.

    Prefer AppleScript (language "applescript"); use "shell" (run with zsh) only for work \
    that is naturally a shell command. Match app names against the running apps listed — \
    "intellij" means IntelliJ IDEA, "chrome" means Google Chrome. To close windows, use \
    System Events UI scripting: for each target process, click the button whose subrole is \
    "AXCloseButton" of each window, wrapped in try so one stubborn window doesn't stop the \
    rest; that works for apps with no scripting dictionary. "Close" means close windows, \
    not quit, unless the user says quit. Never touch the AI Shell app itself, Finder's \
    desktop, or processes that are background only. Do not delete files, empty the Trash, \
    or use sudo unless the user asked for exactly that, and say so plainly in the summary \
    when a command is destructive. Keep scripts short and self-contained.
    """

    private static func userPrompt(_ input: String, snapshot: TerminalSnapshot?) -> String {
        var parts = ["Request: \(input)"]

        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { app -> String? in
                guard let name = app.localizedName else { return nil }
                return "\(name) (\(app.bundleIdentifier ?? "?"))\(app.isHidden ? ", hidden" : "")"
            }
        parts.append("Running apps:\n" + apps.joined(separator: "\n"))

        if let front = AppDelegate.lastFrontmost?.localizedName {
            parts.append("Frontmost app before the field opened: \(front)")
        }
        if let snapshot, !snapshot.isEmpty {
            parts.append("Its visible terminal screen, for questions about it:\n<screen>\n\(snapshot.screen)\n</screen>")
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Running

    /// Runs a plan's script off the main thread. Scripts go through `osascript` and `zsh` as
    /// child processes, which macOS attributes to this app — so the Automation prompt for each
    /// app comes up the first time a command touches it, and not before.
    static func run(_ plan: ShellPlan, completion: @escaping (Result<String, Error>) -> Void) {
        guard let script = plan.script else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            switch plan.language {
            case .applescript:
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-"]
            case .shell:
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-c", script]
            }
            let input = Pipe(), output = Pipe(), errors = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errors

            let result: Result<String, Error>
            do {
                try process.run()
                if plan.language == .applescript { input.fileHandleForWriting.write(Data(script.utf8)) }
                try? input.fileHandleForWriting.close()
                let out = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmed
                let err = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmed
                process.waitUntilExit()
                result = process.terminationStatus == 0 ? .success(out) : .failure(classify(err))
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func classify(_ message: String) -> Error {
        if message.contains("-1743") { return CommandError.notAuthorized(message) }
        if message.contains("-1719") || message.contains("-25211") || message.contains("assistive access") {
            return CommandError.needsAccessibility
        }
        return CommandError.failed(message.isEmpty ? "The script failed." : message)
    }
}
