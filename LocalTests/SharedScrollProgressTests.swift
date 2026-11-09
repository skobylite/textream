// include: Textream/Textream/SharedScrollProgress.swift
// Regression tests for the shared hold, pause and resets of
// SharedScrollProgress. The shared hold must never stay on: a hold that stays
// on stops the text on every screen.
import Foundation

var fails = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  pass" : "  FAIL", name)
    if !ok { fails += 1 }
}

let floating = UUID(), external = UUID()

var s = SharedScrollProgress()
s.beginHold(by: floating)
check("a scroll holds the clock", s.isUserScrolling && s.holdOwner == floating)

s = SharedScrollProgress()
s.isPaused = true
s.wordProgress = 12
s.beginHold(by: floating)
s.resetForNewPage()
check("a page turn ends the hold", !s.isUserScrolling && s.holdOwner == nil)
check("a page turn restarts at word 0", s.wordProgress == 0)
check("a page turn keeps the pause", s.isPaused)

s = SharedScrollProgress()
s.isPaused = true
s.wordProgress = 12
s.beginHold(by: external)
s.resetForNewSession()
check("a new session clears the pause, the hold and the word",
      !s.isPaused && !s.isUserScrolling && s.wordProgress == 0)

s = SharedScrollProgress()
s.beginHold(by: floating)
s.jump(to: 5)
check("a tap ends the hold and sets the word", !s.isUserScrolling && s.wordProgress == 5)
s.endHold(by: floating, at: 9, wordCount: 20)
check("a late release after a tap changes nothing", !s.isUserScrolling && s.wordProgress == 5)

s = SharedScrollProgress()
s.beginHold(by: floating)
s.beginHold(by: external)
s.endHold(by: floating, at: 9, wordCount: 20)
check("a release from a screen that is not the owner changes nothing",
      s.isUserScrolling && s.holdOwner == external && s.wordProgress == 0)
s.endHold(by: external, at: 30, wordCount: 20)
check("the owner's release clamps the word to the page and ends the hold",
      !s.isUserScrolling && s.wordProgress == 20)

s = SharedScrollProgress()
s.beginHold(by: floating)
s.endHold(by: floating, at: -3, wordCount: 20)
check("a release before the start clamps to word 0", !s.isUserScrolling && s.wordProgress == 0)

// The shared look-around scroll.
s = SharedScrollProgress()
s.publishPeek(12.5, from: floating)
check("a scroll shares its word and its source", s.peek == .init(wordProgress: 12.5, source: floating))
s.publishPeek(20, from: external)
check("a scroll on another screen takes over", s.peek?.source == external && s.peek?.wordProgress == 20)
s.clearPeek(from: floating)
check("a late end from the old source does not end the new look-around", s.peek?.source == external)
s.clearPeek(from: external)
check("the source's end clears it", s.peek == nil)
s.publishPeek(3, from: floating)
s.clearPeek()
check("a tap or a resume clears it from any screen", s.peek == nil)
s.publishPeek(3, from: floating)
s.beginHold(by: floating)
s.resetForNewPage()
check("a page turn clears it", s.peek == nil && !s.isUserScrolling)
s.publishPeek(3, from: external)
s.resetForNewSession()
check("a new session clears it", s.peek == nil)

if fails > 0 { print("\(fails) failed"); exit(1) }
