import GRDB
import KnotCore
import KnotStore

// KnotStoreCrashHost: a process that KnotStore's kill tests start and kill
// (docs/architecture.md §17). The package that owns KnotStore gives it its work and its
// kill points. Until then it reports that it is ready and exits.

print("KnotStoreCrashHost: ready")
