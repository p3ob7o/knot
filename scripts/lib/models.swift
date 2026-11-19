// Prints whether the on-device models that the gate requires are on this Mac
// (docs/architecture.md §17): the speech model for English and the system language model.
// It opens no microphone and reads no recording.
//
//   xcrun swift scripts/lib/models.swift
//
// Output, one line each: `speech: available|unavailable`, `speech-english: <locales>|missing`,
// `cleanup: available|unavailable (<reason>)`, and `os: <build>`.

import Foundation
import FoundationModels
import Speech

print("speech: \(SpeechTranscriber.isAvailable ? "available" : "unavailable")")
let english = await SpeechTranscriber.installedLocales.filter { $0.language.languageCode?.identifier == "en" }
print("speech-english: \(english.isEmpty ? "missing" : english.map(\.identifier).sorted().joined(separator: ","))")
switch SystemLanguageModel.default.availability {
case .available:
    print("cleanup: available")
case .unavailable(let reason):
    print("cleanup: unavailable (\(reason))")
}
print("os: \(ProcessInfo.processInfo.operatingSystemVersionString)")
