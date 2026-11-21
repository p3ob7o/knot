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
        /// Capture `index` of the script is about to begin.
        case intent(Int)
        /// The engine answered a save as durable.
        case ack(Acknowledgement)
        /// The script discards that capture now.
        case discarding(index: Int, capture: CaptureID)
        /// An engine call threw: nothing of it was acknowledged.
        case refused(index: Int, code: String)
        /// The child waits at this kill point to be killed.
        case stopped(String)
        /// An error a part logged: its category and its line of IDs and codes.
        case log(String)
        /// The launch ran its part to the end, and exits.
        case done

        struct Acknowledgement: Hashable, Sendable {
            enum State: String, Sendable {
                case open, ended, discarded
            }

            let index: Int
            let capture: CaptureID
            let revision: Int64
            /// The UTF-8 length and SHA-256 of the capture's whole text at that save.
            let bytes: Int
            let digest: String
            let state: State
            /// Whether that text is only spaces and line breaks.
            let blank: Bool
        }

        var rendered: String {
            switch self {
            case .launch(let number): "launch \(number)"
            case .recovered(let count): "recovered \(count)"
            case .intent(let index): "intent \(index)"
            case .ack(let a):
                "ack \(a.index) \(a.capture) \(a.revision) \(a.bytes) \(a.digest) \(a.state.rawValue) \(a.blank ? 1 : 0)"
            case .discarding(let index, let capture): "discarding \(index) \(capture)"
            case .refused(let index, let code): "refused \(index) \(code)"
            case .stopped(let point): "stopped \(point)"
            case .log(let line): "log \(line)"
            case .done: "done"
            }
        }

        static func parse(_ line: String) -> SoakLine? {
            let fields = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            func int(_ i: Int) -> Int? { fields.count > i ? Int(fields[i]).flatMap { $0 >= 0 ? $0 : nil } : nil }
            switch fields.first {
            case "launch": return fields.count == 2 ? int(1).map(SoakLine.launch) : nil
            case "recovered": return fields.count == 2 ? int(1).map(SoakLine.recovered) : nil
            case "intent": return fields.count == 2 ? int(1).map(SoakLine.intent) : nil
            case "ack":
                guard fields.count == 8, let index = int(1), let capture = CaptureID(fields[2]),
                    let revision = Int64(fields[3]), let bytes = int(4), fields[5].count == 64,
                    fields[5].allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
                    let state = Acknowledgement.State(rawValue: fields[6]), fields[7] == "0" || fields[7] == "1"
                else { return nil }
                return .ack(
                    Acknowledgement(
                        index: index, capture: capture, revision: revision, bytes: bytes, digest: fields[5],
                        state: state, blank: fields[7] == "1"))
            case "discarding":
                guard fields.count == 3, let index = int(1), let capture = CaptureID(fields[2]) else { return nil }
                return .discarding(index: index, capture: capture)
            case "refused":
                guard fields.count == 3, let index = int(1), !fields[2].isEmpty else { return nil }
                return .refused(index: index, code: fields[2])
            case "stopped": return fields.count == 2 && !fields[1].isEmpty ? .stopped(fields[1]) : nil
            case "log": return fields.count >= 3 ? .log(fields.dropFirst().joined(separator: " ")) : nil
            case "done": return fields.count == 1 ? .done : nil
            default: return nil
            }
        }
    }
#endif
