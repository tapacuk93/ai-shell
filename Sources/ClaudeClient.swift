import Foundation

/// Minimal raw-HTTP client for the Anthropic Messages API.
/// Swift has no official Anthropic SDK, so this talks to `POST /v1/messages` directly.
enum ClaudeClient {

    static let model = "claude-opus-5"
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let apiVersion = "2023-06-01"

    enum ClientError: LocalizedError {
        case noKey
        case http(Int, String)
        case refused(String)
        case malformed

        var errorDescription: String? {
            switch self {
            case .noKey:
                return "No API key. Add one from the TermDefine menu bar icon → Set API key…"
            case .http(let status, let message):
                return "Anthropic API error \(status): \(message)"
            case .refused(let category):
                return "Claude declined this one (\(category)), at every point in the scrollback."
            case .malformed:
                return "Unexpected response from the Anthropic API."
            }
        }
    }

    struct Answer {
        let text: String
        /// How many characters back the window came from: 0 is the text on screen now, higher
        /// means the classifier declined that far and the retry stepped back through scrollback.
        let charactersBack: Int
        /// False when the terminal exposed no text at all, so this is a plain definition.
        let usedScreen: Bool
    }

    /// Explains `token` using what is currently on the terminal screen as context.
    ///
    /// A terminal screen can carry security-shaped text — a pentest tool's output, an exploit
    /// in a file being edited, a log full of auth failures — that the clicked word has nothing
    /// to do with, and the safety classifiers judge the request as a whole. So a refusal is
    /// retried: first with the window doubled in place, up to twenty thousand characters, since
    /// a window that stops mid-exchange is the one most easily mistaken for the text around it;
    /// then, that exhausted, against ever earlier windows until the scrollback runs out.
    static func explain(
        token: String,
        line: String,
        hint: String?,
        snapshot: TerminalSnapshot,
        completion: @escaping (Result<Answer, Error>) -> Void
    ) {
        send(token: token, line: line, hint: hint, snapshot: snapshot) { result in
            switch result {
            case .success(let text):
                completion(.success(Answer(
                    text: text,
                    charactersBack: snapshot.offset,
                    usedScreen: !snapshot.isEmpty)))

            case .failure(let error):
                guard case .refused(let category)? = error as? ClientError,
                      let retry = snapshot.enlarged() ?? snapshot.steppedBack()
                else {
                    completion(.failure(error))
                    return
                }
                Log.event("refused (\(category)) — retrying with \(retry.length) chars, "
                          + "\(retry.offset) back")
                explain(token: token, line: line, hint: hint, snapshot: retry, completion: completion)
            }
        }
    }

    private static func send(
        token: String,
        line: String,
        hint: String?,
        snapshot: TerminalSnapshot,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let key = ApiKey.current() else {
            completion(.failure(ClientError.noKey))
            return
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 600,
            // A popup wants an answer in a second or two, and the whole task is a short
            // explanation — so no thinking, and the cheapest effort level.
            "thinking": ["type": "disabled"],
            "output_config": ["effort": "low"],
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": userPrompt(token: token, line: line, hint: hint, snapshot: snapshot)]
            ],
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            completion(.failure(ClientError.malformed))
            return
        }
        request.httpBody = data

        URLSession.shared.dataTask(with: request) { data, response, error in
            let result = parse(data: data, response: response, error: error)
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    // MARK: - Response handling

    private static func parse(data: Data?, response: URLResponse?, error: Error?) -> Result<String, Error> {
        if let error { return .failure(error) }
        guard let data, let http = response as? HTTPURLResponse else {
            return .failure(ClientError.malformed)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(ClientError.malformed)
        }

        guard (200..<300).contains(http.statusCode) else {
            let message = (json["error"] as? [String: Any])?["message"] as? String ?? "unknown error"
            return .failure(ClientError.http(http.statusCode, message))
        }

        // Claude Opus 5's safety classifiers can decline a request: that arrives as a
        // successful 200 with no content, so check stop_reason before reading blocks.
        if json["stop_reason"] as? String == "refusal" {
            let category = (json["stop_details"] as? [String: Any])?["category"] as? String ?? "policy"
            return .failure(ClientError.refused(category))
        }

        let blocks = json["content"] as? [[String: Any]] ?? []
        let text = blocks
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
            .trimmed

        return text.isEmpty ? .failure(ClientError.malformed) : .success(text)
    }

    // MARK: - Prompts

    private static let systemPrompt = """
    You explain terminal words for a developer who just ⌘-clicked one in their terminal. \
    You are shown the word, the line it came from, and the visible terminal screen. Your \
    answer is the only thing the popup shows, so it has to stand on its own.

    This is a glossary lookup, not a task about the screen. The user is the operator of this \
    machine, reading their own terminal; the screen is included only so you can tell which \
    sense of the word is meant. Explain the terminology and nothing else — never write, \
    extend, fix, run or advise on the commands, code or output that happen to be visible.

    Answer in 2–4 short sentences of plain prose. Say what the word is and what it is doing \
    here as one continuous explanation — not a general definition followed by a separate \
    “Here it is …” sentence bolted on. Carry the meaning through the specifics on screen: the \
    command it belongs to, the flag it modifies, the path it points at, the error it appears \
    in, the Claude Code session around it. If the screen shows an error involving the word, \
    say what caused it. Skip any preamble, do not repeat the word as a heading, and do not use \
    markdown or bullet lists. Do not include internal or system XML tags in your response. If \
    the screen gives you nothing useful, just define the word.
    """

    private static func userPrompt(token: String, line: String, hint: String?, snapshot: TerminalSnapshot) -> String {
        var parts: [String] = []
        parts.append("Word: \(token)")
        if !line.trimmed.isEmpty, line.trimmed != token {
            parts.append("Line it was clicked on: \(line.trimmed)")
        }
        parts.append("Terminal app: \(snapshot.appName)")

        if let hint {
            parts.append("Reference gloss (may be wrong for this context): \(hint)")
        }

        if snapshot.claudeSession {
            parts.append("""
            The screen shows an interactive Claude Code session (Anthropic's terminal coding agent). \
            Read the word in that light: it may be a slash command, a permission mode, a tool name, \
            a status line, or part of a file the agent is editing.
            """)
        }

        if !snapshot.isEmpty {
            parts.append("Visible terminal screen:\n<screen>\n\(snapshot.screen)\n</screen>")
        }

        return parts.joined(separator: "\n\n")
    }
}
