import Foundation
import KnotCore
import KnotTestSupport
import Testing

@Suite struct ErrorCatalogTests {
    /// The entries of docs/errors.md, by code: each `### \`code\`` heading with its fields.
    static func documentedEntries() throws -> [String: [String: String]] {
        let text = try String(contentsOf: repositoryRoot().appending(path: "docs/errors.md"), encoding: .utf8)
        var entries: [String: [String: String]] = [:]
        var current: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("### `"), line.hasSuffix("`") {
                let code = String(line.dropFirst("### `".count).dropLast())
                current = code
                entries[code] = entries[code] ?? [:]
            } else if line.hasPrefix("#") {
                current = nil
            } else if let code = current, line.hasPrefix("- "), let colon = line.firstIndex(of: ":") {
                let name = String(line[line.index(line.startIndex, offsetBy: 2)..<colon])
                entries[code]?[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return entries
    }

    static func retryText(_ retry: RetryAdvice) -> String {
        guard retry.isSafe else { return "not safe" }
        switch retry.limit {
        case nil: return "safe, as often as needed"
        case 1: return "safe, once"
        case let limit?: return "safe, up to \(limit) times"
        }
    }

    @Test("error-case-lacks-code-or-docs-entry", .tags(.named))
    func everyCaseHasACodeAndAnEntry() throws {
        let entries = try Self.documentedEntries()
        var seen: Set<ErrorCode> = []
        for error in KnotError.catalog {
            let code = error.code.rawValue
            #expect(!code.isEmpty, "A case of the taxonomy lacks a code.")
            #expect(
                code.allSatisfy { $0.isLowercase || $0 == "_" } && !code.hasPrefix("_") && !code.hasSuffix("_"),
                "The code \(code) is not lower-case words joined by underscores.")
            #expect(seen.insert(error.code).inserted, "The code \(code) appears twice in the catalog.")
            guard let entry = entries[code] else {
                Issue.record("docs/errors.md has no entry for \(code).")
                continue
            }
            #expect(entry["Class"] == error.errorClass.rawValue, "\(code): the class in docs/errors.md differs.")
            #expect(entry["Next"] == error.next.rawValue, "\(code): the next action in docs/errors.md differs.")
            #expect(entry["Retry"] == Self.retryText(error.retry), "\(code): the retry in docs/errors.md differs.")
            #expect(entry["Written"] == error.written.rawValue, "\(code): what was written differs.")
            #expect(entry["Exit code"] == String(error.exitStatus.rawValue), "\(code): the exit code differs.")
        }
        let unknown = Set(entries.keys).subtracting(KnotError.catalog.map(\.code.rawValue))
        #expect(unknown.isEmpty, "docs/errors.md has entries for codes the catalog lacks: \(unknown.sorted()).")
    }

    /// Every code of a `KnotError` case declared anywhere in KnotKit's sources.
    static func declaredCodes() throws -> [String: String] {
        let sources = repositoryRoot().appending(path: "Packages/KnotKit/Sources")
        let pattern = try Regex(#"static\s+let\s+(\w+)\s*=\s*KnotError\(\s*code:\s*"([^"]*)""#)
        var codes: [String: String] = [:]
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
            guard file.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in text.matches(of: pattern) {
                let name = String(match.output[1].substring ?? "")
                codes[String(match.output[2].substring ?? "")] = "\(file.lastPathComponent): \(name)"
            }
        }
        return codes
    }

    @Test func everyCaseDeclaredIsInTheCatalog() throws {
        let declared = try Self.declaredCodes()
        #expect(
            Set(declared.keys) == Set(KnotError.catalog.map(\.code.rawValue)),
            "The declared cases and the catalog differ.")
        let missing = Set(declared.keys).subtracting(KnotError.catalog.map(\.code.rawValue))
        #expect(missing.isEmpty, "Cases left out of KnotError.catalog: \(missing.sorted().map { declared[$0]! })")
    }

    @Test func theTaxonomyNamesEveryFailureTheArchitectureFixes() {
        // docs/architecture.md §5, with the engineering review's three cases.
        let named: [KnotError] = [
            .diskFull, .storeBusy, .storeDamaged, .storeNewerThanBuild, .writeFailed, .microphonePermissionRefused,
            .noInputDevice, .audioSessionBusy, .tooLittleSpace, .conversionFailed, .speechModelNotInstalled,
            .audioUnreadable, .cleanupModelNotReady, .cleanupModelUnavailable, .cleanupDeclined, .recognitionFailed,
            .inboxItemUnreadable, .checksumMismatch, .syncSignedOut, .syncAccountChanged, .syncZoneRemoved,
            .syncMassDeletePaused, .textTooLong, .captureStoppedDiskFull, .cursorForeign, .speechUnavailable,
            .cleanupTimedOut, .transcriptionFailed, .systemResourcesLimited,
        ]
        for error in named { #expect(KnotError.catalog.contains(error)) }
    }

    @Test func deferralsFormAClassOfTheirOwn() {
        let deferrals = KnotError.catalog.filter(\.isDeferral).map(\.code)
        #expect(
            Set(deferrals)
                == Set(
                    [
                        KnotError.cleanupModelNotReady, .speechModelNotInstalled, .requestsLimited, .noBackgroundTime,
                        .deviceLocked, .systemResourcesLimited, .appNotInForeground, .linkNotReady, .counterpartMissing,
                        .counterpartFull, .syncTransient,
                    ].map(\.code)))
    }

    @Test func sixErrorsAreFinal() {
        // docs/architecture.md §4 and §5: no retry on this device can fix them, so the job
        // ends at once and is not tried again.
        #expect(
            Set(KnotError.catalog.filter(\.isFinal).map(\.code))
                == Set(
                    [
                        KnotError.speechUnavailable, .audioUnreadable, .cleanupModelUnavailable, .drawingUnreadable,
                        .handwritingLanguageUnsupported, .syncFinal,
                    ].map(\.code)))
        for error in KnotError.catalog where error.isFinal {
            #expect(!error.retry.isSafe, "\(error.code) is final, so no retry is offered.")
        }
        // A failed recognition is an attempt, with a retry.
        #expect(KnotError.recognitionFailed.errorClass == .failure)
        #expect(KnotError.recognitionFailed.retry.isSafe)
    }

    @Test func theCasesThatSection5NamesNow() {
        #expect(KnotError.cleanupTimedOut.errorClass == .failure)
        #expect(KnotError.systemResourcesLimited.isDeferral)
        #expect(KnotError.speechModelNotInstalled.isDeferral, "Not installed or still installing.")
        let details: [ErrorDetail] = [
            .cleanupRefused, .guardrailViolation, .cleanupEmpty, .cleanupMalformed, .guardRejected,
            .textTooLongForModel, .unsupportedLanguage, .unsupportedRequest,
        ]
        #expect(Set(details).count == 8)
        let limited = KnotError.requestsLimited.with(.init(retryAt: at("10:05")))
        #expect(limited.context.retryAt == at("10:05"), "The time to try again, when the system gives one.")
    }

    @Test func aThrownErrorMatchesItsCaseByCode() {
        let thrown = KnotError.diskFull.with(.init(captureID: id(1), posixError: 28))
        #expect(KnotError.diskFull ~= thrown)
        #expect(!(KnotError.writeFailed ~= thrown))
        #expect(KnotError.known(thrown.code)?.next == .freeSpace)
        #expect(KnotError.known("from_a_newer_knot") == nil)
        #expect(thrown.about(capture: id(2)).context.captureID == id(2))
    }

    @Test func anErrorRoundTripsThroughJSON() throws {
        let error = KnotError.cleanupDeclined.with(.init(segmentID: id(3), detail: .guardRejected))
        let data = try JSONEncoder().encode(error)
        #expect(try JSONDecoder().decode(KnotError.self, from: data) == error)
    }
}
