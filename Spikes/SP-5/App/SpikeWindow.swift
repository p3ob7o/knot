import SwiftUI

struct SpikeActions {
    var choose: () -> Void
    var askMicrophone: () -> Void
    var refresh: () -> Void
    var play: () -> Void
    var setMode: (MicrophoneMode) -> Void
    var setBehaviour: (PanelBehaviour) -> Void
    var startTap: () -> Void
    var stopTap: () -> Void
    var clear: () -> Void
}

/// The window the owner reads at the sitting. Every measurement is on screen; nothing needs
/// typing.
struct SpikeWindowView: View {
    @Bindable var model: SpikeModel
    let actions: SpikeActions

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("This app") {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        ForEach(model.environment, id: \.0) { row in
                            GridRow {
                                Text(row.0).foregroundStyle(.secondary)
                                Text(row.1)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    HStack {
                        Button("Ask for the microphone", action: actions.askMicrophone)
                        Button("Read again", action: actions.refresh)
                    }
                }

                GroupBox("The key") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.registration)
                        HStack {
                            Button(model.choosing ? "Press a key…" : "Choose a key", action: actions.choose)
                                .disabled(model.choosing)
                            if !model.chooserMessage.isEmpty { Text(model.chooserMessage).foregroundStyle(.secondary) }
                        }
                        if model.repeats > 0 {
                            Text("Repeated presses while held: \(model.repeats)").foregroundStyle(.orange)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Settings for the row you are on") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker(
                            "Microphone opens",
                            selection: Binding(get: { model.mode }, set: { actions.setMode($0) })
                        ) {
                            ForEach(MicrophoneMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        Picker(
                            "Panel",
                            selection: Binding(get: { model.behaviour }, set: { actions.setBehaviour($0) })
                        ) {
                            ForEach(PanelBehaviour.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        Picker("Key state stops a recording by", selection: $model.keySource) {
                            ForEach(KeyStateReader.Source.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        Toggle("Ignore the key's release (simulates a missed release)", isOn: $model.ignoreReleases)
                    }
                }

                GroupBox("Measurements") {
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent("Tap: release → panel ready (target 100 ms)", value: model.tapSummary)
                        LabeledContent("Hold: 250 ms mark → microphone live (target 150 ms)", value: model.holdSummary)
                        LabeledContent("Hold from key-down: key-down → live", value: model.keyDownSummary)
                        HStack {
                            Button("Play the last hold", action: actions.play).disabled(model.lastHold == nil)
                            Button("Clear", action: actions.clear)
                        }
                        Divider()
                        ForEach(model.records) { record in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.summary).font(.system(.callout, design: .monospaced))
                                if !record.keyPolls.isEmpty {
                                    Text(record.keyPolls.joined(separator: "  ·  "))
                                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Fallback: listen-only event tap (only if row 1 or 2 fails)") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(
                            "Asks for Input Monitoring. Status: \(model.tapStatus). Seen for the key: \(model.tapSeen)."
                        )
                        HStack {
                            Button("Start the event tap", action: actions.startTap)
                            Button("Stop it", action: actions.stopTap)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 640, minHeight: 600)
    }
}
