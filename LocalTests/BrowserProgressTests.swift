// include: Textream/Textream/SharedScrollProgress.swift
// extract: Textream/Textream/BrowserServer.swift BrowserServer phoneCharCount
// Regression tests for the phone page position (BrowserServer.phoneCharCount).
// In Classic and Voice-Activated the page shows the Mac's shared reading
// position and has no clock of its own, so it stops on Pause, follows taps
// and scrolls, and a phone that connects late opens on the current word.
import Foundation

var fails = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  pass" : "  FAIL", name)
    if !ok { fails += 1 }
}

let words = ["a", "bb", "ccc"]
let total = words.joined(separator: " ").count // 8

func phone(_ s: SharedScrollProgress, wordTracking: Bool = false, recognized: Int = 0) -> Int {
    BrowserServer.phoneCharCount(
        isWordTracking: wordTracking,
        recognizedCharCount: recognized,
        sharedWordProgress: s.wordProgress,
        words: words,
        totalCharCount: total
    )
}

// Word Tracking follows the mic, not the shared position.
var s = SharedScrollProgress()
s.wordProgress = 2
check("word tracking: recognized count", phone(s, wordTracking: true, recognized: 5) == 5)
check("word tracking: shared position ignored", phone(s, wordTracking: true, recognized: 0) == 0)

// Classic and Voice-Activated: the same char offset as the Mac screens.
s = SharedScrollProgress()
check("smooth: start of page", phone(s) == 0)
for p in [0.0, 0.5, 1.0, 1.5, 2.25, 3.0, 5.0] {
    s.wordProgress = p
    check("smooth: matches the Mac at word \(p)",
          phone(s) == ScrollProgressMath.charOffset(forWordProgress: p, words: words, totalCharCount: total))
}
s.wordProgress = 99
check("smooth: clamps at the end", phone(s) == total)

// Pause: the page has no clock, so it does not move while the Mac is paused.
s = SharedScrollProgress()
s.wordProgress = 1.5
s.isPaused = true
let paused = phone(s)
check("pause: holds the word", paused == 3 && phone(s) == paused && phone(s) == paused)

// A tap on any Mac screen moves the page to the tapped word.
s.jump(to: 2)
check("tap: page follows", phone(s) == 5)

// A scroll release on any Mac screen moves the page.
let screen = UUID()
s.beginHold(by: screen)
check("scroll hold: page stays", phone(s) == 5)
s.endHold(by: screen, at: 1, wordCount: words.count)
check("scroll release: page follows", phone(s) == 2)

// Page turn and new session restart the page at word 0.
s.wordProgress = 2
s.resetForNewPage()
check("page turn: restart", phone(s) == 0)

// The page must not advance a clock of its own: the session overlay is the
// only screen that advances the shared position.
if let src = try? String(contentsOfFile: "Textream/Textream/BrowserServer.swift", encoding: .utf8) {
    check("no own clock: no timerWordProgress", !src.contains("timerWordProgress"))
    check("no own clock: no scrollSpeed", !src.contains("scrollSpeed"))
} else {
    check("BrowserServer.swift is readable", false)
}

if fails > 0 { print("\(fails) failed"); exit(1) }
