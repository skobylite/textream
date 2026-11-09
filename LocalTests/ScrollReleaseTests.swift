// extract: Textream/Textream/MarqueeTextView.swift Scroll smoothReleaseChangesProgress
// Regression test: a smooth scroll release that reads the current word (for
// example a pull past the top at word 0) must spring back by itself, because
// the shared progress does not change and no onChange moves the text.
import Foundation

var fails = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  pass" : "  FAIL", name)
    if !ok { fails += 1 }
}

check("a pull past the top at word 0 reads word 0: no change",
      !Scroll.smoothReleaseChangesProgress(read: 0, current: 0, wordCount: 50))
check("a read below 0 clamps to word 0: no change",
      !Scroll.smoothReleaseChangesProgress(read: -3, current: 0, wordCount: 50))
check("a read past the end clamps to the word count: no change at the end",
      !Scroll.smoothReleaseChangesProgress(read: 80, current: 50, wordCount: 50))
check("a read of another word changes the progress",
      Scroll.smoothReleaseChangesProgress(read: 12, current: 2.85, wordCount: 50))
check("a read of word 0 from word 2.85 changes the progress",
      Scroll.smoothReleaseChangesProgress(read: 0, current: 2.85, wordCount: 50))

if fails > 0 { print("\(fails) FAIL"); exit(1) }
print("all pass")
