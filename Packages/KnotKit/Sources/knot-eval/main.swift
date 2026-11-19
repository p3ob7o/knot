import Foundation
import KnotCleanup
import KnotCore
import KnotSpeech

// `knot-eval`: two local commands that score speech and cleanup, on the committed synthetic
// fixtures (`--set synthetic`) or on the owner's recordings in the folder that
// KNOT_LOCAL_FIXTURES names (`--set local`). They print numbers only. WP-13 and WP-14
// build them. Until then the tool exits at once with a usage error. It never waits.

FileHandle.standardError.write(Data("knot-eval: not built yet. WP-13 and WP-14 build it.\n".utf8))
exit(2)
