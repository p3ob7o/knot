import Foundation
import KnotCore
import Observation

/// Search: full text over titles, segment text and recognised handwriting. It filters the
/// stream as the person types (docs/product-spec.md §7). The store turns the text into a quoted
/// query, so query syntax is only text.
@MainActor
@Observable
public final class SearchViewModel {
    public private(set) var query = ""
    /// The matching notes in the order of the stream, or `nil` while the query is empty and the
    /// stream shows every note.
    public private(set) var results: [StreamRowModel]?
    public private(set) var problem: StoreProblem?

    public let limit: Int
    private let environment: AppEnvironment
    private let context: UIContext
    private var running: Task<Void, Never>?

    public init(environment: AppEnvironment, context: UIContext, limit: Int = 200) {
        self.environment = environment
        self.context = context
        self.limit = max(1, limit)
    }

    /// The search text changed. The search for the previous text, if it still runs, is dropped.
    public func setQuery(_ text: String) {
        query = text
        running?.cancel()
        running = Task { [weak self] in await self?.search(text) }
    }

    /// Waits for the search of the current text.
    public func settle() async {
        await running?.value
    }

    public func clear() {
        setQuery("")
    }

    private func search(_ text: String) async {
        guard !CaptureText.isEmpty(text) else {
            results = nil
            problem = nil
            return
        }
        do {
            let ids = try await environment.notes.search(text, limit: limit)
            let speech = await environment.transcriber.readiness()
            var rows: [StreamRowModel] = []
            for id in ids {
                guard let record = try await environment.notes.note(id) else { continue }
                rows.append(StreamRowModel(record, thisDevice: context.thisDevice, speech: speech))
            }
            // A newer query took over meanwhile: its own search sets the results.
            guard !Task.isCancelled, text == query else { return }
            results = rows
            problem = nil
        } catch {
            guard text == query else { return }
            problem = StoreProblem(error)
        }
    }
}
