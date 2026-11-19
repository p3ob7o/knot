// The lint's fixture: each case below must be caught. scripts/self-test.sh runs the lint on
// this file as if it sat in the iOS widget extension, and checks that every "expect" line
// is answered by a finding of that rule on the case below it. This file is not compiled.

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
