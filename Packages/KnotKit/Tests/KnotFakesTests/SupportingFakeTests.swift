import Foundation
import KnotCore
import KnotFakes
import KnotTestSupport
import Testing

@Suite struct SupportingFakeTests {
    @Test(.tags(.contract)) func theSurfaceRouterContract() async throws {
        let router = RecordingSurfaceRouter()
        try await SurfaceRouterContract.run(router) { router.destinations }
    }

    @Test(.tags(.contract)) func theCueEmitterContract() async throws {
        let emitter = RecordingCueEmitter()
        try await CueEmitterContract.run(emitter) { emitter.cues }
    }

    @Test(.tags(.contract)) func theFreeSpaceProbeContract() async throws {
        try await FreeSpaceProbeContract.run(FakeFreeSpaceProbe(), folder: URL(fileURLWithPath: "/work"))
        let full = FakeFreeSpaceProbe(bytes: 0)
        #expect(full.availableBytes(forVolumeAt: URL(fileURLWithPath: "/work")) == 0)
        full.setAvailable(nil)
        #expect(full.availableBytes(forVolumeAt: URL(fileURLWithPath: "/work")) == nil)
    }

    @Test(.tags(.contract)) func theInstallIdentityContract() async throws {
        try await InstallIdentityContract.run { FakeInstallIdentity() }
    }

    /// A store that arrives on another device meets another install ID.
    @Test func anotherDeviceHasAnotherInstallID() throws {
        let identity = FakeInstallIdentity()
        let here = try identity.installID()
        identity.moveToAnotherDevice()
        #expect(try identity.installID() != here)
        identity.failNextRead(with: .writeFailed)
        #expect(throws: KnotError.writeFailed) { try identity.installID() }
    }

    @Test(.tags(.contract)) func theProcessNotifierContract() async throws {
        let channel = FakeProcessChannel()
        try await ProcessNotifierContract.run(poster: channel.process(), listener: channel.process())
    }

    /// A lost notice is a hint that did not arrive: the next one does.
    @Test func aNoticeCanBeLost() async {
        let channel = FakeProcessChannel()
        let tool = channel.process()
        let app = channel.process()
        let heard = app.storeChanges()
        channel.loseNext(1)
        tool.postStoreChanged()
        tool.postStoreChanged()
        let count = await SuiteWait.value("the notice that was not lost") {
            var iterator = heard.makeAsyncIterator()
            return await iterator.next() != nil ? 1 : 0
        }
        #expect(count == 1)
    }

    @Test(.tags(.contract)) func theLifecycleContract() async throws {
        let lifecycle = FakeLifecycle()
        try await LifecycleContract.run(lifecycle) { lifecycle.send($0) }
    }
}
