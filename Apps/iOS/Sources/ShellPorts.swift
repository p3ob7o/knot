import Foundation
import KnotCore
import Observation
import SwiftUI

/// Open intents and URLs use the same navigation request. An intent can arrive before
/// SwiftUI has attached the window.
@MainActor
final class IOSSurfaceRouter: SurfaceRouter {
    private var pending: [SurfaceDestination] = []
    private var navigate: ((SurfaceDestination) async -> Void)?

    func takePending() -> SurfaceDestination? {
        pending.isEmpty ? nil : pending.removeFirst()
    }

    func attach(_ navigate: @escaping (SurfaceDestination) async -> Void) async {
        self.navigate = navigate
        while let destination = takePending() {
            await navigate(destination)
        }
    }

    func open(_ destination: SurfaceDestination) async {
        if let navigate { await navigate(destination) } else { pending.append(destination) }
    }
}

enum IOSDeepLink {
    static func destination(_ url: URL, scheme: String) -> SurfaceDestination? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
            parts.scheme?.lowercased() == scheme, parts.user == nil, parts.password == nil,
            parts.port == nil, parts.query == nil, parts.fragment == nil
        else { return nil }
        switch parts.host?.lowercased() {
        case "capture" where parts.path.isEmpty: return .capture
        case "search" where parts.path.isEmpty: return .search
        case "note":
            guard parts.path.hasPrefix("/"), let uuid = UUID(uuidString: String(parts.path.dropFirst())) else {
                return nil
            }
            return .note(NoteID(uuid: uuid))
        default: return nil
        }
    }
}

/// The recorder and its caller decide when to give each cue. The shell draws the system haptic.
@MainActor
@Observable
final class IOSCueEmitter: CueEmitter {
    struct Pulse: Equatable {
        let id = UUID()
        let cue: Cue

        var feedback: SensoryFeedback {
            switch cue {
            case .recordingLive: .start
            case .saved, .stoppedEarly: .stop
            case .discarded: .warning
            case .couldNotStart: .error
            }
        }
    }

    private(set) var pulse: Pulse?
    @ObservationIgnored private var queued: [Pulse] = []
    @ObservationIgnored private var acknowledged: UUID?

    nonisolated func emit(_ cue: Cue) {
        DispatchQueue.main.async {
            self.queued.append(Pulse(cue: cue))
            self.presentNextPulse()
        }
    }

    /// SwiftUI calls this for each trigger change. Advance on the next main-queue turn so
    /// consecutive emissions cannot replace each other in the same render.
    func feedback(for pulse: Pulse?) -> SensoryFeedback? {
        guard let pulse, self.pulse?.id == pulse.id, acknowledged != pulse.id else { return nil }
        acknowledged = pulse.id
        DispatchQueue.main.async {
            self.pulse = nil
            self.presentNextPulse()
        }
        return pulse.feedback
    }

    private func presentNextPulse() {
        if pulse == nil, !queued.isEmpty { pulse = queued.removeFirst() }
    }
}
