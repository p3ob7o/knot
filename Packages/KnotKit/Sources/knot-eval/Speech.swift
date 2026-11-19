import Foundation

/// `knot-eval speech`, which scores transcription. WP-13 builds it, and this file is WP-13's.
enum SpeechCommand {
    /// Runs the command and returns its exit status, one of `EvalExit`.
    static func run(_ options: EvalOptions) async -> Int32 {
        FileHandle.standardError.write(Data("knot-eval speech: not built yet. WP-13 builds it.\n".utf8))
        return EvalExit.notBuilt
    }
}
