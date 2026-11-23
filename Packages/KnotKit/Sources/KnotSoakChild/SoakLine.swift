#if DEBUG || KNOT_FAKES
    import Foundation
    import KnotCore

    /// One line the child prints, and the parent reads with the same code: so the two never
    /// disagree on a line. Every field is an ID, an index, a number, a code, a name or a hash,
    /// never text. A line that does not parse is no line: the parent fails the run on it.
    enum SoakLine: Hashable, Sendable {
        /// The launch has opened its store.
        case launch(Int)
        /// Recovery has run, and finished this many captures.
        case recovered(Int)
        /// What recovery left of the launches before this one: rows still open, entries in
        /// `Inbox/`, and apart from them the temporaries of writes a kill cut before their rename
        /// (`DurableFile`'s `.<name>.<uuid>.partial`), which never held an item.
        case recoveryLeft(open: Int, inbox: Int, partials: Int)
        /// How many captures of the running launch recovery finished: none, for recovery finishes
        /// only captures of earlier launches.
        case recoveredOwn(Int)
        /// How many entries recovery left of earlier launches in `Recording/`: none, when it did its
        /// work, and apart from them the temporaries of cut peaks writes (`RecordingEntries`).
        case recordingLeft(others: Int, peaksTemporaries: Int)
        /// A temporary of a cut peaks write left in `Recording/`, by its name, which holds a
        /// capture ID.
        case peaksTemporary(String)
        /// A job of an earlier launch that this one found marked running before its queue
        /// resumed: a death the queue must count. Its capture, its kind and the deaths it had.
        case foundRunning(capture: CaptureID, kind: String, deaths: Int)
        /// A row of an earlier launch that recovery left open.
        case leftOpen(CaptureID)
        /// A temporary of a cut write that recovery left in `Inbox/` (`InboxEntries`), by its name,
        /// which holds a capture ID and a UUID.
        case inboxPartial(String)
        /// Capture `index` of the script is about to begin.
        case intent(Int)
        /// The engine answered a save as durable.
        case ack(Acknowledgement)
        /// The engine answered frames of a recording as durable: as begun, with none yet; as more
        /// of its audio is synced; or as it ended, with all of them.
        case ackAudio(AudioAcknowledgement)
        /// The script discards that capture now.
        case discarding(index: Int, capture: CaptureID)
        /// An engine call threw: nothing of it was acknowledged.
        case refused(index: Int, code: String)
        /// The child waits at this kill point to be killed.
        case stopped(String)
        /// An error a part logged: its category and its line of IDs and codes.
        case logged(String)
        /// The launch ran its part to the end, and exits.
        case done

        struct Acknowledgement: Hashable, Sendable {
            enum State: String, Sendable {
                case open, ended, discarded
            }

            let index: Int
            /// Which save of the script it answers: 0 the begin, then each update, then the end
            /// (`SoakScript.Capture.texts.count`).
            let save: Int
            let capture: CaptureID
            let revision: Int64
            /// The UTF-8 length and SHA-256 of the capture's whole text at that save.
            let bytes: Int
            let digest: String
            let state: State
            /// Whether that text is only spaces and line breaks.
            let blank: Bool
        }

        struct AudioAcknowledgement: Hashable, Sendable {
            let index: Int
            let capture: CaptureID
            /// The frames durable, as the engine's state said.
            let frames: Int64
            let state: Acknowledgement.State
        }

        var rendered: String {
            switch self {
            case .launch(let number): "launch \(number)"
            case .recovered(let count): "recovered \(count)"
            case .recoveryLeft(let open, let inbox, let partials): "recovery-left \(open) \(inbox) \(partials)"
            case .recoveredOwn(let count): "recovered-own \(count)"
            case .recordingLeft(let others, let temporaries): "recording-left \(others) \(temporaries)"
            case .peaksTemporary(let name): "peaks-temporary \(name)"
            case .foundRunning(let capture, let kind, let deaths): "found-running \(capture) \(kind) \(deaths)"
            case .leftOpen(let capture): "left-open \(capture)"
            case .inboxPartial(let name): "inbox-partial \(name)"
            case .intent(let index): "intent \(index)"
            case .ack(let a):
                "ack \(a.index) \(a.save) \(a.capture) \(a.revision) \(a.bytes) \(a.digest) \(a.state.rawValue) \(a.blank ? 1 : 0)"
            case .ackAudio(let a): "ack-audio \(a.index) \(a.capture) \(a.frames) \(a.state.rawValue)"
            case .discarding(let index, let capture): "discarding \(index) \(capture)"
            case .refused(let index, let code): "refused \(index) \(code)"
            case .stopped(let point): "stopped \(point)"
            case .logged(let line): "log " + line
            case .done: "done"
            }
        }

        static func parse(_ line: String) -> SoakLine? {
            let fields = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            func int(_ i: Int) -> Int? { fields.count > i ? Int(fields[i]).flatMap { $0 >= 0 ? $0 : nil } : nil }
            switch fields.first {
            case "launch": return fields.count == 2 ? int(1).map(SoakLine.launch) : nil
            case "recovered": return fields.count == 2 ? int(1).map(SoakLine.recovered) : nil
            case "recovery-left":
                guard fields.count == 4, let open = int(1), let inbox = int(2), let partials = int(3) else {
                    return nil
                }
                return .recoveryLeft(open: open, inbox: inbox, partials: partials)
            case "recovered-own": return fields.count == 2 ? int(1).map(SoakLine.recoveredOwn) : nil
            case "recording-left":
                guard fields.count == 3, let others = int(1), let temporaries = int(2) else { return nil }
                return .recordingLeft(others: others, peaksTemporaries: temporaries)
            case "peaks-temporary":
                guard fields.count == 2, fields[1].contains(".peaks.sb-"),
                    InboxEntries.capture(ofFile: fields[1]) != nil
                else { return nil }
                return .peaksTemporary(fields[1])
            case "found-running":
                guard fields.count == 4, let capture = CaptureID(fields[1]), !fields[2].isEmpty, let deaths = int(3)
                else { return nil }
                return .foundRunning(capture: capture, kind: fields[2], deaths: deaths)
            case "left-open": return fields.count == 2 ? CaptureID(fields[1]).map(SoakLine.leftOpen) : nil
            case "inbox-partial":
                guard fields.count == 2, InboxEntries.capture(ofPartial: fields[1]) != nil else { return nil }
                return .inboxPartial(fields[1])
            case "intent": return fields.count == 2 ? int(1).map(SoakLine.intent) : nil
            case "ack":
                guard fields.count == 9, let index = int(1), let save = int(2), let capture = CaptureID(fields[3]),
                    let revision = Int64(fields[4]), let bytes = int(5), fields[6].count == 64,
                    fields[6].allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
                    let state = Acknowledgement.State(rawValue: fields[7]), fields[8] == "0" || fields[8] == "1"
                else { return nil }
                return .ack(
                    Acknowledgement(
                        index: index, save: save, capture: capture, revision: revision, bytes: bytes,
                        digest: fields[6], state: state, blank: fields[8] == "1"))
            case "ack-audio":
                guard fields.count == 5, let index = int(1), let capture = CaptureID(fields[2]),
                    let frames = Int64(fields[3]), frames >= 0, let state = Acknowledgement.State(rawValue: fields[4])
                else { return nil }
                return .ackAudio(AudioAcknowledgement(index: index, capture: capture, frames: frames, state: state))
            case "discarding":
                guard fields.count == 3, let index = int(1), let capture = CaptureID(fields[2]) else { return nil }
                return .discarding(index: index, capture: capture)
            case "refused":
                guard fields.count == 3, let index = int(1), !fields[2].isEmpty else { return nil }
                return .refused(index: index, code: fields[2])
            case "stopped": return fields.count == 2 && !fields[1].isEmpty ? .stopped(fields[1]) : nil
            case "log": return fields.count >= 3 ? .logged(fields.dropFirst().joined(separator: " ")) : nil
            case "done": return fields.count == 1 ? .done : nil
            default: return nil
            }
        }
    }
#endif
