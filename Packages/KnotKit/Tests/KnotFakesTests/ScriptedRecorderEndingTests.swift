import Foundation
import KnotCore
import KnotTestSupport
import Testing

@testable import KnotFakes

/// The scripted recorder reads an orphan's ending from its manifest by the port's rule, as the
/// live recorder does, case by case: a reason this build does not know reads as `stopped`, as
/// ruled (pull request 128).
@Suite struct ScriptedRecorderEndingTests {
    @Test func anOrphansEndingIsTheManifests() {
        for check in OrphanEndingCases.all {
            #expect(ScriptedRecorder.ending(of: check.manifest) == check.ending, "\(check.why)")
        }
    }
}
