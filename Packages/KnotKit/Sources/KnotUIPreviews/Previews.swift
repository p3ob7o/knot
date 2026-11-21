#if DEBUG || KNOT_FAKES
    import KnotCore
    import KnotFakes
    import KnotUI
    import SwiftUI

    // The previews of WP-21's first pull request. Each runs on `.preview`, or on values built
    // from KnotFakes' builders. They assume no design direction: the theme is the placeholder.

    #Preview("Record button, every phase") {
        HStack(spacing: 24) {
            RecordButton(phase: .idle) {}
            RecordButton(phase: .starting) {}
            RecordButton(phase: .recording(KnotUIPreviews.environment.ids.make())) {}
            RecordButton(phase: .stopping) {}
        }
        .padding()
    }

    #Preview("Waveform") {
        WaveformView(levels: PreviewSamples.levels)
            .frame(height: 40)
            .padding()
    }

    #Preview("Markers") {
        HStack(spacing: 16) {
            PendingMarker()
            FailedMarker()
            ArrivedMarker()
        }
        .padding()
    }

    #if !os(watchOS)
        #Preview("Stream row, every part") {
            List {
                StreamRowView(PreviewSamples.busyRow)
                StreamRowView(PreviewSamples.recordingOnlyRow)
            }
        }

        #Preview("Stream row, largest text") {
            List {
                StreamRowView(PreviewSamples.busyRow)
            }
            .dynamicTypeSize(.accessibility5)
        }

        #Preview("Voice segment, six states") {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(PreviewSamples.voiceStates) { item in
                        SegmentView(item, handlers: .none)
                    }
                }
                .padding()
            }
        }

        #Preview("Segment marks") {
            VStack(alignment: .leading, spacing: 20) {
                SegmentView(PreviewSamples.fromAnAgent, handlers: .none)
                SegmentView(PreviewSamples.missingRecording, handlers: .none)
                SegmentView(PreviewSamples.newerKnot, handlers: .none)
            }
            .padding()
        }

        #Preview("Audio player") {
            AudioPlayerView(
                state: .playing(at: .seconds(12), of: .seconds(42)), length: .seconds(42), onToggle: {},
                onSeek: { _ in }
            )
            .padding()
        }

        #Preview("Search field") {
            SearchField(text: "roof") { _ in }
                .padding()
        }

        #Preview("Stream, first run") {
            let environment = KnotUIPreviews.environment
            StreamView(
                stream: StreamViewModel(
                    environment: environment, context: KnotUIPreviews.context(for: environment),
                    setupRows: [.actionButton, .lockScreenControl, .watchComplication]),
                search: SearchViewModel(environment: environment, context: KnotUIPreviews.context(for: environment)),
                open: { _ in })
        }

        #Preview("Stream, with notes") {
            let environment = KnotUIPreviews.environment
            StreamView(
                stream: StreamViewModel(environment: environment, context: KnotUIPreviews.context(for: environment)),
                search: SearchViewModel(environment: environment, context: KnotUIPreviews.context(for: environment)),
                open: { _ in }
            )
            .task { await KnotUIPreviews.seed(environment) }
        }

        #Preview("Capture surface") {
            let environment = KnotUIPreviews.environment
            NoteView(
                model: NoteViewModel(
                    environment: environment, context: KnotUIPreviews.context(for: environment),
                    announcer: RecordingAnnouncer()),
                player: PlayerViewModel(player: environment.player))
        }

        #Preview("Settings, iPhone with Live Activities off") {
            let environment = KnotUIPreviews.environment
            SettingsForm(
                SettingsViewModel(
                    environment: environment, context: KnotUIPreviews.context(for: environment), platform: .iPhone,
                    liveActivitiesEnabled: false))
        }
    #endif
#endif
