// extract: Textream/Textream/MarqueeTextView.swift Scroll readingSpringResponse quickSpringResponse quickGlideSettle readingStepWords slidLineY slidProgress wordTrackingTarget TrackingStep TrackingMove trackingMove trackingScrollKeepsWord tapLandingOffset WordItem layoutMidY lineMidY perWordMidYs readingLineY smoothReadingAnchor followerPeekOffset manualOffsetBounds
// include: Textream/Textream/SpeechTextAlignment.swift
// Tests for the Word Tracking scroll (SpeechScrollView): the target slides
// along the line, a slow no-bounce spring moves the text for reading steps
// and a quick one for other moves, and a look-around holds the text still.
// The readings are made up: 150, 183 and 220 words per minute, results of
// 1-5 words that arrive 0.3-0.65 s after the words, a 3 s pause, a re-read
// and taps.
import Foundation

// extract.py copies no imports. This makes CGFloat visible to the extracted code.
typealias CGFloat = Foundation.CGFloat

var fails = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  pass" : "  FAIL", name)
    if !ok { fails += 1 }
}
func info(_ text: String) { print("  info", text) }
func f1(_ x: Double) -> String { String(format: "%.1f", x) }
func f2(_ x: Double) -> String { String(format: "%.2f", x) }

// MARK: Layouts

/// The paragraph divider space of the real layout (paragraphDividerExtraSpacing).
let paragraphSpacing: CGFloat = 14

/// The lines of `counts` words and their paragraph prefix counts, as
/// WordFlowLayout builds them. A paragraph starts at each line index in
/// `paragraphs` (never line 0, as in the app).
func flowLines(_ counts: [Int], paragraphs: Set<Int>) -> (lines: [[Scroll.WordItem]], prefix: [Int]) {
    var lines: [[Scroll.WordItem]] = []
    var id = 0
    for n in counts {
        lines.append((0..<n).map { Scroll.WordItem(id: id + $0, word: "w", charOffset: 0, isAnnotation: false) })
        id += n
    }
    var prefix = [0]
    for index in lines.indices { prefix.append(prefix[index] + (paragraphs.contains(index) ? 1 : 0)) }
    return (lines, prefix)
}

/// The line midY of each word, from the real WordFlowLayout.layoutMidY and
/// perWordMidYs, for lines of `counts` words.
func layout(_ counts: [Int], paragraphs: Set<Int> = [], rowHeight: CGFloat = 24, lineSpacing: CGFloat = 8) -> [CGFloat] {
    let (lines, prefix) = flowLines(counts, paragraphs: paragraphs)
    return Scroll.perWordMidYs(lines: lines.map { line in
        (line.count, Scroll.layoutMidY(ofWordAt: line[0].id, lines: lines, paragraphPrefixCounts: prefix,
                                       rowHeight: rowHeight, lineSpacing: lineSpacing,
                                       paragraphSpacing: paragraphSpacing))
    })
}

/// The lines of a layout: first word, word count and midY.
func lines(_ ys: [CGFloat]) -> [(first: Int, count: Int, y: CGFloat)] {
    var result: [(first: Int, count: Int, y: CGFloat)] = []
    for (index, y) in ys.enumerated() {
        if let last = result.last, last.y == y {
            result[result.count - 1].count += 1
        } else {
            result.append((index, 1, y))
        }
    }
    return result
}

/// The index of the line that holds word `word`.
func lineIndex(_ word: Int, _ ls: [(first: Int, count: Int, y: CGFloat)]) -> Int {
    ls.lastIndex { $0.first <= word } ?? 0
}

/// The largest distance that one word moves the slid Y in a layout.
func maxWordStep(_ ys: [CGFloat]) -> CGFloat {
    let ls = lines(ys)
    var result: CGFloat = 0
    for index in ls.indices where index + 1 < ls.count {
        result = max(result, (ls[index + 1].y - ls[index].y) / CGFloat(ls[index].count))
    }
    return result
}

func slid(_ p: Double, _ ys: [CGFloat]) -> CGFloat { Scroll.slidLineY(progress: p, lineYs: ys)! }
/// The midY of the line of the next word: today's target height.
func lineY(_ p: Double, _ ys: [CGFloat]) -> CGFloat { ys[min(max(Int(p), 0), ys.count - 1)] }
/// The slide of commit 730e771, for the regression checks: from midway to
/// the line before, at the first word, to midway to the next line.
func centredSlid(_ p: Double, _ ys: [CGFloat]) -> CGFloat {
    let count = ys.count
    let clamped = min(max(p, 0), Double(count))
    let word = min(Int(clamped), count - 1)
    let y = ys[word]
    var first = word
    while first > 0, ys[first - 1] == y { first -= 1 }
    var end = word + 1
    while end < count, ys[end] == y { end += 1 }
    let lower = first > 0 ? (ys[first - 1] + y) / 2 : y
    let upper = end < count ? (y + ys[end]) / 2 : y
    return lower + (upper - lower) * CGFloat((clamped - Double(first)) / Double(end - first))
}

/// A deterministic random source (SplitMix64).
struct Random {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(UInt64(1) << 53) }
    mutating func uniform(_ low: Double, _ high: Double) -> Double { low + (high - low) * unit() }
    mutating func int(_ low: Int, _ high: Int) -> Int { low + Int(next() % UInt64(high - low + 1)) }
}

/// A script laid out with lines of 4-8 words and a paragraph every 3-6 lines.
func scriptLayout(words: Int, random: inout Random, perLine: ClosedRange<Int> = 4...8) -> [CGFloat] {
    var counts: [Int] = []
    var paragraphs = Set<Int>()
    var nextParagraph = random.int(3, 6)
    var total = 0
    while total < words {
        let n = min(random.int(perLine.lowerBound, perLine.upperBound), words - total)
        if counts.count == nextParagraph {
            paragraphs.insert(counts.count)
            nextParagraph += random.int(3, 6)
        }
        counts.append(n)
        total += n
    }
    return layout(counts, paragraphs: paragraphs)
}

// MARK: Made-up readings

enum UpdateKind { case reading, reread, tap, farTap }
struct Update { let time: Double; let progress: Double; let kind: UpdateKind }
struct Reading {
    var updates: [Update] = []
    var speaking: [(start: Double, end: Double)] = []
}

/// Three minutes of reading at `wpm`: groups of 1-5 words, each result
/// 0.3-0.65 s after its last word, and a 3 s pause at 45%. With `events`:
/// a re-read of 8 words at 70%, a tap 12 words back at 85% and a far tap
/// 150 words ahead at 92%.
func makeReading(wpm: Double, random: inout Random, events: Bool) -> Reading {
    var reading = Reading()
    var time = 1.0
    var speakStart = time
    var progress = 0
    var lastArrival = 0.0
    let end = 180.0
    var paused = false, reread = !events, tapped = !events, farTapped = !events
    func add(_ p: Int, _ kind: UpdateKind, after delay: Double) {
        let arrival = max(time + delay, lastArrival + 0.05)
        lastArrival = arrival
        reading.updates.append(Update(time: arrival, progress: Double(p), kind: kind))
    }
    while time < end {
        let group = random.int(1, 5)
        for _ in 0..<group { time += 60 / wpm * random.uniform(0.7, 1.3) }
        progress += group
        add(progress, .reading, after: random.uniform(0.3, 0.65))
        if !paused, time > end * 0.45 {
            paused = true
            reading.speaking.append((speakStart, time))
            time += 3
            speakStart = time
        }
        if !reread, time > end * 0.7 {
            reread = true
            progress -= 8
            add(progress, .reread, after: 0.5)
        }
        if !tapped, time > end * 0.85 {
            tapped = true
            progress -= 12
            add(progress, .tap, after: 0.2)
        }
        if !farTapped, time > end * 0.92 {
            farTapped = true
            progress += 150
            add(progress, .farTap, after: 0.2)
        }
    }
    reading.speaking.append((speakStart, time))
    return reading
}

/// A steady reading on 5-word lines at 183 wpm: 2 words every 0.656 s,
/// from 1 s to before `end`. `hold` drops the results from hold.from to
/// hold.to, so the next result brings all the words that were held.
func steadyReading(end: Double, hold: (from: Double, to: Double)? = nil) -> [Update] {
    var updates: [Update] = []
    var time = 1.0
    var progress = 0.0
    while true {
        time += 0.656
        progress += 2
        guard time < end else { break }
        if let hold, time > hold.from, time < hold.to { continue }
        updates.append(Update(time: time, progress: progress, kind: .reading))
    }
    return updates
}

// MARK: 1. The slide along a line

// Lines of 5, 1, 6, 4 and 7 words. Line 2 (after the one-word line) and
// line 4 start a paragraph. Line 0 is the first line of the page and
// line 4 the last.
let edge = layout([5, 1, 6, 4, 7], paragraphs: [2, 4])
let edgeLines = lines(edge)
check("the edge layout has 23 words on 5 lines", edge.count == 23 && edgeLines.count == 5)
check("a paragraph start adds 14 pt: 32, 46, 32 and 46 pt between the lines",
      zip(edgeLines.dropFirst(), edgeLines).map { $0.y - $1.y } == [32, 46, 32, 46])
for (index, line) in edgeLines.enumerated() {
    check("line \(index) is on the reading line at its first word", slid(Double(line.first), edge) == line.y)
    if index + 1 < edgeLines.count {
        let next = edgeLines[index + 1]
        check("line \(index) ends at the Y of line \(index + 1): no step at the line change",
              abs(slid(Double(next.first) - 1e-9, edge) - next.y) < 1e-6)
    }
}
check("the one-word line slides the whole way to the next line in its word",
      slid(5, edge) == edgeLines[1].y && slid(5.5, edge) == (edgeLines[1].y + edgeLines[2].y) / 2)
check("the last line stays at its own Y",
      slid(16, edge) == edgeLines[4].y && slid(22.5, edge) == edgeLines[4].y && slid(23, edge) == edgeLines[4].y)
check("progress past either end stays at the first or the last line",
      slid(40, edge) == edgeLines[4].y && slid(-3, edge) == edgeLines[0].y)
check("no words give no Y", Scroll.slidLineY(progress: 2, lineYs: []) == nil)
check("a progress that is not a number gives no Y", Scroll.slidLineY(progress: .nan, lineYs: edge) == nil)
check("the slide is linear along a line (words 6 to 11)", abs(slid(9, edge) - (slid(6, edge) + slid(12, edge)) / 2) < 1e-9)
var neverBack = true, continuous = true
let edgeStep = maxWordStep(edge)
var p = 0.0
while p < 23 {
    let next = min(23, p + 0.01)
    let d = slid(next, edge) - slid(p, edge)
    if d < -1e-9 { neverBack = false }
    if d > edgeStep * CGFloat(next - p) + 1e-9 { continuous = false }
    p = next
}
check("the slid Y never goes back over the page (steps of 0.01 word)", neverBack)
check("the slid Y has no jumps over the page", continuous)

/// True when progress `p` puts the line of its next word on the reading
/// line or above it, by less than the space to the next line.
func leadsByLessThanALine(_ p: Double, _ ys: [CGFloat]) -> Bool {
    let ls = lines(ys)
    let index = lineIndex(min(max(Int(p), 0), ys.count - 1), ls)
    let spacing = index + 1 < ls.count ? ls[index + 1].y - ls[index].y : 0
    let above = slid(p, ys) - lineY(p, ys)
    return above >= 0 && (above < spacing || above == 0)
}
check("every progress on the edge layout puts the line of the next word on the reading line or less than one line above it",
      stride(from: 0.0, through: 23.0, by: 0.05).allSatisfy { leadsByLessThanALine($0, edge) })
check("the slide of 730e771 put the line of the next word up to half a line below the reading line",
      lineY(12, edge) - centredSlid(12, edge) == 16)

// The inverse.
for (name, ys) in [("the edge layout", edge), ("5 words a row", layout(Array(repeating: 5, count: 12))),
                   ("6 words a row at 123 pt", layout(Array(repeating: 6, count: 10), rowHeight: 115))] {
    let count = Double(ys.count)
    let lastFirst = Double(lines(ys)[lines(ys).count - 1].first)
    check("slidProgress gives back the progress of every slid Y before the last line (\(name))",
          stride(from: 0.0, to: lastFirst, by: 0.05).allSatisfy {
              abs(Scroll.slidProgress(atY: slid($0, ys), lineYs: ys)! - $0) < 1e-6
          })
    check("a Y above the first line reads 0, and a Y on or below the last line reads the end (\(name))",
          Scroll.slidProgress(atY: ys[0] - 50, lineYs: ys) == 0
          && Scroll.slidProgress(atY: ys[ys.count - 1], lineYs: ys) == count
          && Scroll.slidProgress(atY: ys[ys.count - 1] + 50, lineYs: ys) == count)
}
check("no words give no progress", Scroll.slidProgress(atY: 10, lineYs: []) == nil)
check("a one-line page reads 0 at its line", Scroll.slidProgress(atY: 12, lineYs: layout([4])) == 0)

// MARK: 2. The target on made-up readings, both reading positions

let rates: [Double] = [150, 183, 220]
let readingLineCentered: CGFloat = 300
for wpm in rates {
    var random = Random(state: UInt64(wpm) &* 7919)
    let ys = scriptLayout(words: 1000, random: &random)
    let reading = makeReading(wpm: wpm, random: &random, events: true)
    let step = maxWordStep(ys)
    // Near Top reads at the second row (topReadingAnchor).
    let nearTopLine = lines(ys)[1].y
    for nearTop in [false, true] {
        let line = nearTop ? nearTopLine : readingLineCentered
        let name = "\(Int(wpm)) wpm, " + (nearTop ? "Near Top" : "Centered")
        func target(_ p: Double) -> CGFloat {
            Scroll.wordTrackingTarget(lineY: slid(p, ys), readingLineY: line, nearTop: nearTop)
        }
        var previous = target(0)
        var previousProgress = 0.0
        var readingBack = 0, oversized = 0, still = 0, moved = 0, todayMoved = 0
        var eventsBack = 0, jumps = 0, outside = 0
        for update in reading.updates {
            let t = target(update.progress)
            let d = t - previous
            let words = update.progress - previousProgress
            // Near Top holds the text at the top of the page until the slid
            // Y reaches the reading line.
            let clamped = nearTop && slid(update.progress, ys) <= line
            switch update.kind {
            case .reading:
                if d > 1e-9 { readingBack += 1 }
                if -d > CGFloat(words) * step + 1e-9 { oversized += 1 }
                if words > 0 && !clamped {
                    if d < 0 { moved += 1 } else { still += 1 }
                    if lineY(update.progress, ys) != lineY(previousProgress, ys) { todayMoved += 1 }
                }
            case .reread, .tap:
                if d > 0 { eventsBack += 1 }
            case .farTap:
                if abs(d) > 400 { jumps += 1 }
            }
            if !clamped && !leadsByLessThanALine(update.progress, ys) { outside += 1 }
            previous = t
            previousProgress = update.progress
        }
        check("\(name): reading never moves the target back", readingBack == 0)
        check("\(name): each result moves the target by at most its words times the largest word step (\(f1(Double(step))) pt)",
              oversized == 0)
        check("\(name): every result with new words moves the target forward (\(moved) results); today only \(todayMoved) move it",
              still == 0 && moved > 0 && todayMoved < moved * 3 / 4)
        check("\(name): the re-read and the tap move the target back", eventsBack == 2)
        check("\(name): the far tap is a jump of more than 400 pt", jumps == 1)
        check("\(name): the line of the next word is on the reading line or less than one line above it", outside == 0)
    }
}
check("Near Top: the text stays at the top while the slid Y is above the reading line",
      Scroll.wordTrackingTarget(lineY: 20, readingLineY: 48, nearTop: true) == 0
      && Scroll.wordTrackingTarget(lineY: 60, readingLineY: 48, nearTop: true) == -12)
check("Centered: the slid Y sits on the reading line",
      Scroll.wordTrackingTarget(lineY: 260, readingLineY: 300, nearTop: false) == 40)

// MARK: 3. Which moves glide, jump or stay

func move(_ current: CGFloat, _ target: CGFloat, _ step: Scroll.TrackingStep, words: Double = 2,
          deliberate: Bool = false, allowsBack: Bool = false, settling: Bool = false,
          smooth: Bool = false) -> Scroll.TrackingMove {
    Scroll.trackingMove(from: current, to: target, step: step, words: words, deliberate: deliberate,
                        allowsBack: allowsBack, settling: settling, regressionThreshold: 36,
                        jumpLimit: 400, smoothScroll: smooth)
}
check("a forward reading step of 1 to 5 words glides with the reading spring",
      move(-100, -106, .reading, words: 1) == .readingGlide && move(-100, -164, .reading, words: 5) == .readingGlide)
check("5 words on a narrow screen (300 pt) still glide with the reading spring",
      move(-100, -400, .reading, words: 5) == .readingGlide)
check("the bug: a catch-up of 8 words (1.6 rows) after a hold glided with the reading spring; now it takes the quick spring",
      move(-100, -151, .reading, words: 8) == .quickGlide)
check("the undo of a wrong re-read and a resume after an ad-lib (6 to 12 words) take the quick spring",
      move(-100, -140, .reading, words: 6) == .quickGlide && move(-100, -180, .reading, words: 12) == .quickGlide)
check("a reading step soon after a quick glide is quick too, so a slow spring never takes over a fast glide",
      move(-100, -106, .reading, words: 1, settling: true) == .quickGlide)
check("a reading step with no new words (the layout moved) takes the quick spring",
      move(-100, -110, .reading, words: 0) == .quickGlide)
check("a forward move under 1 pt is not applied", move(-100, -100.5, .reading) == .skip)
check("a short move back from reading is not applied (no bounce)", move(-100, -90, .reading) == .skip)
check("a move back of more than the regression threshold takes the quick spring",
      move(-100, -60, .reading) == .quickGlide)
check("a re-read (deliberate) takes the quick spring, also forward",
      move(-100, -90, .reading, deliberate: true) == .quickGlide
      && move(-100, -110, .reading, words: 2, deliberate: true) == .quickGlide)
check("a tap, a pause, a resume or a layout change (other) takes the quick spring",
      move(-100, -110, .other) == .quickGlide && move(-100, -90, .other, deliberate: true) == .quickGlide)
check("a move of more than 400 pt jumps with no animation, in every step but a look-around",
      move(-100, -600, .reading) == .jump && move(-100, 400, .other, deliberate: true) == .jump)
check("during a look-around the base is a plain write in the caller's transaction, also for a long jump",
      move(-100, -110, .still) == .plain && move(-100, -600, .still) == .plain
      && move(-100, 400, .still, deliberate: true) == .plain)
check("during a look-around a short move back is still not applied", move(-100, -90, .still) == .skip)
check("Classic and Voice-Activated keep their plain write",
      move(-100, -110, .reading, smooth: true) == .plain && move(-100, -900, .reading, smooth: true) == .plain)
check("a tap's one backward allowance takes the quick spring", move(-100, -90, .reading, allowsBack: true) == .quickGlide)

// MARK: 4. A model of how SwiftUI shows the offset

/// A cubic Bezier timing curve from (0, 0) to (1, 1).
func bezier(_ x: Double, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Double {
    if x <= 0 { return 0 }
    if x >= 1 { return 1 }
    func b(_ s: Double, _ p1: Double, _ p2: Double) -> Double {
        3 * (1 - s) * (1 - s) * s * p1 + 3 * (1 - s) * s * s * p2 + s * s * s
    }
    var low = 0.0, high = 1.0
    for _ in 0..<40 {
        let s = (low + high) / 2
        if b(s, x1, x2) < x { low = s } else { high = s }
    }
    return b((low + high) / 2, y1, y2)
}

enum Curve { case easeOut, easeInOut }
enum Request { case spring(response: Double), curve(Curve, duration: Double), snap }

/// How SwiftUI shows the animated offset of the text. A probe measured
/// these rules on macOS 27 (SDK 26.1), with a GeometryEffect that logs the
/// value of each frame:
/// - a change with an animation replaces the running animation and starts
///   from the value that shows now (animations do not add up);
/// - a spring that replaces a running spring keeps its speed;
/// - a spring that replaces a curve starts with no speed;
/// - a change with animations off and no animation shows the new value at
///   once, and the running animation ends;
/// - a change that leaves the value the same changes nothing, so the
///   running animation goes on.
struct Shown {
    /// The value that SwiftUI animates to.
    private(set) var value: Double
    private var position: Double
    private var velocity = 0.0
    private var omega: Double? = nil
    private var curve: (kind: Curve, start: Double, from: Double, duration: Double)? = nil

    init(_ value: Double) {
        self.value = value
        position = value
    }

    func shown(at time: Double) -> Double {
        if let c = curve {
            let x = (time - c.start) / c.duration
            let y = c.kind == .easeOut ? bezier(x, 0, 0, 0.58, 1) : bezier(x, 0.42, 0, 0.58, 1)
            return c.from + (value - c.from) * y
        }
        return position
    }

    mutating func set(_ newValue: Double, _ request: Request, at time: Double) {
        guard newValue != value else { return }
        let now = shown(at: time)
        switch request {
        case .snap:
            position = newValue
            velocity = 0
            omega = nil
            curve = nil
        case .spring(let response):
            if omega == nil { velocity = 0 }
            position = now
            curve = nil
            omega = 2 * Double.pi / response
        case .curve(let kind, let duration):
            curve = (kind, time, now, duration)
            omega = nil
            velocity = 0
        }
        value = newValue
    }

    /// Moves the time on to `time` by `dt`: the exact solution of a
    /// critically damped spring.
    mutating func advance(to time: Double, by dt: Double) {
        if let c = curve {
            if time - c.start >= c.duration {
                curve = nil
                position = value
            }
            return
        }
        guard let w = omega else { return }
        let a = position - value
        let b = velocity + w * a
        let decay = exp(-w * dt)
        position = value + (a + b * dt) * decay
        velocity = (b - w * (a + b * dt)) * decay
    }
}

/// Today (3404937): the line of the next word, a 0.5 s ease-out. 730e771:
/// the centred slide, the reading spring for forward reading steps of up to
/// 2 rows and a 0.5 s ease-out for the rest. fixed: this code.
enum Design { case today, centred, fixed }

/// One Word Tracking prompter view, driven as SpeechScrollView drives it:
/// the text shows base + peek (scrollOffset + manualOffset).
struct Prompter {
    let design: Design
    let ys: [CGFloat]
    let readLine: Double
    let advance: Double
    var shown: Shown
    var base: Double
    var peek = 0.0
    /// The progress of the highlight that tracking last followed (trackedCharCount).
    var tracked = 0.0
    var lastQuick = -Double.infinity
    /// fixed only: false drops the settle time (for the bug checks).
    var settles = true
    /// The response of the reading spring (other values for the sweep).
    var readingResponse = Scroll.readingSpringResponse

    init(_ design: Design, _ ys: [CGFloat], readLine: Double, advance: Double = 32) {
        self.design = design
        self.ys = ys
        self.readLine = readLine
        self.advance = advance
        let start = readLine - Double(Prompter.lineY(design, 0, ys))
        base = start
        shown = Shown(start)
    }

    static func lineY(_ design: Design, _ p: Double, _ ys: [CGFloat]) -> CGFloat {
        switch design {
        case .today: return ys[min(max(Int(p), 0), ys.count - 1)]
        case .centred: return centredSlid(p, ys)
        case .fixed: return slid(p, ys)
        }
    }

    func target(_ p: Double) -> Double { readLine - Double(Prompter.lineY(design, p, ys)) }

    mutating func moveBase(_ value: Double, _ request: Request, at time: Double) {
        base = value
        shown.set(base + peek, request, at: time)
    }

    /// recalculateTracking and applyTrackingTarget: the highlight moved to
    /// `progress`. `force` is a tap on this screen (repositionTracking).
    mutating func follow(_ progress: Double, force: Bool = false, step: Scroll.TrackingStep = .reading,
                         at time: Double) {
        let words = progress - tracked
        let deliberate = force || progress < tracked
        tracked = progress
        let to = target(progress)
        let regression = advance * 0.9
        switch design {
        case .fixed:
            let move = Scroll.trackingMove(
                from: CGFloat(base), to: CGFloat(to), step: step, words: words, deliberate: deliberate,
                allowsBack: false, settling: settles && time - lastQuick < Scroll.quickGlideSettle,
                regressionThreshold: CGFloat(regression), jumpLimit: 400, smoothScroll: false)
            switch move {
            case .skip: break
            case .jump: moveBase(to, .snap, at: time)
            case .readingGlide: moveBase(to, .spring(response: readingResponse), at: time)
            case .quickGlide:
                lastQuick = time
                moveBase(to, .spring(response: Scroll.quickSpringResponse), at: time)
            case .plain:
                // A look-around: the base and the peek offset change in one
                // transaction with animations off. The sum stays the same.
                peek -= to - base
                base = to
                shown.set(base + peek, .snap, at: time)
            }
        case .centred, .today:
            guard deliberate || to < base - 1 || to > base + regression else { return }
            if abs(to - base) > 400 {
                moveBase(to, .snap, at: time)
            } else if design == .centred, step == .reading, !deliberate, to < base, abs(to - base) <= 2 * advance {
                moveBase(to, .spring(response: readingResponse), at: time)
            } else {
                moveBase(to, .curve(.easeOut, duration: 0.5), at: time)
            }
        }
    }

    /// One scroll event on this screen (the live Word Tracking scroll
    /// handler). `holds` stops a running glide first (holdTextWhereShown).
    mutating func scroll(by delta: Double, holds: Bool, at time: Double) {
        if holds, peek == 0, delta != 0 {
            let still = shown.shown(at: time) - peek
            if abs(still - base) > 0.5, abs(still - base) <= 400 {
                base = still
                shown.set(base + peek, .snap, at: time)
            }
        }
        peek += delta
        shown.set(base + peek, .curve(.easeOut, duration: 0.15), at: time)
    }

    /// The glide back at the end of a look-around (glideBackToTrackedLine).
    mutating func glideBack(at time: Double) {
        guard peek != 0 else { return }
        peek = 0
        shown.set(base, .curve(.easeInOut, duration: 0.4), at: time)
        if design == .fixed && settles { lastQuick = time }
    }
}

let dt = 1.0 / 240
/// The default floating window: a 102 pt text area with the Centered
/// reading line at 51 pt, 24 pt rows and 8 pt between them. Its own mask
/// fades the bottom 5 pt. The default notch has a 100 pt text area (reading
/// line at 50 pt) whose bottom 20 pt fade out.
let floatingHeight = 102.0, floatingLine = 51.0, rowHalf = 12.0

struct Motion {
    var stops = 0
    var minutes = 0.0
    var linesPassed = 0
    var samples = 0.0
    /// The line of the next word, in lines below the reading line (sum).
    var offset = 0.0
    /// Floating window: the row of the next word reaches the bottom fade.
    var cut = 0.0
    /// Floating window: the centre of that row is at or below the bottom edge.
    var gone = 0.0
    /// Notch: the centre of that row is in the lower half of the fade.
    var faded = 0.0
    /// The total move back of the shown text outside the 1 s after a re-read or a tap.
    var back = 0.0
    var stopsPerMinute: Double { Double(stops) / minutes }
    func percent(_ x: Double) -> Double { 100 * x / samples }
    mutating func add(_ other: Motion) {
        stops += other.stops
        minutes += other.minutes
        linesPassed += other.linesPassed
        samples += other.samples
        offset += other.offset
        cut += other.cut
        gone += other.gone
        faded += other.faded
        back += other.back
    }
}

/// Runs a reading through one design in the default floating window.
func simulate(_ reading: Reading, _ ys: [CGFloat], _ design: Design,
              response: Double = Scroll.readingSpringResponse) -> Motion {
    var view = Prompter(design, ys, readLine: floatingLine)
    view.readingResponse = response
    var m = Motion()
    var progress = 0.0
    var index = 0
    var previous: Double? = nil
    var stopStart: Double? = nil
    var lastEvent = -10.0
    func speaking(_ t: Double) -> Bool { reading.speaking.contains { t >= $0.start && t <= $0.end } }
    let end = (reading.updates.last?.time ?? 0) + 5
    var time = 0.0
    while time < end {
        while index < reading.updates.count, reading.updates[index].time <= time {
            let update = reading.updates[index]
            index += 1
            if update.kind != .reading { lastEvent = time }
            if update.kind == .reading, lineY(update.progress, ys) != lineY(progress, ys), speaking(time - 0.65) {
                m.linesPassed += 1
            }
            view.follow(update.progress, force: update.kind == .tap || update.kind == .farTap, at: time)
            progress = update.progress
        }
        view.shown.advance(to: time, by: dt)
        let s = view.shown.shown(at: time)
        if let previous {
            let velocity = (s - previous) / dt
            // The text moves down (a larger offset) only after a re-read or a tap.
            if velocity > 0, time - lastEvent > 1 { m.back += velocity * dt }
            // A stop: speed below 2 pt/s for at least 0.1 s.
            if abs(velocity) < 2 {
                if stopStart == nil { stopStart = time }
            } else {
                if let start = stopStart, time - start >= 0.1, speaking(start) { m.stops += 1 }
                stopStart = nil
            }
        }
        previous = s
        if speaking(time) {
            let below = Double(lineY(progress, ys)) + s - floatingLine
            m.samples += 1
            m.offset += below / view.advance
            if floatingLine + below + rowHalf > floatingHeight - 5 { m.cut += 1 }
            if floatingLine + below >= floatingHeight { m.gone += 1 }
            if 50 + below > 90 { m.faded += 1 }
        }
        time += dt
    }
    m.minutes = reading.speaking.reduce(0) { $0 + ($1.end - $1.start) } / 60
    return m
}

check("the reading spring has a response of 3.5 s and the quick one 0.5 s",
      Scroll.readingSpringResponse == 3.5 && Scroll.quickSpringResponse == 0.5)
for wpm in rates {
    var fixed = Motion(), today = Motion(), centred = Motion()
    var worstStops = 0.0, todayPerLine = 10.0
    for seed: UInt64 in 1...5 {
        var random = Random(state: seed &* 7919 &+ UInt64(wpm))
        let ys = scriptLayout(words: 1000, random: &random)
        let reading = makeReading(wpm: wpm, random: &random, events: false)
        let f = simulate(reading, ys, .fixed)
        let t = simulate(reading, ys, .today)
        let c = simulate(reading, ys, .centred)
        worstStops = max(worstStops, f.stopsPerMinute)
        todayPerLine = min(todayPerLine, t.stopsPerMinute / (Double(t.linesPassed) / t.minutes))
        fixed.add(f)
        today.add(t)
        centred.add(c)
    }
    let name = "\(Int(wpm)) wpm"
    info("\(name): stop-starts a minute: today \(f1(today.stopsPerMinute)), 730e771 \(f1(centred.stopsPerMinute)), now \(f1(fixed.stopsPerMinute)) (worst reading \(f1(worstStops)))")
    info("\(name): the line of the next word sits on average \(f2(today.offset / today.samples)) / \(f2(centred.offset / centred.samples)) / \(f2(fixed.offset / fixed.samples)) lines below the reading line (today / 730e771 / now)")
    info("\(name): default floating window, the row of the next word reaches the bottom fade \(f1(today.percent(today.cut)))% / \(f1(centred.percent(centred.cut)))% / \(f1(fixed.percent(fixed.cut)))% of the time; its centre is below the edge \(f2(today.percent(today.gone)))% / \(f2(centred.percent(centred.gone)))% / \(f2(fixed.percent(fixed.gone)))%; notch, in the lower half of the fade \(f1(today.percent(today.faded)))% / \(f1(centred.percent(centred.faded)))% / \(f1(fixed.percent(fixed.faded)))%")
    check("\(name): today the text stops and starts about once a line", todayPerLine > 0.8)
    check("\(name): with the reading spring, fewer than 2 stop-starts a minute in every reading", worstStops < 2)
    check("\(name): the line of the next word sits on average within a third of a line of the reading line",
          abs(fixed.offset / fixed.samples) < 1.0 / 3)
    check("the bug, \(name): with the centred slide it sat on average half a line or more below it",
          centred.offset / centred.samples >= 0.5)
    check("\(name), default floating window: the row of the next word reaches the bottom fade less than 6% of the time",
          fixed.percent(fixed.cut) < 6)
    check("the bug, \(name): with the centred slide it reached the bottom fade 14% of the time or more",
          centred.percent(centred.cut) >= 14)
    check("\(name), default floating window: the centre of that row goes below the bottom edge less than 0.5% of the time (730e771 more than 1%)",
          fixed.percent(fixed.gone) < 0.5 && centred.percent(centred.gone) > 1)
    check("\(name), default notch: the centre of that row is in the lower half of the bottom fade less than 3% of the time (730e771 7% or more)",
          fixed.percent(fixed.faded) < 3 && centred.percent(centred.faded) >= 7)
    check("\(name): the shown text never moves back while the reader reads", fixed.back < 0.01)
}
check("at 183 wpm, the row of the next word reaches the bottom fade of the floating window less than 3% of the time", {
    var cut = 0.0, samples = 0.0
    for seed: UInt64 in 1...5 {
        var random = Random(state: seed &* 7919 &+ 183)
        let ys = scriptLayout(words: 1000, random: &random)
        let m = simulate(makeReading(wpm: 183, random: &random, events: false), ys, .fixed)
        cut += m.cut
        samples += m.samples
    }
    return 100 * cut / samples < 3
}())
// The stress case of the plan review: 8 words a line at 150 wpm.
var stressRandom = Random(state: 99)
let wide = scriptLayout(words: 1000, random: &stressRandom, perLine: 8...8)
let slowReading = makeReading(wpm: 150, random: &stressRandom, events: false)
let wideResult = simulate(slowReading, wide, .fixed)
info("150 wpm, 8 words a line: \(f1(wideResult.stopsPerMinute)) stop-starts a minute")
check("150 wpm with 8 words a line: fewer than 2 stop-starts a minute", wideResult.stopsPerMinute < 2)
// A shorter spring does not meet the goal: the response is not longer than it must be.
var sweepRandom = Random(state: 1 &* 7919 &+ 150)
let sweepLayout = scriptLayout(words: 1000, random: &sweepRandom)
let sweepReading = makeReading(wpm: 150, random: &sweepRandom, events: false)
var sweep: [String] = []
for r in [1.0, 2, Scroll.readingSpringResponse - 1, Scroll.readingSpringResponse] {
    sweep.append("\(f1(r)) s: \(f1(simulate(sweepReading, sweepLayout, .fixed, response: r).stopsPerMinute))")
}
info("150 wpm stop-starts a minute by reading spring response: " + sweep.joined(separator: ", "))
check("a reading spring 1 s faster stops and starts 2 or more times a minute at 150 wpm",
      simulate(sweepReading, sweepLayout, .fixed, response: Scroll.readingSpringResponse - 1).stopsPerMinute >= 2)
// With the re-read and the taps, the shown text moves back only after them.
var eventRandom = Random(state: 183)
let eventLayout = scriptLayout(words: 1000, random: &eventRandom)
let eventReading = makeReading(wpm: 183, random: &eventRandom, events: true)
check("with a re-read and taps, the shown text moves back only in the 1 s after them",
      simulate(eventReading, eventLayout, .fixed).back < 0.01)

// MARK: 4b. Catch-ups, taps and glides back

let fiveWords = layout(Array(repeating: 5, count: 80))
/// Runs `updates` (in time order) through `view` and calls `probe` at each
/// step after the updates of that time. During a look-around (a peek
/// offset of 8 pt or more) a result is a still step.
func run(_ updates: [Update], _ view: inout Prompter, until end: Double,
         events: (Double, inout Prompter) -> Void = { _, _ in },
         probe: (Double, Prompter, Double) -> Void) {
    var index = 0
    var time = 0.0
    while time < end {
        while index < updates.count, updates[index].time <= time {
            let update = updates[index]
            index += 1
            view.follow(update.progress, force: update.kind == .tap,
                        step: abs(view.peek) >= 8 ? .still : .reading, at: time)
        }
        events(time, &view)
        view.shown.advance(to: time, by: dt)
        probe(time, view, view.tracked)
        time += dt
    }
}

// A recognizer hold of 2 s at 183 wpm (for example a 2-of-3 confirmation),
// and then one result with the 8 words that were held.
let held = steadyReading(end: 40, hold: (20, 22))
let catchUpTime = held.first { $0.time > 22 }!.time
func cutAfterCatchUp(_ design: Design) -> (cut: Double, left: Double) {
    var view = Prompter(design, fiveWords, readLine: floatingLine)
    var cut = 0.0, left = 0.0
    run(held, &view, until: catchUpTime + 2) { time, view, progress in
        guard time >= catchUpTime else { return }
        let center = Double(lineY(progress, fiveWords)) + view.shown.shown(at: time)
        if center + rowHalf > floatingHeight - 5 { cut += dt }
        if abs(time - catchUpTime - 0.6) < dt / 2 { left = abs(view.base - view.shown.shown(at: time)) }
    }
    return (cut, left)
}
let catchUp = cutAfterCatchUp(.fixed), oldCatchUp = cutAfterCatchUp(.centred)
info("an 8-word catch-up after a 2 s hold: the next word's row is in the bottom fade for \(f2(catchUp.cut)) s (730e771 \(f2(oldCatchUp.cut)) s)")
check("after a catch-up of 8 words, the row of the next word leaves the bottom fade within 0.3 s", catchUp.cut <= 0.3)
check("the bug: with the reading spring it stayed in the fade for 1 s or more", oldCatchUp.cut >= 1)
check("0.6 s after the catch-up, the text is within 2 pt of its target", catchUp.left <= 2)

// A tap 12 words back while the text glides, and two results 0.15 s and
// 0.45 s after it, as the reader goes on from the tapped word.
func tapDuringReading(settles: Bool) -> (landing: Double, past: Double) {
    let tapTime = 20.33
    var updates = steadyReading(end: tapTime)
    let tapped = updates.last!.progress - 12
    updates.append(Update(time: tapTime, progress: tapped, kind: .tap))
    updates.append(Update(time: tapTime + 0.15, progress: tapped + 1, kind: .reading))
    updates.append(Update(time: tapTime + 0.45, progress: tapped + 2, kind: .reading))
    var view = Prompter(.fixed, fiveWords, readLine: floatingLine)
    view.settles = settles
    let tapTarget = view.target(tapped)
    var landing = Double.infinity, past = 0.0
    run(updates, &view, until: tapTime + 3) { time, view, _ in
        guard time >= tapTime else { return }
        let s = view.shown.shown(at: time)
        past = max(past, s - tapTarget)
        if landing == .infinity, time > tapTime + 0.46, abs(s - view.base) <= 2 { landing = time - tapTime }
    }
    return (landing, past)
}
let tap = tapDuringReading(settles: true), unsettled = tapDuringReading(settles: false)
info("a tap during a glide lands in \(f2(tap.landing)) s; without the settle time a slow spring took over the quick glide and carried the text \(f1(unsettled.past)) pt past the tapped word")
check("a tap during a glide, with results 0.15 s and 0.45 s after it, lands within 2 pt in 0.8 s", tap.landing <= 0.8)
check("after a tap the text never moves past the tapped word", tap.past <= 0.5)
check("the bug: a slow spring that takes over the quick glide carries the text more than 10 pt past it", unsettled.past > 10)

// The glide back at 26 s at the end of a 60 pt look-around, and a result
// of 2 words 0.2 s into it.
func glideBackWithResult(settles: Bool) -> Double {
    var updates = steadyReading(end: 25.9)
    updates.append(Update(time: 26.2, progress: updates.last!.progress + 2, kind: .reading))
    var view = Prompter(.fixed, fiveWords, readLine: floatingLine)
    view.settles = settles
    var left = 0.0
    var peeked = false, glided = false
    run(updates, &view, until: 27, events: { time, view in
        if !peeked, time >= 20 {
            peeked = true
            for _ in 0..<6 { view.scroll(by: 10, holds: true, at: time) }
        }
        if !glided, time >= 26 {
            glided = true
            view.glideBack(at: time)
        }
    }) { time, view, _ in
        if abs(time - 26.8) < dt / 2 { left = abs(view.shown.shown(at: time) - view.base) }
    }
    return left
}
let glideLeft = glideBackWithResult(settles: true), stalled = glideBackWithResult(settles: false)
info("a result 0.2 s into the glide back: 0.8 s after the glide back starts, the text is \(f1(glideLeft)) pt from its place (with a slow spring \(f1(stalled)) pt)")
check("a result during the glide back does not slow it: 0.8 s after it starts, the text is within 2 pt of its place", glideLeft <= 2)
check("the bug: a slow spring that replaces the glide back starts with no speed and leaves the text more than 10 pt away", stalled > 10)

// MARK: 5. A look-around holds the text still

/// A look-around during reading at 183 wpm: at 40 s the user scrolls the
/// text 120 pt down in 12 wheel steps of 10 pt, 20 ms apart. Then 10
/// results arrive 0.5 s apart, one of them a jump of more than 400 pt. The
/// base and the peek offset change together. Gives the largest distance
/// between the text and the same scroll on text at rest, the largest move
/// while the results arrive, and the glide that ran when the scroll started.
func lookAround(holds: Bool, design: Design = .fixed) -> (fromScroll: Double, duringResults: Double, glide: Double) {
    var random = Random(state: 183 &* 7919)
    let ys = scriptLayout(words: 1000, random: &random)
    let reading = makeReading(wpm: 183, random: &random, events: false)
    var view = Prompter(design, ys, readLine: floatingLine)
    let start = 40.0
    var time = 0.0
    var index = 0
    while time < start {
        while index < reading.updates.count, reading.updates[index].time <= time {
            view.follow(reading.updates[index].progress, at: time)
            index += 1
        }
        view.shown.advance(to: time, by: dt)
        time += dt
    }
    let glide = abs(view.base + view.peek - view.shown.shown(at: time))
    var reference = Shown(view.shown.shown(at: time))
    var fromScroll = 0.0
    func step(_ seconds: Double, _ body: (Double) -> Void = { _ in }) {
        let end = time + seconds
        while time < end {
            view.shown.advance(to: time, by: dt)
            reference.advance(to: time, by: dt)
            fromScroll = max(fromScroll, abs(view.shown.shown(at: time) - reference.shown(at: time)))
            body(time)
            time += dt
        }
    }
    for _ in 0..<12 {
        view.scroll(by: 10, holds: holds, at: time)
        reference.set(reference.value + 10, .curve(.easeOut, duration: 0.15), at: time)
        step(0.02)
    }
    step(0.2)
    let atResults = view.shown.shown(at: time)
    var duringResults = 0.0
    let next = reading.updates.filter { $0.time > start }.prefix(10).map(\.progress)
    for (n, progress) in next.enumerated() {
        // The sixth result is a far move of the highlight.
        let p = n == 5 ? progress + 150 : progress
        if design == .today {
            // 3404937: the base in a transaction of its own, then the peek
            // offset in the ambient one (implicit 0.15 s ease-out).
            let to = view.target(p)
            let delta = to - view.base
            if abs(delta) > 400 {
                view.moveBase(to, .snap, at: time)
            } else {
                view.base = to
            }
            view.peek -= delta
            view.shown.set(view.base + view.peek, .curve(.easeOut, duration: 0.15), at: time)
        } else {
            view.follow(p, step: .still, at: time)
        }
        step(0.5) { t in duringResults = max(duringResults, abs(view.shown.shown(at: t) - atResults)) }
    }
    return (fromScroll, duringResults, glide)
}
let held1 = lookAround(holds: true), unheld = lookAround(holds: false), before = lookAround(holds: false, design: .today)
info("a look-around starts while the reading spring still has \(f1(held1.glide)) pt to go")
check("a look-around during reading moves the text only by the user's scroll (within 0.5 pt)", held1.fromScroll <= 0.5)
check("the shown text moves no more than 0.5 pt while 10 results arrive, one of them a jump of more than 400 pt",
      held1.duringResults <= 0.5)
check("the bug: without the hold, the first scroll step ends the running glide in 0.15 s and the text jumps on by \(f1(unheld.fromScroll)) pt",
      unheld.fromScroll > 5)
check("the bug (3404937): a far move of the highlight during a look-around jumped the text by more than 400 pt and back",
      before.duringResults > 400)

// MARK: 6. Every screen reads and follows a look-around with the same map

/// The follower's peek offset for shared progress `shared`, as
/// applyFollowerPeek computes it in Word Tracking (Centered).
func followerOffset(_ shared: Double, _ ys: [CGFloat], height: CGFloat, base: CGFloat) -> CGFloat {
    let readLine = Scroll.readingLineY(containerHeight: height, smoothScroll: false, nearTop: false, topAnchor: 0)
    let bounds = Scroll.manualOffsetBounds(scrollOffset: base, topOffset: height / 2 - 14,
                                           maxWordY: ys[ys.count - 1], containerHeight: height)
    return Scroll.followerPeekOffset(readLineY: readLine, wordY: slid(shared, ys), scrollOffset: base,
                                     lower: bounds.lower, upper: bounds.upper)
}
struct Screen { let name: String; let ys: [CGFloat]; let height: CGFloat }
// The floating window: 5 words a row, 32 pt rows, 102 pt high. The External:
// 6 words a row, 123 pt rows, 968 pt high.
let floatingScreen = Screen(name: "floating window", ys: layout(Array(repeating: 5, count: 14)), height: 102)
let externalScreen = Screen(name: "External", ys: layout(Array(repeating: 6, count: 12), rowHeight: 115), height: 968)
/// The progress at the first, middle and last word of lines of both layouts.
let followProgress: [Double] = [10, 12, 14, 15, 25, 27, 29, 30, 36, 38.5, 41, 12.5, 15.5, 17, 18, 24, 26.5, 29.4]
let nudges: [CGFloat] = [0, 1, -1, 5, -7.5]
let scrolls: [CGFloat] = [10, -10, 40, -40]
check("the nudge rule: a scroll of less than 8 pt keeps the word, 8 pt or more reads the place",
      nudges.allSatisfy { Scroll.trackingScrollKeepsWord(manualOffset: $0, minimumMove: 8) }
      && !Scroll.trackingScrollKeepsWord(manualOffset: 8, minimumMove: 8)
      && !Scroll.trackingScrollKeepsWord(manualOffset: -8, minimumMove: 8))
for (source, follower) in [(floatingScreen, externalScreen), (externalScreen, floatingScreen)] {
    let sourceLine = source.height / 2, followerLine = follower.height / 2
    var nudgeMax: CGFloat = 0, readNudgeMax: CGFloat = 0, placeError = 0.0, wrongWay = 0
    for p in followProgress {
        let sourceBase = Scroll.wordTrackingTarget(lineY: slid(p, source.ys), readingLineY: sourceLine, nearTop: false)
        let followerBase = Scroll.wordTrackingTarget(lineY: slid(p, follower.ys), readingLineY: followerLine, nearTop: false)
        /// The place at the source's reading line after a scroll of `d`.
        func read(_ d: CGFloat) -> Double { Scroll.slidProgress(atY: sourceLine - (sourceBase + d), lineYs: source.ys)! }
        /// What the source shares for a scroll of `d` (scrollReadProgress).
        func shared(_ d: CGFloat) -> Double {
            Scroll.trackingScrollKeepsWord(manualOffset: d, minimumMove: 8) ? p : read(d)
        }
        for d in nudges {
            nudgeMax = max(nudgeMax, abs(followerOffset(shared(d), follower.ys, height: follower.height, base: followerBase)))
            readNudgeMax = max(readNudgeMax, abs(followerOffset(read(d), follower.ys, height: follower.height, base: followerBase)))
        }
        for d in scrolls {
            let s = shared(d)
            let offset = followerOffset(s, follower.ys, height: follower.height, base: followerBase)
            let place = Scroll.slidProgress(atY: followerLine - (followerBase + offset), lineYs: follower.ys)!
            placeError = max(placeError, abs(place - s))
            if offset * d <= 0 { wrongWay += 1 }
        }
    }
    check("a scroll of less than 8 pt on the \(source.name) moves the \(follower.name) by less than 0.5 pt", nudgeMax < 0.5)
    check("without the nudge rule, such a scroll would move the \(follower.name) by up to \(f1(Double(readNudgeMax))) pt",
          readNudgeMax >= 0.5)
    check("a 10 or 40 pt scroll on the \(source.name) puts the same reading place on the \(follower.name)'s reading line",
          placeError < 0.01)
    check("a 10 or 40 pt scroll on the \(source.name) moves the \(follower.name) the same way", wrongWay == 0)
}

// MARK: 7. The line midY of every word in one pass

var midRandom = Random(state: 7)
var midCounts: [Int] = []
var midParagraphs = Set<Int>()
for index in 0..<300 {
    midCounts.append(midRandom.int(1, 8))
    if index > 0, midRandom.int(0, 4) == 0 { midParagraphs.insert(index) }
}
let mid = flowLines(midCounts, paragraphs: midParagraphs)
let byWord = mid.lines.map {
    Scroll.layoutMidY(ofWordAt: $0[0].id, lines: mid.lines, paragraphPrefixCounts: mid.prefix,
                      rowHeight: 24, lineSpacing: 8, paragraphSpacing: paragraphSpacing)
}
let byLine = mid.lines.indices.map {
    Scroll.lineMidY($0, paragraphPrefixCounts: mid.prefix, rowHeight: 24, lineSpacing: 8, paragraphSpacing: paragraphSpacing)
}
check("lineMidY gives each line the midY that layoutMidY gives its words (300 lines, with paragraphs)",
      byWord.count == byLine.count && zip(byWord, byLine).allSatisfy { $0 == $1 })

// MARK: 8. A tap on an annotation

let tapWords = ["Hello", "[pause]", "world", "[long", "pause", "here]", "again", "🙂", "end", "[smile]"]
var tapOffsets: [Int] = []
var tapOffset = 0
for word in tapWords {
    tapOffsets.append(tapOffset)
    tapOffset += word.count + 1
}
let tapText = tapWords.joined(separator: " ")
func land(_ word: Int) -> Int { Scroll.tapLandingOffset(words: tapWords, charOffset: tapOffsets[word]) }
check("a tap on a spoken word lands on it", land(0) == tapOffsets[0] && land(2) == tapOffsets[2] && land(6) == tapOffsets[6])
check("a tap on [pause] lands on the next word, as the recognizer's jumpTo does", land(1) == tapOffsets[2])
check("a tap on any word of a long annotation lands after it", land(3) == tapOffsets[6] && land(4) == tapOffsets[6] && land(5) == tapOffsets[6])
check("a tap on an emoji-only word lands on it (the recognizer skips only [bracket] text)", land(7) == tapOffsets[7])
check("a tap on a last annotation, or past the end, lands at the end",
      land(9) == tapText.count && Scroll.tapLandingOffset(words: tapWords, charOffset: tapText.count + 40) == tapText.count)

// MARK: 9. The view uses these rules (source check)

let path = "Textream/Textream/MarqueeTextView.swift"
guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
    print("  FAIL cannot read \(path)"); exit(1)
}
// Code lines only (a comment that names a call does not count), with each
// run of white space as one space.
let code = source.split(separator: "\n", omittingEmptySubsequences: false)
    .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    .joined(separator: "\n")
    .split(whereSeparator: { $0.isWhitespace })
    .joined(separator: " ")
func section(_ start: String, _ end: String) -> Substring? {
    guard let s = code.range(of: start),
          let e = code.range(of: end, range: s.upperBound..<code.endIndex) else { return nil }
    return code[s.upperBound..<e.lowerBound]
}
func count(_ s: String) -> Int { code.components(separatedBy: s).count - 1 }
func has(_ start: String, _ end: String, _ text: String) -> Bool { section(start, end)?.contains(text) ?? false }

let handler = (".onChange(of: highlightedCharCount) { _, _ in", "} else if !smoothScroll {")
check("a look-around on this screen or another one holds the text still",
      has(handler.0, handler.1, "let holdsStill = isPeeking || Self.peekOwner(source: sharedProgress?.peek?.source, this: peekSourceID) == .other"))
check("live tracking asks for a reading step, or for a still step during a look-around",
      has(handler.0, handler.1, "recalculateTracking(containerHeight: containerHeight, step: holdsStill ? .still : .reading)"))
check("the peek offset takes up the base move", has(handler.0, handler.1, "manualOffset -= scrollOffset - baseBefore"))
check("only the look-around path writes in one transaction with animations off",
      has(handler.0, handler.1, "if holdsStill { var transaction = Transaction() transaction.disablesAnimations = true withTransaction(transaction, followReader) } else { followReader() }"))

let apply = ("private func applyTrackingTarget(", "private func glide(to target: CGFloat, response: Double) {")
check("applyTrackingTarget asks trackingMove with the words of the step and the settle time",
      has(apply.0, apply.1, "let move = Self.trackingMove( from: scrollOffset, to: target, step: step, words: words, deliberate: followsBack || force || !hasAppliedTrackingTarget, allowsBack: allowsNextBackwardTrackingUpdate, settling: now - lastQuickGlide < Self.quickGlideSettle, regressionThreshold: regressionThreshold, jumpLimit: wordFlowCullingBuffer, smoothScroll: smoothScroll )"))
check("a long move jumps with animations off",
      has(apply.0, apply.1, "case .jump: var transaction = Transaction() transaction.disablesAnimations = true withTransaction(transaction) { scrollOffset = target } case .readingGlide:"))
check("a reading step glides with the reading spring",
      has(apply.0, apply.1, "case .readingGlide: glide(to: target, response: Self.readingSpringResponse) case .quickGlide:"))
check("every other Word Tracking move glides with the quick spring and starts the settle time",
      has(apply.0, apply.1, "case .quickGlide: lastQuickGlide = now if isAnimatingReadingPositionChange { scrollOffset = target } else { glide(to: target, response: Self.quickSpringResponse) } case .plain: scrollOffset = target }"))
check("a glide writes the base inside a no-bounce spring transaction with animations off",
      has("private func glide(to target: CGFloat, response: Double) {", "private func wordIndex(at",
          "var transaction = Transaction(animation: .spring(response: response, dampingFraction: 1)) transaction.disablesAnimations = true withTransaction(transaction) { scrollOffset = target } }"))

let recalc = ("private func recalculateTracking(", "private func recalcTopWithPreviousLine(")
check("each step counts its words before tracking takes the new highlight",
      has(recalc.0, recalc.1, "let words = smoothScroll ? 0 : trackingProgress - trackingProgress(atCharCount: trackedCharCount) trackedCharCount = highlightedCharCount"))
check("Centered puts the slid Y on the centre line",
      has(recalc.0, recalc.1, "if let wordY = readingY(forProgress: trackingProgress) { applyTrackingTarget( Self.wordTrackingTarget(lineY: wordY, readingLineY: center, nearTop: false), followsBack: highlightMovedBack, step: step, words: words )"))
check("Near Top holds the text at the top, then puts the slid Y on its reading line",
      has("private func recalcTopWithPreviousLine(", "private var trackingProgress: Double {",
          "guard let wordY = readingY(forProgress: trackingProgress) else { return } applyTrackingTarget( Self.wordTrackingTarget(lineY: wordY, readingLineY: topReadingAnchor, nearTop: true), followsBack: highlightMovedBack, step: step, words: words )"))
check("a tap aims at the highlight that it sets, past an annotation",
      code.contains("let landing = smoothScroll ? charOffset : Self.tapLandingOffset(words: words, charOffset: charOffset) let tappedWordIndex = wordIndex(at: landing)")
      && code.contains("trackedCharCount = landing onWordTap?(charOffset)")
      && code.contains("repositionTracking(toWordIndex: tappedWordIndex, charCount: landing)")
      && has("private func repositionTracking(", "static func tapLandingOffset(",
             "readingY(forProgress: trackingProgress(atCharCount: charCount))")
      && has("private func repositionTracking(", "static func tapLandingOffset(",
             "Self.wordTrackingTarget( lineY: wordY, readingLineY: activeReadingLineY(containerHeight: containerHeight), nearTop: readingPosition == .nearTop )"))
check("a look-around in live Word Tracking starts where the text is",
      code.contains("if !smoothScroll { peekResetGeneration += 1 if isListening { if manualOffset == 0, delta != 0 { holdTextWhereShown() } schedulePeekGlideBack() } }"))
check("the hold reads the shown offset and writes the base there with animations off",
      has("private func holdTextWhereShown() {", "private func scrollReadProgress()",
          "guard let shown = shownOffset.value else { return } let base = shown - manualOffset let gap = abs(base - scrollOffset) guard gap > 0.5, gap <= wordFlowCullingBuffer else { return } var transaction = Transaction() transaction.disablesAnimations = true withTransaction(transaction) { scrollOffset = base }"))
check("the text shows its offset through ShownOffsetEffect",
      count(".modifier(ShownOffsetEffect(y: scrollOffset + manualOffset, shown: shownOffset))") == 1
      && count(".offset(y: scrollOffset + manualOffset)") == 0)
check("ShownOffsetEffect writes the offset that it shows",
      has("struct ShownOffsetEffect: GeometryEffect {", "struct SpeechScrollView: View {",
          "func effectValue(size: CGSize) -> ProjectionTransform { shown.value = y return ProjectionTransform(CGAffineTransform(translationX: 0, y: y)) }"))
check("a glide back starts the settle time",
      has("private func glideBackToTrackedLine() {", "private func holdTextWhereShown() {",
          "withTransaction(transaction) { manualOffset = 0 } lastQuickGlide = ProcessInfo.processInfo.systemUptime }"))
check("Word Tracking keeps the word only for a nudge",
      has("private func scrollKeepsCurrentWord() -> Bool {", "static func trackingScrollKeepsWord(",
          "if !smoothScroll, layoutWidth > 0 { return Self.trackingScrollKeepsWord(manualOffset: manualOffset, minimumMove: minimumPeekOffset) }"))
check("wordMidYs makes one pass over the lines",
      has("func wordMidYs() -> [CGFloat] {", "static func perWordMidYs(", "Self.lineMidY(")
      && !has("func wordMidYs() -> [CGFloat] {", "static func perWordMidYs(", "layoutMidY("))
check("tracking uses the slid target in both reading positions",
      count("readingY(forProgress: trackingProgress)") == 2 && count("Self.wordTrackingTarget(") == 3)
check("Word Tracking reads, keeps and follows a look-around with the slid map",
      has("private func readingY(forProgress", "private func trackingWordY", "Self.slidLineY(")
      && has("private func wordProgressAtCurrentOffset", "private func activeWordFraction", "Self.slidProgress(atY:")
      && code.contains("guard let wordY = readingY(forProgress: peek.wordProgress)")
      && code.contains("smoothScroll ? smoothWordProgress : trackingProgress"))

if fails > 0 { print("\(fails) FAIL"); exit(1) }
print("all pass")
