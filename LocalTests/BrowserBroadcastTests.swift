// include: Textream/Textream/BrowserServer.swift
// include: Textream/Textream/SharedScrollProgress.swift
// extract: Textream/Textream/NotchSettings.swift NS ListeningMode
// Regression tests for the char count that BrowserServer broadcasts to the
// phone page. They compile the real BrowserServer class, call showContent
// with a shared reading position, and read the count the next broadcast
// sends (currentCharCount) in each listening mode. This catches a
// showContent that does not keep the shared position, a wrong mode check,
// and a broadcast that does not pass the shared word to phoneCharCount.
import Foundation

// Small stand-ins for the app types that BrowserServer.swift reads. The real
// ones need the whole app (speech, SwiftUI settings).
typealias ListeningMode = NS.ListeningMode
final class SpeechRecognizer {
    var recognizedCharCount = 0
    var audioLevels: [Float] = []
    var isListening = false
    var lastSpokenText = ""
}
struct ColorStub { var cssColor = "#ffffff" }
final class NotchSettings {
    static let shared = NotchSettings()
    var browserServerPort: UInt16 = 7373
    var listeningMode: ListeningMode = .classic
    var fontColorPreset = ColorStub()
    var cueColorPreset = ColorStub()
}

var fails = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  pass" : "  FAIL", name)
    if !ok { fails += 1 }
}

let words = ["a", "bb", "ccc", "dddd"]
let total = words.joined(separator: " ").count // 13
let speech = SpeechRecognizer()
speech.recognizedCharCount = 4
let shared = SharedScrollProgress()
let server = BrowserServer()
server.showContent(speechRecognizer: speech, words: words, totalCharCount: total,
                   hasNextPage: false, scrollProgress: shared)

func expected(_ p: Double) -> Int {
    ScrollProgressMath.charOffset(forWordProgress: p, words: words, totalCharCount: total)
}

for mode in [ListeningMode.classic, .silencePaused] {
    NotchSettings.shared.listeningMode = mode
    shared.wordProgress = 0
    check("\(mode.label): start of page", server.currentCharCount() == 0)
    // A late connect or a tap: the page shows the shared word, not char 0.
    shared.wordProgress = 2
    check("\(mode.label): shared word 2", server.currentCharCount() == expected(2) && expected(2) > 0)
    shared.wordProgress = 3.5
    check("\(mode.label): shared word 3.5", server.currentCharCount() == expected(3.5))
    // The mic count is not used in these modes.
    check("\(mode.label): mic count ignored", server.currentCharCount() != speech.recognizedCharCount)
}

NotchSettings.shared.listeningMode = .wordTracking
shared.wordProgress = 3
check("Word Tracking: follows the mic", server.currentCharCount() == 4)
speech.recognizedCharCount = 9
check("Word Tracking: mic moves the page", server.currentCharCount() == 9)

server.stop()

// The broadcast must send this count, not compute its own.
if let src = try? String(contentsOfFile: "Textream/Textream/BrowserServer.swift", encoding: .utf8),
   let a = src.range(of: "private func broadcastCurrentState()"),
   let b = src.range(of: "\n    }\n", range: a.upperBound..<src.endIndex) {
    let body = src[a.upperBound..<b.lowerBound]
    check("broadcast sends currentCharCount()", body.contains("currentCharCount()") && !body.contains("phoneCharCount("))
} else {
    check("broadcastCurrentState is in BrowserServer.swift", false)
}
if fails > 0 { print("\(fails) failed"); exit(1) }
