import Foundation
import KnotCore
import KnotTestSupport
import Testing

// Every transition of each state machine, and every illegal one: each table lists the legal
// transitions, and every other pair of a state and an event must be refused.

private let failure = KnotError.transcriptionFailed.code

@Suite struct TypedMachineTests {
    static let states = TypedState.allCases
    static let events: [TypedEvent] = [
        .end(isEmpty: false), .end(isEmpty: true), .recoverAtRelaunch(isEmpty: false),
        .recoverAtRelaunch(isEmpty: true), .saveFailed, .retrySaved,
    ]
    static let legal: [(TypedState, TypedEvent, TypedState)] = [
        (.draft, .saveFailed, .failed),
        (.failed, .retrySaved, .ready),
        (.draft, .end(isEmpty: false), .ready),
        (.draft, .end(isEmpty: true), .discarded),
        // Rule 12: a draft found after a crash becomes a finished typed segment at relaunch.
        (.draft, .recoverAtRelaunch(isEmpty: false), .ready),
        (.draft, .recoverAtRelaunch(isEmpty: true), .discarded),
    ]

    @Test func everyTransitionAndEveryIllegalOne() {
        for state in Self.states {
            for event in Self.events {
                let expected = Self.legal.first { $0.0 == state && $0.1 == event }?.2
                if let expected {
                    #expect((try? TypedMachine.reduce(state, event)) == expected, "\(state) + \(event)")
                } else {
                    #expect(throws: IllegalTransition(from: state, event: event)) {
                        try TypedMachine.reduce(state, event)
                    }
                }
            }
        }
    }
}

@Suite struct VoiceMachineTests {
    static let states: [VoiceState] = [
        .recording, .recovered, .recorded, .transcribing, .transcribed, .cleaning, .ready, .discarded, .onWatch,
        .delivered, .failed(.transcribe, failure), .failed(.clean, failure), .failed(.record, failure),
    ]
    static let events: [VoiceEvent] = [
        .stop, .discardAccidental, .killed, .recoveryFinished, .transferred, .ingested, .startTranscribing,
        .transcribed(hasWords: true), .transcribed(hasWords: false), .startCleaning, .keepRawTranscript, .cleaned,
        .deferred, .stepFailed(failure), .retry, .speechUnavailableHere, .audioUnreadable, .saveFailed(failure),
    ]
    static let legal: [(VoiceState, VoiceEvent, VoiceState)] = [
        (.recording, .stop, .recorded),
        (.recording, .discardAccidental, .discarded),
        (.recording, .killed, .recovered),
        (.recovered, .recoveryFinished, .recorded),
        (.onWatch, .transferred, .delivered),
        (.delivered, .ingested, .recorded),
        (.recorded, .startTranscribing, .transcribing),
        (.transcribing, .transcribed(hasWords: true), .transcribed),
        // A recording with no recognised words is ready with empty text.
        (.transcribing, .transcribed(hasWords: false), .ready),
        (.transcribing, .deferred, .recorded),
        // Final errors: speech unavailable here, and audio that cannot be read.
        (.transcribing, .speechUnavailableHere, .recorded),
        (.transcribing, .audioUnreadable, .ready),
        (.transcribing, .stepFailed(failure), .failed(.transcribe, failure)),
        (.transcribed, .startCleaning, .cleaning),
        // No model, or cleanup off: the raw transcript is the text.
        (.transcribed, .keepRawTranscript, .ready),
        (.cleaning, .cleaned, .ready),
        // A refusal, an empty or malformed result, or the guard's rejection.
        (.cleaning, .keepRawTranscript, .ready),
        (.cleaning, .deferred, .transcribed),
        (.cleaning, .stepFailed(failure), .failed(.clean, failure)),
        // A recording whose save failed keeps its audio, and a retry stores it.
        (.recording, .saveFailed(failure), .failed(.record, failure)),
        (.recovered, .saveFailed(failure), .failed(.record, failure)),
        (.failed(.record, failure), .retry, .recorded),
        (.failed(.transcribe, failure), .retry, .recorded),
        (.failed(.clean, failure), .retry, .transcribed),
    ]

    @Test func everyTransitionAndEveryIllegalOne() {
        for state in Self.states {
            for event in Self.events {
                let expected = Self.legal.first { $0.0 == state && $0.1 == event }?.2
                if let expected {
                    #expect((try? VoiceMachine.reduce(state, event)) == expected, "\(state) + \(event)")
                } else {
                    #expect(throws: IllegalTransition(from: state, event: event)) {
                        try VoiceMachine.reduce(state, event)
                    }
                }
            }
        }
    }

    @Test func aFailureNeverRemovesTheRecording() {
        // No transition leads from a kept recording to discarded: only the accidental press
        // of a recording still running does. Asked of the reducer, for every state and event.
        for state in Self.states {
            for event in Self.events where (try? VoiceMachine.reduce(state, event)) == .discarded {
                #expect(state == .recording && event == .discardAccidental, "\(state) + \(event) discards it.")
            }
        }
    }
}

@Suite struct InkMachineTests {
    static let code = KnotError.recognitionFailed.code
    static let states: [InkState] = [.drawing, .recognising, .ready, .discarded, .failed(code)]
    static let events: [InkEvent] = [
        .stroke, .end(isEmpty: false), .end(isEmpty: true), .recoverAtRelaunch(isEmpty: false),
        .recoverAtRelaunch(isEmpty: true), .recognised, .stepFailed(code), .retry, .saveFailed(code),
    ]
    static let legal: [(InkState, InkEvent, InkState)] = [
        (.drawing, .stroke, .drawing),
        (.drawing, .end(isEmpty: false), .recognising),
        (.drawing, .end(isEmpty: true), .discarded),
        // A drawing found at relaunch goes on to recognition.
        (.drawing, .recoverAtRelaunch(isEmpty: false), .recognising),
        (.drawing, .recoverAtRelaunch(isEmpty: true), .discarded),
        (.recognising, .recognised, .ready),
        (.recognising, .stepFailed(code), .failed(code)),
        (.drawing, .saveFailed(code), .failed(code)),
        (.failed(code), .retry, .recognising),
    ]

    @Test func everyTransitionAndEveryIllegalOne() {
        for state in Self.states {
            for event in Self.events {
                let expected = Self.legal.first { $0.0 == state && $0.1 == event }?.2
                if let expected {
                    #expect((try? InkMachine.reduce(state, event)) == expected, "\(state) + \(event)")
                } else {
                    #expect(throws: IllegalTransition(from: state, event: event)) {
                        try InkMachine.reduce(state, event)
                    }
                }
            }
        }
    }

    @Test("ink-reducer-rejects-ready-to-drawing", .tags(.named))
    func readyNeverGoesBackToDrawing() {
        // A stroke on a finished drawing is refused: writing more starts a new ink segment.
        #expect(throws: IllegalTransition(from: InkState.ready, event: InkEvent.stroke)) {
            try InkMachine.reduce(.ready, .stroke)
        }
        for event in Self.events {
            #expect((try? InkMachine.reduce(.ready, event)) != .drawing)
        }
        // Nothing but a drawing leads to drawing, asked of the reducer for every state and event.
        for state in Self.states {
            for event in Self.events where (try? InkMachine.reduce(state, event)) == .drawing {
                #expect(state == .drawing, "\(state) + \(event) reopens a drawing.")
            }
        }
    }
}

@Suite struct JobMachineTests {
    static func job(_ state: JobState, attempts: Int = 0, deaths: Int = 0) -> Job {
        Job(id: id(1), segmentID: id(2), kind: .transcribe, state: state, attempts: attempts, deaths: deaths)
    }

    static let attempt = KnotError.transcriptionFailed
    static let deferral = KnotError.cleanupModelNotReady

    @Test func attemptsAreCountedAndTheFifthFails() throws {
        var job = Self.job(.queued)
        for number in 1...4 {
            job = try JobMachine.reduce(job, .start)
            job = try JobMachine.reduce(job, .stepFailed(Self.attempt, retryAt: at("10:00")))
            #expect(job.state == .queued)
            #expect(job.attempts == number)
            #expect(job.notBefore == at("10:00"))
            #expect(job.lastErrorCode == Self.attempt.code)
        }
        job = try JobMachine.reduce(job, .start)
        #expect(job.notBefore == nil)
        job = try JobMachine.reduce(job, .stepFailed(Self.attempt, retryAt: at("10:00")))
        #expect(job.state == .failed(Self.attempt.code))
        #expect(job.attempts == JobMachine.maximumAttempts)
    }

    @Test func deferralsAreNeverCounted() throws {
        var job = Self.job(.queued)
        for _ in 1...20 {
            job = try JobMachine.reduce(job, .start)
            job = try JobMachine.reduce(job, .stepFailed(Self.deferral, retryAt: at("10:00")))
        }
        #expect(job.state == .queued)
        #expect(job.attempts == 0)
        #expect(job.deaths == 0)
        #expect(job.notBefore == nil, "A deferral runs again when the app comes forward, not at a time.")
    }

    @Test("job-found-running-at-launch-twice-rule", .tags(.named))
    func jobFoundRunningAtLaunchTwice() throws {
        var job = try JobMachine.reduce(Self.job(.queued), .start)
        job = try JobMachine.reduce(job, .foundRunningAtLaunch)
        #expect(job.state == .queued, "The first death sends the job back to the queue once.")
        #expect(job.deaths == 1)
        #expect(job.attempts == 0, "A death is not an attempt.")
        job = try JobMachine.reduce(job, .start)
        job = try JobMachine.reduce(job, .foundRunningAtLaunch)
        #expect(job.state == .failed(KnotError.jobDiedTwice.code))
        #expect(job.deaths == 2)
        #expect(job.lastErrorCode == KnotError.jobDiedTwice.code)
        // The segment offers a retry, which starts the count again.
        job = try JobMachine.reduce(job, .retry)
        #expect(job == Self.job(.queued).with(lastErrorCode: KnotError.jobDiedTwice.code))
    }

    @Test func success() throws {
        var job = try JobMachine.reduce(Self.job(.queued, attempts: 2), .start)
        job = try JobMachine.reduce(job, .succeeded)
        #expect(job.state == .done)
        #expect(job.lastErrorCode == nil)
    }

    @Test func everyIllegalTransitionIsRefused() {
        let states: [JobState] = [.queued, .running, .done, .failed(Self.attempt.code)]
        let events: [JobEvent] = [
            .start, .succeeded, .stepFailed(Self.attempt, retryAt: nil), .stepFailed(Self.deferral, retryAt: nil),
            .foundRunningAtLaunch, .retry, .yielded, .stepFailed(.audioUnreadable, retryAt: nil),
        ]
        let legal: [(JobState, JobEvent)] = [
            (.queued, .start), (.running, .succeeded), (.running, .stepFailed(Self.attempt, retryAt: nil)),
            (.running, .stepFailed(Self.deferral, retryAt: nil)), (.running, .foundRunningAtLaunch),
            (.running, .yielded), (.running, .stepFailed(.audioUnreadable, retryAt: nil)),
            (.failed(Self.attempt.code), .retry),
        ]
        for state in states {
            for event in events where !legal.contains(where: { $0.0 == state && $0.1 == event }) {
                #expect(throws: IllegalTransition(from: state, event: event)) {
                    try JobMachine.reduce(Self.job(state), event)
                }
            }
        }
    }
}

extension Job {
    fileprivate func with(lastErrorCode: ErrorCode?) -> Job {
        var copy = self
        copy.lastErrorCode = lastErrorCode
        return copy
    }
}

@Suite struct JobFinalAndYieldTests {
    static func running() -> Job {
        Job(id: id(1), segmentID: id(2), kind: .transcribe, state: .running)
    }

    @Test(arguments: [KnotError.audioUnreadable, .speechUnavailable, .cleanupModelUnavailable])
    func aFinalErrorEndsTheJobAtOnceAsDone(error: KnotError) throws {
        let job = try JobMachine.reduce(Self.running(), .stepFailed(error, retryAt: at("10:00")))
        #expect(job.state == .done, "\(error.code) is not tried again on this device.")
        #expect(job.lastErrorCode == error.code)
        #expect(job.attempts == 0)
        #expect(job.notBefore == nil)
    }

    @Test func aYieldIsNotCountedAndTheJobStaysQueued() throws {
        var job = Self.running()
        for _ in 1...10 {
            job = try JobMachine.reduce(job, .yielded)
            #expect(job.state == .queued)
            job = try JobMachine.reduce(job, .start)
        }
        #expect(job.attempts == 0)
        #expect(job.deaths == 0)
        #expect(job.lastErrorCode == nil, "A yield is not an error.")
        #expect(throws: IllegalTransition(from: JobState.queued, event: JobEvent.yielded)) {
            try JobMachine.reduce(Job(id: id(1), segmentID: id(2), kind: .transcribe), .yielded)
        }
    }

    @Test func aFailedRecognitionIsAnAttempt() throws {
        let job = try JobMachine.reduce(
            Job(id: id(1), segmentID: id(2), kind: .recognise, state: .running),
            .stepFailed(.recognitionFailed, retryAt: nil))
        #expect(job.state == .queued)
        #expect(job.attempts == 1)
    }
}

@Suite struct JobDeferralTimeAndDeclineTests {
    static func running(_ kind: JobKind = .clean) -> Job {
        Job(id: id(1), segmentID: id(2), kind: kind, state: .running)
    }

    @Test func aDeferralKeepsTheTimeTheSystemGives() throws {
        let limited = KnotError.requestsLimited.with(.init(retryAt: at("10:05")))
        let job = try JobMachine.reduce(Self.running(), .stepFailed(limited, retryAt: nil))
        #expect(job.state == .queued)
        #expect(job.notBefore == at("10:05"))
        #expect(job.attempts == 0)
    }

    @Test func aDeclineIsAResultAndEndsTheJobAtOnce() throws {
        let declined = KnotError.cleanupDeclined.with(.init(detail: .guardRejected))
        let job = try JobMachine.reduce(Self.running(), .stepFailed(declined, retryAt: at("10:00")))
        #expect(job.state == .done, "The segment is ready with the raw transcript as its text.")
        #expect(job.attempts == 0)
        #expect(job.lastErrorCode == KnotError.cleanupDeclined.code)
    }
}
