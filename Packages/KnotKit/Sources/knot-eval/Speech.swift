import Foundation

/// `knot-eval speech`, which scores transcription. WP-13 builds it, and this file is WP-13's.
enum SpeechCommand {
    /// Runs the command with the arguments that follow `speech`, and returns the exit status.
    static func run(_ arguments: [String]) async -> Int32 {
        FileHandle.standardError.write(Data("knot-eval speech: not built yet. WP-13 builds it.\n".utf8))
        return 2
    }
}
