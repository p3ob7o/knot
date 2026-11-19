import KnotAudio
import KnotCapture
import KnotCore
import KnotFakes
import KnotStore

// KnotSoakChild: the child process of the capture ledger soak (docs/architecture.md §17).
// The parent starts it over the real store, kills it at points the seed chooses and
// relaunches it. WP-06 builds it. Until then it reports that it is ready and exits.

print("KnotSoakChild: ready")
