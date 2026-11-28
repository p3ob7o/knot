#if DEBUG
    import Foundation
    import KnotCore

    extension Shell {
        // The optional operand belongs to the existing debug-only launch argument.
        private var previewScenario: String? {
            guard composition.live == nil else { return nil }
            let arguments = ProcessInfo.processInfo.arguments
            guard let flag = arguments.firstIndex(of: "-KnotPreview"), arguments.indices.contains(flag + 1)
            else { return nil }
            return arguments[flag + 1]
        }

        var debugDropTarget: Bool { previewScenario == "drag" }
        var debugFocusProbe: Bool { previewScenario == "capture-focus" }

        func runPreviewScenario() async {
            guard composition.live == nil, !ranPreviewScenario else { return }
            ranPreviewScenario = true
            let scenario = previewScenario
            let now = environment.clock.now()

            if scenario == "done" {
                capture.fieldChanged("A synthetic line completed by Done")
                done()
                await capture.settle()
                if capture.typedCapture == nil, capture.fieldText.isEmpty, capture.problem == nil,
                    let id = capture.noteID, let note = try? await environment.notes.note(id),
                    note.liveSegments.contains(where: {
                        $0.text == "A synthetic line completed by Done" && $0.endedAt != nil
                    })
                {
                    previewAction = "Capture finished"
                }
            } else if scenario == "late-capture" {
                let past = now.addingTimeInterval(-3600)
                _ = try? await seedLine(
                    "A synthetic late arrival", at: past, placement: .newNote,
                    arrival: .late, device: environment.ids.make())
            } else if scenario == "move" || scenario == "undo-move" {
                guard let first = try? await seedLine("The first synthetic segment", at: now, placement: .newNote),
                    let second = try? await seedLine(
                        "The moved synthetic segment", at: now.addingTimeInterval(1), placement: .named(first.noteID))
                else { return }
                guard await openNoteAfterSaving(first.noteID), let note = openNote else { return }
                await note.refresh()
                guard let id = second.segmentIDs.first else { return }
                note.moveToOwnNote(id)
                await note.settle()
                if scenario == "undo-move" {
                    guard let moved = try? await environment.notes.segment(id), moved.noteID != first.noteID else {
                        return
                    }
                    note.undo()
                    await note.settle()
                    guard let restored = try? await environment.notes.segment(id), restored.noteID == first.noteID,
                        let follow = try? await seedLine(
                            "The next synthetic capture", at: now.addingTimeInterval(2), placement: .window),
                        follow.noteID == first.noteID
                    else { return }
                    previewAction = "Move undone"
                }
            } else if debugDropTarget,
                let receipt = try? await seedLine("A synthetic note to drag", at: now, placement: .newNote)
            {
                await openNoteAfterSaving(receipt.noteID)
            }
        }

        private func seedLine(
            _ text: String, at date: Date, placement: CapturePlacement,
            arrival: Arrival = .live, device: DeviceID? = nil
        ) async throws(KnotError) -> CaptureReceipt {
            try await environment.notes.record(
                NewCapture(
                    id: environment.ids.make(), kind: .typed,
                    origin: CaptureOrigin(
                        source: .device(device ?? composition.context.thisDevice), surface: .macWindow),
                    launchID: environment.ids.make(), placement: placement, arrival: arrival,
                    startedAt: date, endedAt: date, body: .text(text)))
        }
    }
#endif
