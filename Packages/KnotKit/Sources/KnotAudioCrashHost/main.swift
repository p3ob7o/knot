import KnotAudio
import KnotCore

// KnotAudioCrashHost: a process that KnotAudio's kill tests start and kill
// (docs/architecture.md §17). The package that owns KnotAudio gives it its work and its
// kill points. Until then it reports that it is ready and exits.

print("KnotAudioCrashHost: ready")
