import KnotCore
import KnotInk

// KnotInkCrashHost: a process that KnotInk's kill tests start and kill
// (docs/architecture.md §17). The package that owns KnotInk gives it its work and its
// kill points. Until then it reports that it is ready and exits.

print("KnotInkCrashHost: ready")
