// extract: Textream/Textream/SharedScrollProgress.swift ScrollProgressMath charOffset wordProgress shouldAdvance tickStep
// extract: Textream/Textream/MarqueeTextView.swift Scroll readingLineY smoothReadingAnchor wordProgress smoothReleaseKeepsWord smoothLayoutY perWordMidYs ScrollEndTiming scrollEndTiming
// Regression tests for the shared Classic/Voice-Activated reading position
// (SharedScrollProgress) and the smooth-scroll reading line (SpeechScrollView).
import Foundation

// extract.py copies no imports. This makes CGFloat visible to the extracted code.
typealias CGFloat = Foundation.CGFloat

/// AppKit's NSEvent.Phase, with the same raw values, for
/// ScrollWheelNSView.scrollEndTiming. The test does not link AppKit.
enum NSEvent {
    struct Phase: OptionSet {
        let rawValue: UInt
        static let began = Phase(rawValue: 0x1)
        static let stationary = Phase(rawValue: 0x2)
        static let changed = Phase(rawValue: 0x4)
        static let ended = Phase(rawValue: 0x8)
        static let cancelled = Phase(rawValue: 0x10)
        static let mayBegin = Phase(rawValue: 0x20)
    }
}

var fails = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  pass" : "  FAIL", name)
    if !ok { fails += 1 }
}
func near(_ a: Double, _ b: Double, _ tolerance: Double = 0.01) -> Bool { abs(a - b) < tolerance }

// MARK: 1. Word progress <-> char offset

let abc = ["a", "bb", "ccc"]
let abcTotal = abc.joined(separator: " ").count
func offset(_ p: Double) -> Int {
    ScrollProgressMath.charOffset(forWordProgress: p, words: abc, totalCharCount: abcTotal)
}
check("the test words have 8 characters", abcTotal == 8)
check("progress 0 is char 0", offset(0) == 0)
check("progress 1 is char 2", offset(1) == 2)
check("progress 1.5 is char 3", offset(1.5) == 3)
check("progress 3 and 5 are the end (8)", offset(3) == 8 && offset(5) == 8)
check("char 3 is progress 1.5",
      ScrollProgressMath.wordProgress(forCharOffset: 3, words: abc) == 1.5)
check("every word start round-trips",
      (0..<abc.count).allSatisfy {
          ScrollProgressMath.wordProgress(forCharOffset: offset(Double($0)), words: abc) == Double($0)
      })

// The private converter that NotchOverlayView, FloatingOverlayView and
// ExternalDisplayView each had before (frozen copy).
func oldCharOffset(_ progress: Double, words: [String], totalCharCount: Int) -> Int {
    let wholeWord = Int(progress)
    let frac = progress - Double(wholeWord)
    var offset = 0
    for i in 0..<min(wholeWord, words.count) {
        offset += words[i].count + 1 // +1 for space
    }
    if wholeWord < words.count {
        offset += Int(Double(words[wholeWord].count) * frac)
    }
    return min(offset, totalCharCount)
}
func oldWordProgress(_ charOffset: Int, words: [String]) -> Double {
    var offset = 0
    for (i, word) in words.enumerated() {
        let end = offset + word.count
        if charOffset <= end {
            let frac = Double(charOffset - offset) / Double(max(1, word.count))
            return Double(i) + frac
        }
        offset = end + 1
    }
    return Double(words.count)
}
var rng = SystemRandomNumberGenerator()
var sameAsOld = true
for _ in 0..<1000 {
    let words = (0..<Int.random(in: 1...30, using: &rng)).map { _ in
        String(repeating: "x", count: Int.random(in: 1...9, using: &rng))
    }
    let total = words.joined(separator: " ").count
    let p = Double.random(in: 0...Double(words.count + 2), using: &rng)
    let c = Int.random(in: 0...(total + 3), using: &rng)
    if ScrollProgressMath.charOffset(forWordProgress: p, words: words, totalCharCount: total)
        != oldCharOffset(p, words: words, totalCharCount: total)
        || ScrollProgressMath.wordProgress(forCharOffset: c, words: words) != oldWordProgress(c, words: words) {
        sameAsOld = false
    }
}
check("1000 random inputs give the same results as the old private converters", sameAsOld)

// MARK: 2. When the clock advances

func advance(classic: Bool, paused: Bool = false, held: Bool = false, done: Bool = false,
             listening: Bool = false, speaking: Bool = false) -> Bool {
    ScrollProgressMath.shouldAdvance(isClassic: classic, isPaused: paused, isHeld: held, isDone: done,
                                     isListening: listening, isSpeaking: speaking)
}
check("Classic advances with the mic off", advance(classic: true))
check("Classic stops when paused", !advance(classic: true, paused: true))
check("Classic stops while a scroll holds it", !advance(classic: true, held: true))
check("Classic stops when done", !advance(classic: true, done: true))
check("Voice-Activated advances when listening and speaking", advance(classic: false, listening: true, speaking: true))
check("Voice-Activated stops when silent", !advance(classic: false, listening: true, speaking: false))
check("Voice-Activated stops when the mic is off", !advance(classic: false, listening: false, speaking: true))
check("Voice-Activated stops while held, paused or done",
      !advance(classic: false, held: true, listening: true, speaking: true)
      && !advance(classic: false, paused: true, listening: true, speaking: true)
      && !advance(classic: false, done: true, listening: true, speaking: true))

// Only the session overlay runs the clock. A second screen that also ticked
// would double the speed on every screen.
func step(drives: Bool, wordTracking: Bool = false, classic: Bool = true, paused: Bool = false,
          held: Bool = false, listening: Bool = true, speaking: Bool = true) -> Double {
    ScrollProgressMath.tickStep(drivesProgress: drives, isWordTracking: wordTracking, isClassic: classic,
                                isPaused: paused, isHeld: held, isDone: false,
                                isListening: listening, isSpeaking: speaking, scrollSpeed: 3)
}
check("the driving screen adds scrollSpeed * 0.05 a tick (Classic and Voice-Activated)",
      near(step(drives: true), 0.15) && near(step(drives: true, classic: false), 0.15))
var neverSteps = true
for wt in [false, true] { for c in [false, true] { for pa in [false, true] { for he in [false, true] {
    for li in [false, true] { for sp in [false, true] {
        if step(drives: false, wordTracking: wt, classic: c, paused: pa, held: he, listening: li, speaking: sp) != 0 {
            neverSteps = false
        }
    } }
} } } }
check("a screen that does not drive the clock never adds words", neverSteps)
check("Word Tracking never ticks", step(drives: true, wordTracking: true) == 0)
check("the driving screen does not tick while paused or held",
      step(drives: true, paused: true) == 0 && step(drives: true, held: true) == 0)

// MARK: 3. One reading line

for h: CGFloat in [102, 300, 968] {
    let w = Int(h)
    check("tracking Centered reads at h/2 (\(w) pt)",
          Scroll.readingLineY(containerHeight: h, smoothScroll: false, nearTop: false, topAnchor: 33) == h / 2)
    check("smooth Centered reads at the smooth anchor (\(w) pt)",
          Scroll.readingLineY(containerHeight: h, smoothScroll: true, nearTop: false, topAnchor: 33)
              == Scroll.smoothReadingAnchor(containerHeight: h))
    check("Near Top reads at the top anchor in both modes (\(w) pt)",
          Scroll.readingLineY(containerHeight: h, smoothScroll: true, nearTop: true, topAnchor: 33) == 33
          && Scroll.readingLineY(containerHeight: h, smoothScroll: false, nearTop: true, topAnchor: 33) == 33)
}
check("smooth anchor of 102 pt is 82", Scroll.smoothReadingAnchor(containerHeight: 102) == 82)
check("smooth anchor of 968 pt is 948", Scroll.smoothReadingAnchor(containerHeight: 968) == 948)

// MARK: 4 and 5. A scroll release reads the word at the reading line

/// Word midYs from the real WordFlowLayout.perWordMidYs: every word on a
/// line has the midY of the line.
func layout(perRow: Int, rowHeight: CGFloat, words: Int) -> [(Int, CGFloat)] {
    let rows = (words + perRow - 1) / perRow
    let lines: [(wordCount: Int, midY: CGFloat?)] = (0..<rows).map {
        (min(perRow, words - $0 * perRow), CGFloat($0) * rowHeight + rowHeight / 2)
    }
    return Scroll.perWordMidYs(lines: lines).enumerated().map { ($0.offset, $0.element) }
}
/// The real SpeechScrollView.smoothLayoutY over these positions.
func y(_ p: Double, _ positions: [(Int, CGFloat)]) -> CGFloat {
    Scroll.smoothLayoutY(progress: p, wordCount: positions.count) {
        $0 >= 0 && $0 < positions.count ? positions[$0].1 : nil
    }!
}
func read(_ atY: CGFloat, _ positions: [(Int, CGFloat)]) -> Double {
    Scroll.wordProgress(atY: atY, positions: positions, wordCount: positions.count, fallback: -1)
}

let rowsOf5 = layout(perRow: 5, rowHeight: 32, words: 12)
check("perWordMidYs gives one midY for each word, by line",
      rowsOf5.map { $0.1 } == [16, 16, 16, 16, 16, 48, 48, 48, 48, 48, 80, 80])
check("perWordMidYs skips a line with no midY",
      Scroll.perWordMidYs(lines: [(2, 10), (3, nil), (1, 30)]) == [10, 10, 30])
check("smoothLayoutY puts a whole word at its own Y", y(5, rowsOf5) == 48 && y(4, rowsOf5) == 16)
check("smoothLayoutY goes from the last word of a line toward the next line", y(4.5, rowsOf5) == 32)
check("smoothLayoutY stays on the line between two words of one line", y(6.5, rowsOf5) == 48)
check("smoothLayoutY clamps past the end", y(20, rowsOf5) == 80)

let ps: [Double] = [0, 4.5, 10, 24.25, 39.5]
let h: CGFloat = 968
let anchor = Scroll.readingLineY(containerHeight: h, smoothScroll: true, nearTop: false, topAnchor: 0)
let external = layout(perRow: 5, rowHeight: 123, words: 50)
for p in ps {
    // Tracking puts the word at the reading line; the release reads there.
    let offset = anchor - y(p, external)
    check("C2: a release at progress \(p) reads \(p) back (968 pt, 123 pt rows)",
          near(read(anchor - offset, external), p))
}
// The old release read at h/2, so it lost many words on a tall screen.
for p in ps where p >= 24 {
    let offset = anchor - y(p, external)
    check("C2: the old read at h/2 is more than 15 words off at progress \(p)",
          abs(read(h / 2 - offset, external) - p) > 15)
}

let layouts: [(String, [(Int, CGFloat)])] = [
    ("5 words a row, 32 pt rows", layout(perRow: 5, rowHeight: 32, words: 50)),
    ("8 words a row, 123 pt rows", layout(perRow: 8, rowHeight: 123, words: 50)),
]
for (name, positions) in layouts {
    // Words on one line share a midY, so a mid-line progress cannot come
    // back as itself. The screen position must come back.
    check("the screen position round-trips (\(name))",
          ps.allSatisfy { p in near(Double(y(read(y(p, positions), positions), positions)), Double(y(p, positions))) })
}
check("the word round-trips with 5 words a row and 32 pt rows",
      ps.allSatisfy { near(read(y($0, layouts[0].1), layouts[0].1), $0) })

// MARK: A release with no real move keeps the word

let floating = layout(perRow: 5, rowHeight: 32, words: 50)
for current in [22.15, 25.6, 26.65, 28.3] {
    // A release with no move reads the word back from the line of the word.
    // That gives the first word of the line, so the shared word would go back.
    let readBack = read(y(current, floating), floating)
    check("a read from the line of word \(current) gives an earlier word (\(readBack))", readBack < current - 0.5)
}
check("a release that moved the text less than 8 pt keeps the word, also with no layout Y",
      [0, 2, -2, 7.9, -7.9].allSatisfy {
          Scroll.smoothReleaseKeepsWord(manualOffset: $0, minimumMove: 8, readY: 500, wordY: nil, rowAdvance: 32)
      })
check("with no layout Y, a release that moved the text 8 pt or more takes the word read",
      [8, -8, 20, -120, 250].allSatisfy {
          !Scroll.smoothReleaseKeepsWord(manualOffset: $0, minimumMove: 8, readY: 500, wordY: nil, rowAdvance: 32)
      })

/// The shared word after a release of a scroll of `d` px (positive moves the
/// text down) on a screen that tracking put at progress `p`, as onScrollEnd
/// decides it.
func released(_ p: Double, by d: CGFloat, _ positions: [(Int, CGFloat)], rowAdvance: CGFloat) -> Double {
    let readY = y(p, positions) - d
    return Scroll.smoothReleaseKeepsWord(manualOffset: d, minimumMove: 8, readY: readY,
                                         wordY: y(p, positions), rowAdvance: rowAdvance)
        ? p : read(readY, positions)
}
func lineY(_ p: Double, _ positions: [(Int, CGFloat)]) -> CGFloat { positions[min(Int(p), positions.count - 1)].1 }
let externalRows = layout(perRow: 6, rowHeight: 123, words: 60)
let screens: [(String, [(Int, CGFloat)], CGFloat)] = [
    ("floating window, 32 pt rows", floating, 32),
    ("External, 123 pt rows", externalRows, 123),
]
// Includes progress in the last word of a line (24.8, 29.57), where the
// text sits between two lines.
let releaseProgress = [22.15, 24.8, 25.6, 26.65, 27.3, 28.3, 29.57, 34.43, 37.2]
for (name, positions, row) in screens {
    for d: CGFloat in [10, -10, 12, -12] {
        // One wheel notch is 10 px. Without the half-row rule, a read from
        // the line gives its first or last word, and the other screen jumps
        // one row.
        check("a \(Int(d)) px release on the \(name) keeps the shared word on its line",
              releaseProgress.allSatisfy { lineY(released($0, by: d, positions, rowAdvance: row), positions) == lineY($0, positions) })
    }
    check("a \(Int(row)) px release (one row) on the \(name) takes a word of another line",
          releaseProgress.allSatisfy {
              lineY(released($0, by: -row, positions, rowAdvance: row), positions) > lineY($0, positions)
                  && lineY(released($0, by: row, positions, rowAdvance: row), positions) < lineY($0, positions)
          })
}
check("the bug: a 10 px read from the line of word 27.3 on the floating window gives a word of the line before",
      lineY(read(y(27.3, floating) - 10, floating), floating) < lineY(27.3, floating))
check("a 10 px wheel release on the floating window keeps the word", released(27.3, by: 10, floating, rowAdvance: 32) == 27.3)
check("a 20 px release on the External keeps the word", released(36.25, by: 20, externalRows, rowAdvance: 123) == 36.25)
check("a -120 px release on the External (steal) reads a word of the next line",
      lineY(released(29.57, by: -120, externalRows, rowAdvance: 123), externalRows) > lineY(29.57, externalRows))

// MARK: When a scroll event ends the scroll

func end(_ phase: NSEvent.Phase, _ momentum: NSEvent.Phase = []) -> Scroll.ScrollEndTiming {
    Scroll.scrollEndTiming(phase: phase, momentumPhase: momentum)
}
check("a mouse wheel event (no phases) ends the scroll after a pause", end([]) == .afterWheelPause)
check("a trackpad gesture ends at .ended", end(.ended) == .now)
check("a cancelled trackpad gesture (two fingers rest, then lift) ends", end(.cancelled) == .now)
check("momentum ends at .ended or .cancelled", end([], .ended) == .now && end([], .cancelled) == .now)
check("trackpad and momentum events in progress do not end the scroll",
      end(.began) == .noEnd && end(.changed) == .noEnd && end(.mayBegin) == .noEnd
      && end(.stationary) == .noEnd && end([], .began) == .noEnd && end([], .changed) == .noEnd)

if fails > 0 { print("\(fails) failed"); exit(1) }
