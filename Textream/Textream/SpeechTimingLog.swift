//
//  SpeechTimingLog.swift
//  Textream
//

import Foundation

/// The numbers of one listening session for the speech timing log. The log
/// is off by default; the launch argument -speechTimingLog YES turns it on.
/// It holds numbers only, never words. It is a plain struct, so LocalTests
/// can test it. All times are seconds of system uptime.
///
/// The definitions are the same for every engine:
/// - Move: a change of the highlight after a result. Forward moves less
///   than `burstSeconds` apart count as one move, because results can come
///   in bursts (the macOS 26 model sends several within a few ms).
/// - Speaking time: the time that the voice detector reports speech, added
///   up from its level updates (20 a second).
/// - Wait: the speaking time between two highlight moves. The time from the
///   start to the first move and from the last move to the stop are waits too.
/// - Stall: a wait longer than `stallSeconds`.
/// - Onset: the first level update with speech after a pause of at least
///   `pauseSeconds` of silence. The detector reports silence only
///   `detectorHangover` after the last speech, so the pause starts that much
///   before the detector turns silent. Onset delay: the time from an onset
///   to the next highlight move.
/// - Restart gap and drop gap: the speaking time from a restart of
///   recognition, or from a drop of matched text, to the next highlight move.
/// - Reset: a result that is shorter than the result before it and keeps
///   less than half of it as the same start.
struct SpeechTimingLog {
    static let stallSeconds = 1.5
    static let pauseSeconds = 1.0
    /// The voice detector reports speech for this long after the last level
    /// with speech (the default hangoverDuration of VoiceActivityDetector).
    static let detectorHangover = 0.75
    /// A move of more than this many words is a big move.
    static let bigMoveWords = 3
    static let burstSeconds = 0.1
    /// A longer gap between two level updates adds only this much speaking time.
    static let maxUpdateGap = 0.25

    private let startedAt: TimeInterval
    private var wordEnds: [Int]

    private var spoken = 0.0
    private var lastUpdate: TimeInterval?
    private var lastActive = false
    private var silentSince: TimeInterval
    private var onset: TimeInterval?

    private var lastMoveSpoken = 0.0
    /// The time of the last move, and the offset before its burst when it went forward.
    private var lastMoveAt: TimeInterval?
    private var burstFrom: Int?
    private(set) var waits: [Double] = []
    private(set) var forwardWords: [Int] = []
    private(set) var backMoves = 0
    private(set) var silentMoves = 0
    private(set) var onsetDelays: [Double] = []

    private var restartSpoken: Double?
    private var dropSpoken: Double?
    private(set) var restarts = 0
    private(set) var drops = 0
    private(set) var restartGaps: [Double] = []
    private(set) var dropGaps: [Double] = []

    private(set) var results = 0
    private(set) var finals = 0
    private(set) var resets = 0
    private(set) var errorCodes: [Int: Int] = [:]
    private(set) var readyAfter: Double?
    private(set) var firstResultAfter: Double?

    init(text: String, at time: TimeInterval) {
        startedAt = time
        silentSince = time
        wordEnds = Self.wordEnds(in: text)
    }

    /// The page text changed (Director Mode edits).
    mutating func setText(_ text: String) {
        wordEnds = Self.wordEnds(in: text)
    }

    /// The speaking time from the start up to `time`.
    func speakingTime(at time: TimeInterval) -> Double {
        guard lastActive, let lastUpdate else { return spoken }
        return spoken + min(max(0, time - lastUpdate), Self.maxUpdateGap)
    }

    /// One level update of the voice detector.
    mutating func voice(active: Bool, at time: TimeInterval) {
        spoken = speakingTime(at: time)
        if active && !lastActive && time - silentSince >= Self.pauseSeconds {
            onset = time
        }
        if !active && lastActive {
            // The silence started when the detector last heard speech.
            silentSince = time - Self.detectorHangover
        }
        lastActive = active
        lastUpdate = time
    }

    /// The highlight moved from char offset `from` to `to` after a result.
    mutating func move(from: Int, to: Int, voiceActive: Bool, at time: TimeInterval) {
        guard from != to else { return }
        let now = speakingTime(at: time)
        if to > from, let burstFrom, let lastMoveAt, time - lastMoveAt < Self.burstSeconds {
            // The same burst: the last move grows.
            forwardWords[forwardWords.count - 1] = Self.words(between: burstFrom, and: to, ends: wordEnds)
        } else {
            waits.append(now - lastMoveSpoken)
            if to > from {
                burstFrom = from
                forwardWords.append(Self.words(between: from, and: to, ends: wordEnds))
            } else {
                burstFrom = nil
                backMoves += 1
            }
            if !voiceActive { silentMoves += 1 }
        }
        lastMoveSpoken = now
        lastMoveAt = time
        if let onset {
            onsetDelays.append(time - onset)
            self.onset = nil
        }
        if let restartSpoken {
            restartGaps.append(now - restartSpoken)
            self.restartSpoken = nil
        }
        if let dropSpoken {
            dropGaps.append(now - dropSpoken)
            self.dropSpoken = nil
        }
    }

    /// Recognition restarted. A gap runs from the first restart to the next move.
    mutating func restart(at time: TimeInterval) {
        restarts += 1
        if restartSpoken == nil { restartSpoken = speakingTime(at: time) }
    }

    /// Matched text was dropped (the macOS 26 engine).
    mutating func drop(at time: TimeInterval) {
        drops += 1
        if dropSpoken == nil { dropSpoken = speakingTime(at: time) }
    }

    /// A result arrived.
    mutating func result(isFinal: Bool, reset: Bool, at time: TimeInterval) {
        results += 1
        if isFinal { finals += 1 }
        if reset { resets += 1 }
        if firstResultAfter == nil { firstResultAfter = time - startedAt }
    }

    mutating func error(code: Int) {
        errorCodes[code, default: 0] += 1
    }

    /// Listening started (the audio runs and recognition is set up).
    mutating func ready(at time: TimeInterval) {
        if readyAfter == nil { readyAfter = time - startedAt }
    }

    /// Facts that SpeechRecognizer gives at the stop.
    struct Context {
        var engine = "apple"
        var onDevice = false
        var fallback = false
        /// Smallest and largest tap buffer, in frames (0 when none came).
        var bufferFrames = (min: 0, max: 0)
        var micRate = 0.0
        /// Smallest and largest buffer given to the macOS 26 model, in frames.
        var modelFrames: (min: Int, max: Int)?
    }

    /// The summary line at the stop: key=value pairs, numbers only.
    func summary(at time: TimeInterval, _ context: Context) -> String {
        let now = speakingTime(at: time)
        let allWaits = waits + [now - lastMoveSpoken]
        let restartGaps = self.restartGaps + (restartSpoken.map { [now - $0] } ?? [])
        let dropGaps = self.dropGaps + (dropSpoken.map { [now - $0] } ?? [])
        let moves = forwardWords.count + backMoves
        let big = forwardWords.filter { $0 > Self.bigMoveWords }.count
        let errors = errorCodes.isEmpty ? "0"
            : errorCodes.keys.sorted().map { "\($0):\(errorCodes[$0]!)" }.joined(separator: ",")
        var parts = [
            "engine=\(context.engine)",
            "onDevice=\(context.onDevice ? 1 : 0)",
            "fallback=\(context.fallback ? 1 : 0)",
            "spokenMinutes=" + Self.number(now / 60),
            "moves=\(moves)",
            "backMoves=\(backMoves)",
            "waitMed=" + Self.number(Self.median(allWaits)),
            "waitMax=" + Self.number(allWaits.max()),
            "stalls=\(allWaits.filter { $0 > Self.stallSeconds }.count)",
            "wordsPerMoveMed=" + Self.number(Self.median(forwardWords.map(Double.init)), digits: 1),
            "bigMoveShare=" + Self.number(forwardWords.isEmpty ? nil : Double(big) / Double(forwardWords.count), digits: 3),
            "restarts=\(restarts)",
            "restartGapMed=" + Self.number(Self.median(restartGaps)),
            "restartGapMax=" + Self.number(restartGaps.max()),
            "drops=\(drops)",
            "dropGapMed=" + Self.number(Self.median(dropGaps)),
            "dropGapMax=" + Self.number(dropGaps.max()),
            "onsets=\(onsetDelays.count)",
            "onsetDelayMed=" + Self.number(Self.median(onsetDelays)),
            "silentMoves=\(silentMoves)",
            "bufferFrames=\(context.bufferFrames.min)",
            "bufferFramesMax=\(context.bufferFrames.max)",
            "micRate=" + Self.number(context.micRate, digits: 0),
        ]
        if let model = context.modelFrames {
            parts += ["modelFrames=\(model.min)", "modelFramesMax=\(model.max)"]
        }
        parts += [
            "results=\(results)",
            "finals=\(finals)",
            "resets=\(resets)",
            "errors=" + errors,
            "ready=" + Self.number(readyAfter),
            "firstResult=" + Self.number(firstResultAfter),
        ]
        return parts.joined(separator: " ")
    }

    /// True when `new` is a reset of `old` (see the definitions above).
    static func isReset(from old: String, to new: String) -> Bool {
        guard new.count < old.count else { return false }
        let same = zip(old, new).prefix(while: { $0 == $1 }).count
        return same * 2 < old.count
    }

    /// The char offsets where the words of `text` end.
    static func wordEnds(in text: String) -> [Int] {
        var ends: [Int] = []
        var inWord = false
        var offset = 0
        for character in text {
            if character.isWhitespace {
                if inWord { ends.append(offset) }
                inWord = false
            } else {
                inWord = true
            }
            offset += 1
        }
        if inWord { ends.append(offset) }
        return ends
    }

    /// How many words end after the lower offset and at or before the higher one.
    static func words(between a: Int, and b: Int, ends: [Int]) -> Int {
        func endsUpTo(_ x: Int) -> Int {
            var lo = 0, hi = ends.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if ends[mid] <= x { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }
        return endsUpTo(max(a, b)) - endsUpTo(min(a, b))
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    /// A number with a fixed count of decimals, or "-" when there is none.
    static func number(_ value: Double?, digits: Int = 2) -> String {
        guard let value else { return "-" }
        return String(format: "%.\(digits)f", value)
    }
}
