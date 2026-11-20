import Foundation
import KnotCore
import Testing

@testable import KnotExport

/// Finding 5: a full volume is told apart from any other failed write, in the form Foundation
/// gives it and in the form the system gives it.
@Suite struct WriteErrorTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let error: NSError
        let code: ErrorCode
        let posix: Int32?
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(
            name: "POSIX, no space", error: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)),
            code: KnotError.diskFull.code, posix: ENOSPC),
        Case(
            name: "Cocoa, out of space",
            error: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError),
            code: KnotError.diskFull.code, posix: nil),
        Case(
            name: "Cocoa, over POSIX no space",
            error: NSError(
                domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))]),
            code: KnotError.diskFull.code, posix: ENOSPC),
        Case(
            name: "POSIX, no permission", error: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)),
            code: KnotError.writeFailed.code, posix: EACCES),
        Case(
            name: "Cocoa, no permission, over POSIX",
            error: NSError(
                domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
                userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))]),
            code: KnotError.writeFailed.code, posix: EACCES),
    ]

    @Test(arguments: cases)
    func aFailedWriteIsMapped(_ example: Case) {
        let error = FolderExportSink.knotError(example.error)
        #expect(error.code == example.code)
        #expect(error.context.posixError == example.posix)
    }
}
