// include: Textream/Textream/SharedScrollProgress.swift
// (run.sh needs at least one extract or include line.)
// Source check for the shared look-around call sites in SpeechScrollView.
// SmoothScrollSyncTests tests the rules (peekDecision). This test checks that
// the view still sends each event to those rules: deleting one of these
// one-line calls passes the type-check and every other suite, but breaks
// the screen sync (for example a tap that no longer clears the look-around
// on the other screen).
import Foundation

var fails = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  pass" : "  FAIL", name)
    if !ok { fails += 1 }
}

let path = "Textream/Textream/MarqueeTextView.swift"
guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
    print("  FAIL cannot read \(path)"); exit(1)
}
// Code lines only: a comment that names a call does not count.
let code = source.split(separator: "\n", omittingEmptySubsequences: false)
    .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("///") }
    .joined(separator: "\n")
func count(_ s: String) -> Int { code.components(separatedBy: s).count - 1 }

check("a tap clears the look-around", count("handlePeekEvent(.tap)") == 1)
check("both highlight branches report a move", count("handlePeekEvent(.highlightMoved)") == 2)
check("a shared progress move is reported", count("handlePeekEvent(.smoothProgressMoved)") == 1)
check("pause and resume are reported", count("handlePeekEvent(.listeningChanged") == 1)
check("a closed screen clears its own look-around", count("handlePeekEvent(.disappear)") == 1)
check("a scroll release asks the rules", count("peekDecision(.scrollEnded)") == 1)
check("a late release from another screen is skipped", count("if peekEnd.skipsRelease { return }") == 1)
// The timer only writes firedGlideBackTimer. The current view then asks the
// rules, which glide back and clear the look-around (see ScrollTargetTests).
check("the glide-back timer asks the rules", count("handlePeekEvent(.glideBackTimer)") == 1)
check("a shared look-around change is followed",
      code.contains(".onChange(of: sharedProgress?.peek) { _, _ in\n                followSharedPeek()"))
check("a scroll and a paused overscroll publish the look-around", count("publishSharedPeek()") == 3)

// A screen that opens during a look-around shows the shared word.
if let start = code.range(of: ".onAppear {"), let end = code.range(of: ".onDisappear {", range: start.upperBound..<code.endIndex) {
    check("a screen that opens late follows the shared look-around",
          code[start.upperBound..<end.lowerBound].contains("applyFollowerPeek(peek)"))
} else {
    check("onAppear and onDisappear found", false)
}

if fails > 0 { print("\(fails) FAIL"); exit(1) }
print("all pass")
