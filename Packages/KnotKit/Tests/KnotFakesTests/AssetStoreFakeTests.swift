import Foundation
import KnotCore
import KnotFakes
import KnotTestSupport
import Synchronization
import Testing

/// A file asset store on the power-cut layer, with a scratch folder beside the store.
func fileAssetStore() throws -> (FileAssetStore, PowerCutFileLayer, StoreLocations) {
    let layer = PowerCutFileLayer()
    for path in ["/work", "/scratch"] {
        try layer.createFolder(URL(fileURLWithPath: path, isDirectory: true))
    }
    try layer.syncFolder(URL(fileURLWithPath: "/", isDirectory: true))
    let locations = StoreLocations.testing(root: URL(fileURLWithPath: "/work", isDirectory: true))
    return (FileAssetStore(locations: locations, layer: layer), layer, locations)
}

@Suite struct FileAssetStoreTests {
    @Test(.tags(.contract)) func theContract() async throws {
        try await AssetStoreContract.run {
            let (store, layer, locations) = try fileAssetStore()
            let count = Mutex(0)
            return AssetStoreSubject(
                store: store, locations: locations,
                writeScratch: { data in
                    let number = count.withLock { value in
                        value += 1
                        return value
                    }
                    let url = URL(fileURLWithPath: "/scratch/\(number).tmp")
                    try layer.write(data, to: url)
                    return url
                },
                exists: { layer.exists($0) })
        }
    }

    /// A power cut after any write of a placement leaves the file whole or absent, and once
    /// `place` returned, so that a row may point to it, the file is whole.
    @Test func aPowerCutAtAnyPointLeavesTheFileWholeOrAbsent() async throws {
        let asset: AssetID = Identifier(uuid: UUID())
        let data = Data(repeating: 7, count: 4_096)
        let (probe, probeLayer, _) = try fileAssetStore()
        let start = probeLayer.operationCount
        _ = try await probe.place(data, as: asset, kind: .audio)
        let steps = probeLayer.operationCount - start
        #expect(steps > 3)
        for cut in 0...steps {
            let (store, layer, locations) = try fileAssetStore()
            layer.die(afterOperations: cut)
            var returned = false
            do {
                _ = try await store.place(data, as: asset, kind: .audio)
                returned = true
            } catch {}
            layer.cutPower()
            let url = locations.asset(asset, kind: .audio)
            if returned {
                #expect(try layer.read(url) == data, "Cut after \(cut): a placement that returned is on the drive.")
            } else if layer.exists(url) {
                #expect(try layer.read(url) == data, "Cut after \(cut): the file is whole or absent.")
            }
        }
    }

    @Test func aFullDiskLeavesNothingAndSaysSo() async throws {
        let (store, layer, locations) = try fileAssetStore()
        let asset: AssetID = Identifier(uuid: UUID())
        layer.failNextWrite(with: KnotError.diskFull)
        await #expect(throws: KnotError.diskFull) { try await store.place(Data("x".utf8), as: asset, kind: .audio) }
        #expect(!layer.exists(locations.asset(asset, kind: .audio)))
        #expect(try await store.find(asset, kind: .audio) == nil)
    }
}
