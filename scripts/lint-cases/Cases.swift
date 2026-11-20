// The lint's fixture. scripts/self-test.sh runs the lint on this file as if it sat in the iOS
// widget extension. Every "expect: <rule>" line must be answered by a finding of that rule
// on the line below it, and an "expect: nothing" line by no finding there. This file is not
// compiled.

// expect: logged-text
Logger.store.info("saved \(note.text)")
// expect: logged-text
storeLogger.error("could not save \(error)")
// expect: logged-text
logger.notice("capture \(captureID, privacy: .public) holds \(note.text)")
// expect: logged-text
logger.debug(
    "stored \(segment.text)"
)
// expect: logged-text
os_log("saved %@", log: .default, type: .info, text)
// expect: logged-text
logger.info("capture \(captureID, privacy: .public): \(note.text, privacy: .public)")
// expect: standard-defaults
let defaults: UserDefaults = .standard
// expect: required-reason
let created = try url.resourceValues(forKeys: [.creationDateKey])
// expect: required-reason
let changed = try url.resourceValues(forKeys: [.attributeModificationDateKey])
// expect: required-reason
let result = fstat(descriptor, &info)
// expect: network
let listener = try NWListener(using: .tcp)
// expect: standard-defaults
let optionalDefaults: UserDefaults? = .standard
// expect: standard-defaults
@AppStorage("window", store: .standard) var window = ""
// expect: standard-defaults
ContentView().defaultAppStorage(.standard)
// expect: required-reason
let status = fstatat(directory, name, &info, 0)
// expect: required-reason
let count = getattrlistbulk(descriptor, &list, &buffer, size, 0)
// expect: required-reason
let space = fstatfs(descriptor, &volume)
// expect: logged-text
dump(note)
// expect: logged-text
Swift.print(note.text)
// A parenthesis inside a string literal does not join the lines after it into one statement,
// so a finding names its own line.
// expect: nothing
let opening = "("
// expect: logged-text
logger.info("saved \(note.text)")

// The lines below must pass: an ID and a formatted duration shown as public, and a line that
// the escape marker lets through.
// expect: nothing
logger.info("opened \(note.id.uuidString, privacy: .public)")
// expect: nothing
logger.info("took \(elapsed.formatted(), privacy: .public)")
// expect: nothing
logger.info("\(line, privacy: .public)")  // knot-lint: allow logged-text: the system sink logs a finished line
// expect: fake-unguarded
struct FakeTransport {}
#if DEBUG || KNOT_FAKES
    // expect: nothing
    struct FakeGuardedTransport {}
#else
    // expect: fake-unguarded
    struct FakeInTheElseBranch {}
#endif
#if KNOT_FAKES || DEBUG
    // expect: nothing
    final class FakeOtherOrder {}
#endif
#if !KNOT_FAKES
    // expect: fake-unguarded
    enum FakeBehindNot {}
#endif
