#if DEBUG || KNOT_FAKES
    import SwiftUI

    // Preview names follow the cells in docs/design/brief.md §6.

    #if !os(watchOS)
        #Preview("iPhone | Capture, empty") {
            CaptureMatrixPreview(surface: .phone, example: .blank)
        }

        #Preview("iPhone | Capture, typing") {
            CaptureMatrixPreview(surface: .phone, example: .typing)
        }

        #Preview("iPhone | Capture, adding to an open note; the window running out") {
            Group {
                CaptureMatrixPreview(surface: .phone, example: .adding)
                CaptureMatrixPreview(surface: .phone, example: .expired)
            }
        }

        #Preview("iPhone | Capture inside an older note") {
            CaptureMatrixPreview(surface: .phone, example: .older)
        }

        #Preview("iPhone | Recording, live") {
            CaptureMatrixPreview(surface: .phone, example: .live)
        }

        #Preview("iPhone | Recording, typing and Pencil not accepted") {
            CaptureMatrixPreview(surface: .phone, example: .blocked)
        }

        #Preview("iPhone | Just stopped: saved, with text arriving except on the Watch") {
            CaptureMatrixPreview(surface: .phone, example: .saved)
        }

        #Preview("iPhone | Short recording discarded") {
            CaptureMatrixPreview(surface: .phone, example: .discarded)
        }

        #Preview("iPhone | Stopped at the limit, or by a call") {
            RecordingMatrixPreview(surface: .phone, example: .limit)
        }

        #Preview("iPhone | Could not start, with the reason") {
            CaptureMatrixPreview(surface: .phone, example: .permission)
        }

        #Preview("iPhone | Text could not be saved") {
            CaptureMatrixPreview(surface: .phone, example: .saveFailure)
        }

        #Preview("iPhone | Stream, populated") {
            StreamMatrixPreview(surface: .phone, example: .populated)
        }

        #Preview("iPhone | Stream, first run") {
            StreamMatrixPreview(surface: .phone, example: .empty)
        }

        #Preview("iPhone | Stream, row with no text yet") {
            StreamMatrixPreview(surface: .phone, example: .noText)
        }

        #Preview("iPhone | Stream, rows pending and failed") {
            StreamMatrixPreview(surface: .phone, example: .pendingAndFailed)
        }

        #Preview("iPhone | Stream, captures arrived late") {
            StreamMatrixPreview(surface: .phone, example: .arrived)
        }

        #Preview("iPhone | Stream, first restore from iCloud") {
            StreamMatrixPreview(surface: .phone, example: .restoring)
        }

        #Preview("iPhone | Stream, notes could not be opened") {
            StreamMatrixPreview(surface: .phone, example: .unavailable)
        }

        #Preview("iPhone | Stream, largest text size") {
            StreamMatrixPreview(surface: .phone, example: .largest)
        }

        #Preview("iPhone | Search, results and none") {
            Group {
                StreamMatrixPreview(surface: .phone, example: .search, query: "roof")
                StreamMatrixPreview(surface: .phone, example: .search, query: "stapler")
            }
        }

        #Preview("iPhone | Note, mixed segments") {
            NoteMatrixPreview(surface: .phone, example: .mixed)
        }

        #Preview("iPhone | Note, title: none, generated, typed, editing") {
            Group {
                NoteMatrixPreview(surface: .phone, example: .titles)
                NoteMatrixPreview(surface: .phone, example: .titles, titleOrigin: .generated)
                NoteMatrixPreview(surface: .phone, example: .titles, titleOrigin: .user)
            }
        }

        #Preview("iPhone | Note, a segment being edited") {
            NoteMatrixPreview(surface: .phone, example: .editing)
        }

        #Preview("iPhone | Voice segment, each of its six states") {
            NoteMatrixPreview(surface: .phone, example: .voiceStates)
        }

        #Preview("iPhone | Voice segment: playing, show original, recording removed") {
            NoteMatrixPreview(surface: .phone, example: .playback)
        }

        #Preview("iPhone | Ink segment: shown, being recognised, failed, nothing recognised") {
            NoteMatrixPreview(surface: .phone, example: .ink)
        }

        #Preview("iPhone | Conflict copy") {
            NoteMatrixPreview(surface: .phone, example: .conflict)
        }

        #Preview("iPhone | Segment from the command line; from a newer Knot") {
            NoteMatrixPreview(surface: .phone, example: .marked)
        }

        #Preview("iPhone | Attachment waiting, downloading, unavailable") {
            NoteMatrixPreview(surface: .phone, example: .attachments)
        }

        #Preview("iPhone | Delete with undo; share") {
            NoteMatrixPreview(surface: .phone, example: .deleted)
        }

        #Preview("iPhone | A segment moved to its own note, with undo") {
            NoteMatrixPreview(surface: .phone, example: .moved)
        }

        #Preview("iPhone | Settings, the full list") {
            SettingsMatrixPreview(surface: .phone, example: .full)
        }

        #Preview("iPhone | Sync: off, syncing, error, storage full, no account") {
            SettingsMatrixPreview(surface: .phone, example: .sync)
        }

        #Preview("iPhone | Prompts: account changed; notes removed from iCloud") {
            SettingsMatrixPreview(surface: .phone, example: .prompts)
        }

        #Preview("iPhone | Export: in progress, done, with what it could not fetch") {
            SettingsMatrixPreview(surface: .phone, example: .export)
        }

        #Preview("iPhone | First run: microphone, model downloading, Action Button") {
            SettingsMatrixPreview(surface: .phone, example: .firstRun)
        }

    #endif

    #if !os(watchOS)
        #Preview("iPad | Capture, empty") {
            CaptureMatrixPreview(surface: .pad, example: .blank)
        }

        #Preview("iPad | Capture, adding to an open note; the window running out") {
            Group {
                CaptureMatrixPreview(surface: .pad, example: .adding)
                CaptureMatrixPreview(surface: .pad, example: .expired)
            }
        }

        #Preview("iPad | Recording, typing and Pencil not accepted") {
            CaptureMatrixPreview(surface: .pad, example: .blocked)
        }

        #Preview("iPad | Stream, populated") {
            StreamMatrixPreview(surface: .pad, example: .populated)
        }

        #Preview("iPad | Stream, largest text size") {
            StreamMatrixPreview(surface: .pad, example: .largest)
        }

        #Preview("iPad | Note, mixed segments") {
            NoteMatrixPreview(surface: .pad, example: .mixed)
        }

        #Preview("iPad | Ink segment: shown, being recognised, failed, nothing recognised") {
            NoteMatrixPreview(surface: .pad, example: .ink)
        }

        #Preview("iPad | Two columns do not fit; keyboard up") {
            // WP-30 owns the split view. Its compact capture detail uses the iPhone layout.
            CaptureMatrixPreview(surface: .phone, example: .blank)
        }

    #endif

    #if !os(watchOS)
        #Preview("Mac panel | Capture, empty") {
            CaptureMatrixPreview(surface: .panel, example: .blank)
        }

        #Preview("Mac panel | Capture, typing") {
            CaptureMatrixPreview(surface: .panel, example: .typing)
        }

        #Preview("Mac panel | Capture, adding to an open note; the window running out") {
            Group {
                CaptureMatrixPreview(surface: .panel, example: .adding)
                CaptureMatrixPreview(surface: .panel, example: .expired)
            }
        }

        #Preview("Mac panel | Recording, live") {
            CaptureMatrixPreview(surface: .panel, example: .live)
        }

        #Preview("Mac panel | Recording, before the microphone is live") {
            CaptureMatrixPreview(surface: .panel, example: .starting)
        }

        #Preview("Mac panel | Recording, continues a note or starts a new one") {
            Group {
                RecordingMatrixPreview(surface: .panel, example: .destination)
                RecordingMatrixPreview(surface: .panel, example: .newDestination)
            }
        }

        #Preview("Mac panel | Just stopped: saved, with text arriving except on the Watch") {
            CaptureMatrixPreview(surface: .panel, example: .saved)
        }

        #Preview("Mac panel | Stopped at the limit, or by a call") {
            RecordingMatrixPreview(surface: .panel, example: .limit)
        }

        #Preview("Mac panel | Could not start, with the reason") {
            CaptureMatrixPreview(surface: .panel, example: .permission)
        }

        #Preview("Mac panel | No microphone connected") {
            CaptureMatrixPreview(surface: .panel, example: .noMicrophone)
        }

        #Preview("Mac panel | Text could not be saved") {
            CaptureMatrixPreview(surface: .panel, example: .saveFailure)
        }

    #endif

    #if !os(watchOS)
        #Preview("Mac window | Capture inside an older note") {
            CaptureMatrixPreview(surface: .window, example: .older)
        }

        #Preview("Mac window | Stream, populated") {
            StreamMatrixPreview(surface: .window, example: .populated)
        }

        #Preview("Mac window | Stream, first run") {
            StreamMatrixPreview(surface: .window, example: .empty)
        }

        #Preview("Mac window | Stream, notes could not be opened") {
            StreamMatrixPreview(surface: .window, example: .unavailable)
        }

        #Preview("Mac window | Stream, largest text size") {
            StreamMatrixPreview(surface: .window, example: .largest)
        }

        #Preview("Mac window | Search, results and none") {
            Group {
                StreamMatrixPreview(surface: .window, example: .search, query: "roof")
                StreamMatrixPreview(surface: .window, example: .search, query: "stapler")
            }
        }

        #Preview("Mac window | Note, mixed segments") {
            NoteMatrixPreview(surface: .window, example: .mixed)
        }

        #Preview("Mac window | Note, a segment being edited") {
            NoteMatrixPreview(surface: .window, example: .editing)
        }

        #Preview("Mac window | Delete with undo; share") {
            NoteMatrixPreview(surface: .window, example: .deleted)
        }

        #Preview("Mac window | A segment moved to its own note, with undo") {
            NoteMatrixPreview(surface: .window, example: .moved)
        }

        #Preview("Mac window | Settings, the full list") {
            SettingsMatrixPreview(surface: .window, example: .full)
        }

        #Preview("Mac window | Two columns do not fit; keyboard up") {
            // WP-33 owns column collapse. This shows the shared capture page at compact width.
            CaptureMatrixPreview(surface: .phone, example: .blank)
        }

    #endif

    #if os(watchOS)
        #Preview("Watch | Recording, live") {
            WatchMatrixPreview(example: .live)
        }

        #Preview("Watch | Recording, continues a note or starts a new one") {
            Group {
                WatchMatrixPreview(example: .destination)
                WatchMatrixPreview(example: .newDestination)
            }
        }

        #Preview("Watch | Recording, display dimmed") {
            WatchMatrixPreview(example: .dimmed)
        }

        #Preview("Watch | Just stopped: saved, with text arriving except on the Watch") {
            WatchMatrixPreview(example: .saved)
        }

        #Preview("Watch | Short recording discarded") {
            WatchMatrixPreview(example: .discarded)
        }

        #Preview("Watch | Stopped at the limit, or by a call") {
            WatchMatrixPreview(example: .limit)
        }

        #Preview("Watch | Could not start, with the reason") {
            WatchMatrixPreview(example: .cannotStart)
        }

        #Preview("Watch | Storage nearly full") {
            WatchMatrixPreview(example: .nearlyFull)
        }

    #endif

#endif
