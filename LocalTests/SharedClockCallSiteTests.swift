// include: Textream/Textream/SharedScrollProgress.swift
// (run.sh needs at least one extract or include line.)
// Source check for the shared clock call sites. SmoothScrollSyncTests tests
// tickStep as a pure function. This test checks two one-line places that the
// type-check and the other suites do not see:
// - Only the session overlay runs the clock. If the External display also
//   passes drivesProgress: true, Classic runs at double speed on every screen
//   and on the phone page.
// - A paused smooth screen still follows the shared position. If the
//   smoothWordProgress onChange guard also needs isListening, a paused Classic
//   screen does not follow a tap made on another screen.
import Foundation

var fails = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  pass" : "  FAIL", name)
    if !ok { fails += 1 }
}

// Code lines only: a comment that names a call does not count.
func code(_ path: String) -> String {
    guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
        print("  FAIL cannot read \(path)"); exit(1)
    }
    return source.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        .joined(separator: "\n")
}

/// The text from `start` up to the next `end` after it, or nil.
func section(_ text: String, from start: String, to end: String) -> Substring? {
    guard let s = text.range(of: start),
          let e = text.range(of: end, range: s.upperBound..<text.endIndex) else { return nil }
    return text[s.upperBound..<e.lowerBound]
}

let external = code("Textream/Textream/ExternalDisplayController.swift")
let notch = code("Textream/Textream/NotchOverlayController.swift")
let marquee = code("Textream/Textream/MarqueeTextView.swift")

// External display: show() builds ExternalDisplayView without drivesProgress: true.
if let show = section(external, from: "func show(", to: "func dismiss()") {
    check("External show() builds ExternalDisplayView", show.contains("ExternalDisplayView("))
    check("External show() does not run the clock", !show.contains("drivesProgress: true"))
} else {
    check("External show() found", false)
}
check("ExternalDisplayView does not run the clock by default",
      external.contains("var drivesProgress = false"))
check("ExternalDisplayView passes its drivesProgress on",
      external.contains("drivesProgress: drivesProgress,"))

// Fullscreen is the session overlay, so it runs the clock.
if let fullscreen = section(notch, from: "private func showFullscreen(", to: "NSHostingView(") {
    check("Fullscreen builds ExternalDisplayView", fullscreen.contains("ExternalDisplayView("))
    check("Fullscreen runs the clock", fullscreen.contains("drivesProgress: true"))
} else {
    check("showFullscreen found", false)
}

// The smooth onChange follows the shared position also while paused.
if let body = section(marquee, from: ".onChange(of: smoothWordProgress) { _, _ in", to: ".onChange(") {
    let guards = body.split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { $0.hasPrefix("guard ") }
    check("the smooth onChange guard is only smoothScroll",
          guards == ["guard smoothScroll else { return }"])
} else {
    check("smoothWordProgress onChange found", false)
}

if fails > 0 { print("\(fails) FAIL"); exit(1) }
print("all pass")
