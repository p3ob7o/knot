/// A stable error code, such as `disk_full` (docs/architecture.md §19).
///
/// Codes are values, not a closed list of cases: a code that a newer Knot wrote still reads,
/// and a later package adds a code without breaking a `switch`. A code never changes its
/// meaning. `docs/errors.md` has an entry for each code in `KnotError.catalog`.
public struct ErrorCode: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral,
    CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public var description: String { rawValue }

    /// True for the form every code has: lower-case ASCII letters, digits and underscores,
    /// starting with a letter, at most 64 characters. A code read from elsewhere, such as a
    /// file or a newer Knot, may not have it, and then it is never written to a log as it is.
    public var isWellFormed: Bool {
        let bytes = Array(rawValue.utf8)
        guard let first = bytes.first, (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(first), bytes.count <= 64
        else { return false }
        return bytes.allSatisfy { byte in
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || byte == UInt8(ascii: "_")
        }
    }
}

/// Whether an error is a failure, or a step that cannot run now (docs/architecture.md §4).
///
/// A failure counts as an attempt. A deferral is never counted: the work runs again when the
/// app comes forward or the model's availability changes.
public enum ErrorClass: String, Hashable, Sendable, Codable {
    case failure
    case deferral
}

/// What to do next. The command line, `--json`, MCP results and the app render it.
public enum NextAction: String, Hashable, Sendable, Codable {
    /// Nothing is needed: the outcome is final and not an error to fix.
    case none
    /// Try again now.
    case retry
    /// Try again a little later, unchanged.
    case waitAndRetry = "wait_and_retry"
    /// Free space on the device, then try again.
    case freeSpace = "free_space"
    /// Allow the microphone in the system's settings.
    case allowMicrophone = "allow_microphone"
    /// Connect a microphone.
    case connectMicrophone = "connect_microphone"
    /// Install a newer Knot.
    case updateKnot = "update_knot"
    /// Open Knot, which migrates or repairs what the tool cannot.
    case openKnot = "open_knot"
    /// The store needs its owner: follow the troubleshooting guide.
    case followTroubleshootingGuide = "follow_troubleshooting_guide"
    /// Wait for the on-device model to arrive. Knot finishes the work by itself.
    case waitForModel = "wait_for_model"
    /// Unlock the device. Knot finishes the work by itself.
    case unlockDevice = "unlock_device"
    /// Sign in to iCloud.
    case signInToICloud = "sign_in_to_icloud"
    /// Answer whether to upload the notes on this device.
    case answerUploadQuestion = "answer_upload_question"
    /// Read the note or segment again and use its current revision.
    case readAgain = "read_again"
    /// Read changes again from the start, without a cursor.
    case readFromStart = "read_from_start"
    /// Use a new capture ID for new content.
    case useNewCaptureID = "use_new_capture_id"
    /// Make the text shorter.
    case shortenText = "shorten_text"
    /// Choose another hotkey.
    case chooseAnotherKey = "choose_another_key"
    /// Turn on command-line access in Knot's Settings on this Mac.
    case turnOnCommandLineAccess = "turn_on_command_line_access"
    /// Give a full ID, or more of its last characters.
    case giveMoreOfTheID = "give_more_of_the_id"
    /// Wait for the capture to end in the app.
    case waitForCaptureToEnd = "wait_for_capture_to_end"
    /// Stop the recording before typing or drawing.
    case stopRecording = "stop_recording"
    /// Use the development build, `knot-dev`, and its own store.
    case useDevelopmentBuild = "use_development_build"
    /// Build the development app from its worktree, which names the worktree's store folder.
    case buildFromWorktree = "build_from_worktree"
    /// Reinstall Knot, whose installation lacks its shared container.
    case reinstallKnot = "reinstall_knot"
    /// Report the problem with its request ID.
    case reportProblem = "report_problem"
}

/// Whether a retry is safe and how often (docs/architecture.md §19).
public struct RetryAdvice: Hashable, Sendable, Codable {
    /// True when repeating the same call cannot do harm.
    public let isSafe: Bool
    /// How many times a retry is worth it. `nil` means as often as needed.
    public let limit: Int?

    public static let notSafe = RetryAdvice(isSafe: false, limit: 0)
    public static let safe = RetryAdvice(isSafe: true, limit: nil)

    public static func safe(times: Int) -> RetryAdvice {
        RetryAdvice(isSafe: true, limit: times)
    }
}

/// What was written before the error, so that nobody guesses (docs/architecture.md §19).
public enum WriteOutcome: String, Hashable, Sendable, Codable {
    /// Nothing changed.
    case nothing
    /// What was captured up to the failure is kept.
    case keptUpToFailure = "kept_up_to_failure"
    /// The content waits in `Inbox/` and is stored when the store answers.
    case keptInInbox = "kept_in_inbox"
    /// The recording, the drawing or the received file is kept with the segment.
    case contentKept = "content_kept"
    /// The step ended without changing the text; the text the segment shows stays.
    case textUnchanged = "text_unchanged"
    /// Not known: an unexpected failure.
    case unknown
}

/// The exit codes of the `knot` command (docs/product-spec.md §10).
public enum ExitStatus: Int32, Hashable, Sendable, Codable, CaseIterable {
    case done = 0
    case unexpected = 1
    case usage = 2
    case notFound = 3
    case accessOff = 4
    case conflict = 5
    case storeBusy = 6
    case needsOwner = 7
    case incomplete = 8
}

/// A detail that names which of several outcomes one code covers. It never holds note text.
public enum ErrorDetail: String, Hashable, Sendable, Codable {
    case cleanupRefused = "cleanup_refused"
    case cleanupEmpty = "cleanup_empty"
    case cleanupMalformed = "cleanup_malformed"
    case guardRejected = "guard_rejected"
}

/// The IDs and numbers an error is about. It holds IDs only, never text (docs/architecture.md §19).
public struct ErrorContext: Hashable, Sendable, Codable {
    public var captureID: CaptureID?
    public var noteID: NoteID?
    public var segmentID: SegmentID?
    public var assetID: AssetID?
    public var jobID: JobID?
    /// The POSIX error number of a failed file operation.
    public var posixError: Int32?
    public var detail: ErrorDetail?

    public init(
        captureID: CaptureID? = nil, noteID: NoteID? = nil, segmentID: SegmentID? = nil,
        assetID: AssetID? = nil, jobID: JobID? = nil, posixError: Int32? = nil, detail: ErrorDetail? = nil
    ) {
        self.captureID = captureID
        self.noteID = noteID
        self.segmentID = segmentID
        self.assetID = assetID
        self.jobID = jobID
        self.posixError = posixError
        self.detail = detail
    }

    public static let empty = ErrorContext()
}

/// The one error type of Knot's ports and rules (docs/architecture.md §5 and §19).
///
/// Every case of the taxonomy is a value in `KnotError.catalog`, and carries a stable code,
/// the next action, whether a retry is safe and how often, what was written, and the exit
/// code of the command line. A thrown error is a case with its context filled in. No port
/// throws anything else, and no error ever contains note text.
public struct KnotError: Error, Hashable, Sendable, Codable {
    public let code: ErrorCode
    public let errorClass: ErrorClass
    public let next: NextAction
    public let retry: RetryAdvice
    public let written: WriteOutcome
    public let exitStatus: ExitStatus
    public var context: ErrorContext

    public init(
        code: ErrorCode, errorClass: ErrorClass = .failure, next: NextAction, retry: RetryAdvice,
        written: WriteOutcome, exitStatus: ExitStatus, context: ErrorContext = .empty
    ) {
        self.code = code
        self.errorClass = errorClass
        self.next = next
        self.retry = retry
        self.written = written
        self.exitStatus = exitStatus
        self.context = context
    }

    /// True for a step that cannot run now, which is never counted as an attempt.
    public var isDeferral: Bool { errorClass == .deferral }

    /// The same case with its context.
    public func with(_ context: ErrorContext) -> KnotError {
        var copy = self
        copy.context = context
        return copy
    }

    /// The same case about one capture.
    public func about(capture: CaptureID) -> KnotError {
        var copy = self
        copy.context.captureID = capture
        return copy
    }

    /// The case in the catalog with this code, if this build knows it.
    public static func known(_ code: ErrorCode) -> KnotError? {
        catalog.first { $0.code == code }
    }

    /// Matches an error by its code, so that `case KnotError.diskFull:` reads a thrown error.
    public static func ~= (pattern: KnotError, value: KnotError) -> Bool {
        pattern.code == value.code
    }
}
