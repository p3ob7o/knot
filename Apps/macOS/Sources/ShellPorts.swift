import AppKit
import KnotCore

@MainActor
final class MacSurfaceRouter: SurfaceRouter {
    private var navigate: ((SurfaceDestination) -> Void)?
    private var pending: [SurfaceDestination] = []

    func attach(_ navigate: @escaping (SurfaceDestination) -> Void) {
        self.navigate = navigate
        let destinations = pending
        pending.removeAll()
        for destination in destinations { navigate(destination) }
    }

    func open(_ destination: SurfaceDestination) async {
        if let navigate { navigate(destination) } else { pending.append(destination) }
    }

    static func destination(for url: URL, scheme: String) -> SurfaceDestination? {
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

/// Mac cues are the panel and the menu bar's visible states. The recorder owns cue timing.
@MainActor
final class MacCues: CueEmitter {
    var receive: ((Cue) -> Void)?

    nonisolated func emit(_ cue: Cue) {
        DispatchQueue.main.async { self.receive?(cue) }
    }
}
