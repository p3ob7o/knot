import AppKit
import Carbon.HIToolbox
import CryptoKit
import KnotKit
import WebKit
import XCTest
@testable import Knot

final class NativeShellTests: XCTestCase {
    func test_T18_savedFramesRejectMalformedValuesAndClampWholeWindowToDisplay() throws {
        let suite = "KnotNativeShellTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["x": Double.nan, "y": 0.0, "w": 440.0, "h": 460.0], forKey: "knot.windowFrame")
        XCTAssertNil(WindowStateStore.savedFrame(in: defaults))

        let screen = NSRect(x: 0, y: 0, width: 1_200, height: 800)
        let clamped = WindowStateStore.constrainedFrame(
            NSRect(x: 1_199, y: -900, width: 700, height: 900),
            visibleFrames: [screen], fallback: screen
        )
        XCTAssertTrue(screen.contains(clamped))
        XCTAssertLessThanOrEqual(clamped.height, screen.height)
    }

    func test_T20_keyCodeZeroIsValidWithPrimaryModifierAndDisabledIsNil() throws {
        let suite = "KnotShortcutTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ansiA = Shortcut(keyCode: 0, ctrl: true)
        XCTAssertTrue(ansiA.isValid)
        XCTAssertTrue(ansiA.displayString.hasSuffix("A"))
        XCTAssertFalse(Shortcut(keyCode: 0, shift: true).isValid)
        ShortcutStore.save(ansiA, to: defaults)
        XCTAssertEqual(ShortcutStore.load(from: defaults), ansiA)
        ShortcutStore.save(nil, to: defaults)
        XCTAssertNil(ShortcutStore.load(from: defaults))

        let bare = Shortcut(keyCode: UInt32(kVK_ANSI_K))
        ShortcutStore.save(bare, to: defaults)
        XCTAssertEqual(ShortcutStore.load(from: defaults), bare)
        XCTAssertNil(ShortcutStore.loadEnabled(from: defaults))
        ShortcutStore.save(bare, approvingLegacyBare: true, to: defaults)
        XCTAssertEqual(ShortcutStore.loadEnabled(from: defaults), bare)

        let bareANSIKeyCodeZero = Shortcut(keyCode: 0)
        ShortcutStore.save(bareANSIKeyCodeZero, approvingLegacyBare: true, to: defaults)
        XCTAssertEqual(ShortcutStore.loadEnabled(from: defaults), bareANSIKeyCodeZero)
    }

    func test_T15_T17_largeCheckpointTransferRejectsReorderAndVerifiesHash() throws {
        let source = Data(String(repeating: "source line\n", count: 30_000).utf8)
        let hash = SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined()
        let transferID = UUID().uuidString
        let store = RichCheckpointTransferStore()
        XCTAssertNil(try store.accept(type: "checkpointBegin", payload: [
            "transferID": transferID, "baseRevision": 2, "nextRevision": 3,
            "totalBytes": source.count, "sha256": hash
        ]))
        let pieces = stride(from: 0, to: source.count, by: 176 * 1_024).map {
            Data(source[$0..<min($0 + 176 * 1_024, source.count)])
        }
        for (index, piece) in pieces.enumerated() {
            XCTAssertNil(try store.accept(type: "checkpointChunk", payload: [
                "transferID": transferID, "sequence": index,
                "dataBase64": piece.base64EncodedString()
            ]))
        }
        XCTAssertThrowsError(try store.accept(type: "checkpointEnd", payload: [
            "transferID": transferID, "sha256": hash
        ]))

        let valid = Data(#"{"baseRevision":2,"nextRevision":3,"markdown":"kept","blocksJSON":"[]","opaqueSourcesJSON":"[]","selectedRange":null,"assetIDs":[]}"#.utf8)
        let validHash = SHA256.hash(data: valid).map { String(format: "%02x", $0) }.joined()
        let validID = UUID().uuidString
        XCTAssertNil(try store.accept(type: "checkpointBegin", payload: [
            "transferID": validID, "baseRevision": 2, "nextRevision": 3,
            "totalBytes": valid.count, "sha256": validHash
        ]))
        XCTAssertNil(try store.accept(type: "checkpointChunk", payload: [
            "transferID": validID, "sequence": 0, "dataBase64": valid.base64EncodedString()
        ]))
        let payload = try XCTUnwrap(try store.accept(type: "checkpointEnd", payload: [
            "transferID": validID, "sha256": validHash
        ]))
        XCTAssertEqual(payload["markdown"] as? String, "kept")
    }

    func test_T15_nativeCheckpointJSONRejectsMalformedDeepAndOversizedShapes() throws {
        XCTAssertEqual(RichBridgeCoordinator.validJSONNodeCount(Data("{}".utf8)), 1)
        XCTAssertNil(RichBridgeCoordinator.validJSONNodeCount(Data("{bad".utf8)))

        let tooDeep = String(repeating: "[", count: 65) + "0" + String(repeating: "]", count: 65)
        XCTAssertNil(RichBridgeCoordinator.validJSONNodeCount(Data(tooDeep.utf8)))

        let atLimit = "[" + Array(repeating: "0", count: 19_999).joined(separator: ",") + "]"
        XCTAssertEqual(RichBridgeCoordinator.validJSONNodeCount(Data(atLimit.utf8)), 20_000)
        let overLimit = "[" + Array(repeating: "0", count: 20_000).joined(separator: ",") + "]"
        XCTAssertNil(RichBridgeCoordinator.validJSONNodeCount(Data(overLimit.utf8)))
    }

    func test_T25_bundleManifestHashesEveryProductionResource() throws {
        let manifest = try EditorBundleManifest.load()
        XCTAssertEqual(manifest.buildID, gutenbergEditorBuildID)
        XCTAssertEqual(manifest.entry, "index.html")
        XCTAssertGreaterThan(manifest.files.count, 1)
        for path in manifest.files.keys {
            let resource = try manifest.data(for: path)
            XCTAssertFalse(resource.0.isEmpty)
            XCTAssertEqual(resource.0.count, resource.1.bytes)
        }
        let index = try XCTUnwrap(String(data: manifest.data(for: manifest.entry).0, encoding: .utf8))
        XCTAssertTrue(index.contains("default-src"))
        XCTAssertTrue(index.contains("__KNOT_CSP_NONCE__"))
        XCTAssertFalse(index.contains("http://"))
        XCTAssertFalse(index.contains("https://"))
    }

    func test_T15_externalURLAllowlistRejectsPrivilegedAndMalformedSchemes() {
        XCTAssertEqual(RichBridgeCoordinator.permittedExternalURL("https://example.com/note")?.scheme, "https")
        XCTAssertEqual(RichBridgeCoordinator.permittedExternalURL("http://example.com")?.scheme, "http")
        XCTAssertEqual(RichBridgeCoordinator.permittedExternalURL("mailto:person@example.com")?.scheme, "mailto")
        XCTAssertNil(RichBridgeCoordinator.permittedExternalURL("javascript:alert(1)"))
        XCTAssertNil(RichBridgeCoordinator.permittedExternalURL("file:///etc/passwd"))
        XCTAssertNil(RichBridgeCoordinator.permittedExternalURL("knot-editor://bundle/index.html"))
        XCTAssertNil(RichBridgeCoordinator.permittedExternalURL("https:/missing-host"))
        XCTAssertNil(RichBridgeCoordinator.permittedExternalURL("mailto:"))
    }

}
