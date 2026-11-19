import KnotCore
import KnotLink

// KnotLinkCrashHost: a process that KnotLink's kill tests start and kill
// (docs/architecture.md §17). The package that owns KnotLink gives it its work and its
// kill points. Until then it reports that it is ready and exits.

print("KnotLinkCrashHost: ready")
