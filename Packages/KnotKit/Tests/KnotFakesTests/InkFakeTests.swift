import Foundation
import KnotCore
import KnotFakes
import KnotTestSupport
import Testing

@Suite struct ScriptedInkRecogniserTests {
    /// A drawing's bytes from the fixtures: any bytes are a drawing to the fake.
    static func fixtureDrawing() throws -> InkDrawingData {
        InkDrawingData(bytes: try Data(contentsOf: FixtureFiles.url("ink/line.json")))
    }

    @Test(.tags(.contract)) func theContract() async throws {
        try await InkRecogniserContract.run {
            let recogniser = ScriptedInkRecogniser()
            let words = try Self.fixtureDrawing()
            let other = InkDrawingData(bytes: try Data(contentsOf: FixtureFiles.url("ink/list.json")))
            let blank = InkDrawingData(bytes: Data("blank canvas".utf8))
            recogniser.script(words, text: "a line of words")
            recogniser.script(other, text: "milk eggs bread")
            recogniser.script(blank, text: "")
            return InkRecogniserSubject(
                recogniser: recogniser, words: words, wordsHold: ["line", "words"], other: other,
                otherHolds: ["milk", "eggs", "bread"], blank: blank,
                unreadable: InkDrawingData(bytes: Data("not a drawing".utf8)),
                language: Locale.Language(identifier: "en-GB"), unsupportedLanguage: Locale.Language(identifier: "ja"),
                setInForeground: { recogniser.setInForeground($0) })
        }
    }

    @Test(arguments: [KnotError.recognitionFailed, .appNotInForeground])
    func aScriptedFailureIsThrownOnce(error: KnotError) async throws {
        let recogniser = ScriptedInkRecogniser()
        let drawing = try Self.fixtureDrawing()
        recogniser.script(drawing, text: "words")
        recogniser.failNextRecognitions(with: error)
        let language = Locale.Language(identifier: "en")
        await #expect(throws: error) { try await recogniser.recognise(drawing, language: language) }
        #expect(try await recogniser.recognise(drawing, language: language).text == "words")
    }

    /// A recognition cancelled while it runs yields. Proved by what happens (findings 84 and 22):
    /// its scripted wait is an hour, longer than the suites' wait, so a recognition that missed
    /// the cancel would still be waiting when `SuiteWait` gives up, and the check would fail.
    @Test func aRecognitionCancelledWhileItRunsYields() async throws {
        let recogniser = ScriptedInkRecogniser()
        let drawing = try Self.fixtureDrawing()
        recogniser.script(drawing, text: "words")
        recogniser.setDelay(.seconds(3_600))
        let task = Task { try await recogniser.recognise(drawing, language: Locale.Language(identifier: "en")) }
        await SuiteWait.until("the recognition to begin") { recogniser.recognitionCount > 0 }
        task.cancel()
        let outcome = await SuiteWait.value("the cancelled recognition to return") { await task.result }
        #expect(throws: KnotError.cancelled) { try outcome?.get() }
    }

    @Test func anUnscriptedDrawingIsUnreadable() async {
        let recogniser = ScriptedInkRecogniser()
        await #expect(throws: KnotError.drawingUnreadable) {
            try await recogniser.recognise(
                InkDrawingData(bytes: Data("never scripted".utf8)), language: Locale.Language(identifier: "en"))
        }
    }
}

@Suite struct ScriptedDrawingImagesTests {
    @Test(.tags(.contract)) func theContract() async throws {
        let drawing = try ScriptedInkRecogniserTests.fixtureDrawing()
        let unreadable = InkDrawingData(bytes: Data("not a drawing".utf8))
        try await DrawingImagesContract.run(drawing: drawing, unreadable: unreadable) {
            let images = ScriptedDrawingImages()
            images.scriptUnreadable(unreadable)
            return images
        }
    }

    @Test func aScriptedImageIsGivenForItsDrawing() async throws {
        let images = ScriptedDrawingImages()
        let drawing = InkDrawingData(bytes: Data("strokes".utf8))
        let image = ScriptedDrawingImages.synthetic(scale: 3)
        images.script(drawing, image: image)
        #expect(try await images.image(of: drawing, scale: 2) == image)
        #expect(
            try await images.image(of: InkDrawingData(bytes: Data("other".utf8)), scale: 1).pixelWidth
                == ScriptedDrawingImages.pointSize.width)
        await #expect(throws: KnotError.drawingUnreadable) {
            try await images.image(of: InkDrawingData(bytes: Data()), scale: 1)
        }
    }
}
