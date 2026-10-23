import Foundation
import os

/// Diagnostics for "I clicked and nothing happened" reports.
///
/// Read them with:
///     log show --last 5m --predicate 'subsystem == "com.oeaio.aishell"' --style compact
///
/// Only the word being looked up and which code path ran are recorded — never the terminal
/// screen contents that get sent to the API.
enum Log {
    private static let logger = Logger(subsystem: "com.oeaio.aishell", category: "lookup")

    static func event(_ message: String) {
        logger.log("\(message, privacy: .public)")
    }
}
