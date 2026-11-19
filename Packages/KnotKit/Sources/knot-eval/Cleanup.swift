import Foundation

/// `knot-eval cleanup`, which scores cleanup. WP-14 builds it, and this file is WP-14's.
enum CleanupCommand {
    /// Runs the command and returns its exit status, one of `EvalExit`.
    static func run(_ options: EvalOptions) async -> Int32 {
        FileHandle.standardError.write(Data("knot-eval cleanup: not built yet. WP-14 builds it.\n".utf8))
        return EvalExit.notBuilt
    }
}
