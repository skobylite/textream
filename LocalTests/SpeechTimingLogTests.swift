// include: Textream/Textream/SpeechTimingLog.swift
// include: Textream/Textream/VoiceActivityDetector.swift
// Tests for the summary numbers of the speech timing log (SpeechTimingLog).
// Made-up sessions: voice detector updates 20 times a second, highlight
// moves, restarts and drops at known times.
import Foundation

var fails = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  pass" : "  FAIL", name)
    if !ok { fails += 1 }
}
func near(_ a: Double?, _ b: Double, _ tolerance: Double = 0.001) -> Bool {
    guard let a else { return false }
    return abs(a - b) <= tolerance
}
/// The value of `key` in a summary line.
func value(_ key: String, _ line: String) -> String? {
    line.split(separator: " ").first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) }
}
/// Voice detector updates every 0.05 s from `from` up to (not including) `to`.
func speak(_ log: inout SpeechTimingLog, _ from: Double, _ to: Double, active: Bool = true) {
    var t = from
    while t < to - 1e-9 {
        log.voice(active: active, at: t)
        t += 0.05
    }
}

// Word ends and words between offsets.
let text = "the quick brown fox jumps"
let ends = SpeechTimingLog.wordEnds(in: text)
check("word ends are after each word", ends == [3, 9, 15, 19, 25])
check("spaces in a row make no empty words", SpeechTimingLog.wordEnds(in: " a  bc ") == [2, 6])
check("a move over one word counts 1", SpeechTimingLog.words(between: 0, and: 4, ends: ends) == 1)
check("a move to the next word start counts 1", SpeechTimingLog.words(between: 4, and: 10, ends: ends) == 1)
check("a move to the end of the text counts the last word", SpeechTimingLog.words(between: 20, and: 25, ends: ends) == 1)
check("a move over the whole text counts every word", SpeechTimingLog.words(between: 0, and: 25, ends: ends) == 5)
check("a move back counts the same words", SpeechTimingLog.words(between: 25, and: 4, ends: ends) == 4)
check("a move inside one word counts 0", SpeechTimingLog.words(between: 5, and: 7, ends: ends) == 0)

// Median.
check("median of an odd count", SpeechTimingLog.median([3, 1, 2]) == 2)
check("median of an even count is the mean of the two middle values", SpeechTimingLog.median([4, 1, 2, 3]) == 2.5)
check("no median without values", SpeechTimingLog.median([]) == nil)

// Resets.
check("a new transcript after a pause is a reset", SpeechTimingLog.isReset(from: "the quick brown fox", to: "over the"))
check("a revision of the last word is not a reset", !SpeechTimingLog.isReset(from: "the quick brown fox jumps", to: "the quick brown fox jump"))
check("a longer transcript is not a reset", !SpeechTimingLog.isReset(from: "the quick", to: "the quick brown"))
check("the first result is not a reset", !SpeechTimingLog.isReset(from: "", to: "the"))

// Speaking time.
var log = SpeechTimingLog(text: text, at: 0)
speak(&log, 0, 1, active: false)
speak(&log, 1, 3)
check("speaking time adds up the active updates", near(log.speakingTime(at: 3), 2))
log.voice(active: true, at: 4)
check("a gap of 1.05 s in the updates adds only 0.25 s", near(log.speakingTime(at: 4), 2.2))
log.voice(active: false, at: 4.05)
check("silence adds no speaking time", near(log.speakingTime(at: 6), 2.25))
log = SpeechTimingLog(text: text, at: 0)
speak(&log, 0, 3)
check("spoken minutes come from the speaking time",
      value("spokenMinutes", log.summary(at: 3, SpeechTimingLog.Context())) == "0.05")

// Waits, stalls, words per move and big moves.
log = SpeechTimingLog(text: text, at: 0)
speak(&log, 0, 1, active: false)
speak(&log, 1, 2)
log.move(from: 0, to: 4, voiceActive: true, at: 2)       // 1 word after 1 s of speech
speak(&log, 2, 2.5)
log.move(from: 4, to: 10, voiceActive: true, at: 2.5)    // 1 word after 0.5 s
speak(&log, 2.5, 4.5)
log.move(from: 10, to: 20, voiceActive: true, at: 4.5)   // 2 words after 2 s: a stall
speak(&log, 4.5, 4.7)
log.move(from: 20, to: 25, voiceActive: false, at: 4.7)  // 1 word while the detector reports silence
speak(&log, 4.7, 5)
log.move(from: 25, to: 0, voiceActive: true, at: 5)      // back to the start (a re-read)
speak(&log, 5, 5.1)
log.move(from: 0, to: 25, voiceActive: true, at: 5.1)    // 5 words at once: a big move
speak(&log, 5.1, 5.5)
var line = log.summary(at: 5.5, SpeechTimingLog.Context())
check("every highlight move counts", value("moves", line) == "6")
check("a move back counts as a back move", value("backMoves", line) == "1")
// Waits: 1, 0.5, 2, 0.2, 0.3, 0.1 and the 0.4 s after the last move.
check("the median wait is the speaking time between moves", value("waitMed", line) == "0.40")
check("the longest wait", value("waitMax", line) == "2.00")
check("a wait over 1.5 s is a stall", value("stalls", line) == "1")
check("the median words per forward move", value("wordsPerMoveMed", line) == "1.0")
check("the share of forward moves over 3 words", value("bigMoveShare", line) == "0.200")
check("a move while the detector reports silence counts", value("silentMoves", line) == "1")

// Bursts: results that come a few ms apart move the highlight once.
log = SpeechTimingLog(text: text, at: 0)
speak(&log, 0, 1)
log.move(from: 0, to: 4, voiceActive: true, at: 1.0)
log.move(from: 4, to: 10, voiceActive: true, at: 1.01)
log.move(from: 10, to: 16, voiceActive: true, at: 1.03)
log.move(from: 16, to: 20, voiceActive: true, at: 1.05)   // one burst of 4 words
speak(&log, 1, 1.5)
log.move(from: 20, to: 25, voiceActive: true, at: 1.5)    // 0.45 s later: a new move
line = log.summary(at: 1.5, SpeechTimingLog.Context())
check("forward moves less than 0.1 s apart count as one move", value("moves", line) == "2")
check("the words of a burst add up", value("wordsPerMoveMed", line) == "2.5")
check("a burst of more than 3 words is a big move", value("bigMoveShare", line) == "0.500")
check("the waits are counted between bursts", value("waitMax", line) == "1.00" && value("waitMed", line) == "0.45")
log = SpeechTimingLog(text: text, at: 0)
log.move(from: 0, to: 10, voiceActive: true, at: 1.0)
log.move(from: 10, to: 4, voiceActive: true, at: 1.02)
log.move(from: 4, to: 10, voiceActive: true, at: 1.04)
line = log.summary(at: 2, SpeechTimingLog.Context())
check("a move back in a burst, and the move after it, are moves of their own",
      value("moves", line) == "3" && value("backMoves", line) == "1")

// The wait after the last move counts until the stop.
log = SpeechTimingLog(text: text, at: 0)
speak(&log, 0, 0.5)
log.move(from: 0, to: 4, voiceActive: true, at: 0.5)
speak(&log, 0.5, 3)
line = log.summary(at: 3, SpeechTimingLog.Context())
check("the reader speaks on after the last move: the end is a stall", value("stalls", line) == "1" && value("waitMax", line) == "2.50")

// Onset delay: speech after a pause of at least 1 s of real silence, to the
// next move. The levels go through the app's voice detector, as in
// SpeechRecognizer.recordAudioLevel. The detector reports speech for 0.75 s
// after the last speech, so a pause of 1.2 s shows only 0.45 s of detector
// silence. It must still count.
/// Levels every 0.05 s from `from` up to (not including) `to`, through the detector.
func levels(_ log: inout SpeechTimingLog, _ vad: inout VoiceActivityDetector,
            _ from: Double, _ to: Double, speech: Bool) {
    var i = 0
    while from + Double(i) * 0.05 < to - 1e-9 {
        let t = from + Double(i) * 0.05
        vad.process(level: speech ? 0.1 : 0.001, at: t)
        log.voice(active: vad.isActive(at: t), at: t)
        i += 1
    }
}
var vad = VoiceActivityDetector()
log = SpeechTimingLog(text: text, at: 0)
levels(&log, &vad, 0, 1.5, speech: true)                    // speech at once: no onset
log.move(from: 0, to: 4, voiceActive: true, at: 1.5)
levels(&log, &vad, 1.5, 2.0, speech: true)
levels(&log, &vad, 2.0, 2.6, speech: false)                 // a pause of 0.6 s: no onset
levels(&log, &vad, 2.6, 3.0, speech: true)
log.move(from: 4, to: 10, voiceActive: true, at: 3.0)
levels(&log, &vad, 3.0, 3.5, speech: true)
levels(&log, &vad, 3.5, 4.3, speech: false)                 // a pause of 0.8 s: no onset
levels(&log, &vad, 4.3, 4.7, speech: true)
log.move(from: 10, to: 16, voiceActive: true, at: 4.7)
levels(&log, &vad, 4.7, 5.2, speech: true)
levels(&log, &vad, 5.2, 6.4, speech: false)                 // a pause of 1.2 s
levels(&log, &vad, 6.4, 7.0, speech: true)
log.move(from: 16, to: 20, voiceActive: true, at: 7.0)      // 0.6 s after the onset
levels(&log, &vad, 7.0, 7.5, speech: true)
levels(&log, &vad, 7.5, 9.0, speech: false)                 // a pause of 1.5 s
levels(&log, &vad, 9.0, 9.4, speech: true)
log.move(from: 20, to: 25, voiceActive: true, at: 9.4)      // 0.4 s after the onset
line = log.summary(at: 9.4, SpeechTimingLog.Context())
check("speech after a pause of 1.2 s or 1.5 s is an onset, after 0.6 s or 0.8 s not", value("onsets", line) == "2")
check("the median onset delay", value("onsetDelayMed", line) == "0.50")

vad = VoiceActivityDetector()
log = SpeechTimingLog(text: text, at: 0)
levels(&log, &vad, 0, 0.5, speech: false)
levels(&log, &vad, 0.5, 1, speech: true)
log.move(from: 0, to: 4, voiceActive: true, at: 1)
line = log.summary(at: 1, SpeechTimingLog.Context())
check("speech less than 1 s after the start is not an onset", value("onsets", line) == "0" && value("onsetDelayMed", line) == "-")
vad = VoiceActivityDetector()
log = SpeechTimingLog(text: text, at: 0)
levels(&log, &vad, 0, 1.2, speech: false)
levels(&log, &vad, 1.2, 1.5, speech: true)
log.move(from: 0, to: 4, voiceActive: true, at: 1.5)
line = log.summary(at: 1.5, SpeechTimingLog.Context())
check("speech 1.2 s after the start is an onset", value("onsets", line) == "1" && value("onsetDelayMed", line) == "0.30")

// Restart and drop gaps.
log = SpeechTimingLog(text: text, at: 0)
speak(&log, 0, 1)
log.restart(at: 1)
speak(&log, 1, 1.5)
log.restart(at: 1.5)                                       // a retry before any move
speak(&log, 1.5, 2)
log.move(from: 0, to: 4, voiceActive: true, at: 2)         // 1 s of speech after the first restart
speak(&log, 2, 3)
log.restart(at: 3)
speak(&log, 3, 3.3)
log.move(from: 4, to: 10, voiceActive: true, at: 3.3)      // 0.3 s
speak(&log, 3.3, 4)
log.drop(at: 4)
speak(&log, 4, 4.2)
log.move(from: 10, to: 16, voiceActive: true, at: 4.2)     // 0.2 s
speak(&log, 4.2, 5)
log.restart(at: 5)                                         // no move after it: the gap runs to the stop
speak(&log, 5, 6)
line = log.summary(at: 6, SpeechTimingLog.Context())
check("each restart counts", value("restarts", line) == "4")
check("the restart gap runs from the first restart of a series", value("restartGapMax", line) == "1.00")
check("the median restart gap includes the open gap at the stop", value("restartGapMed", line) == "1.00")
check("drops and their gaps", value("drops", line) == "1" && value("dropGapMed", line) == "0.20" && value("dropGapMax", line) == "0.20")

// Results, errors, start times and the context.
log = SpeechTimingLog(text: text, at: 10)
log.ready(at: 10.4)
log.ready(at: 20)
log.result(isFinal: false, reset: false, at: 11.25)
log.result(isFinal: true, reset: false, at: 12)
log.result(isFinal: false, reset: true, at: 13)
log.error(code: 1110)
log.error(code: 216)
log.error(code: 1110)
var context = SpeechTimingLog.Context()
context.engine = "speechTranscriber"
context.onDevice = true
context.fallback = false
context.bufferFrames = (1200, 1200)
context.micRate = 48000
context.modelFrames = (400, 401)
line = log.summary(at: 14, context)
check("results, finals and resets", value("results", line) == "3" && value("finals", line) == "1" && value("resets", line) == "1")
check("error codes with their counts", value("errors", line) == "216:1,1110:2")
check("the time to the first ready and the first result", value("ready", line) == "0.40" && value("firstResult", line) == "1.25")
check("the engine and the on-device flag", value("engine", line) == "speechTranscriber" && value("onDevice", line) == "1" && value("fallback", line) == "0")
check("the tap buffer size and rate", value("bufferFrames", line) == "1200" && value("bufferFramesMax", line) == "1200" && value("micRate", line) == "48000")
check("the model buffer size", value("modelFrames", line) == "400" && value("modelFramesMax", line) == "401")
check("no model buffer size for today's engine",
      value("modelFrames", SpeechTimingLog(text: text, at: 0).summary(at: 1, SpeechTimingLog.Context())) == nil)

// An empty session: no moves, no values to report.
line = SpeechTimingLog(text: text, at: 0).summary(at: 2, SpeechTimingLog.Context())
check("an empty session gives dashes, not numbers", value("waitMed", line) == "0.00" && value("wordsPerMoveMed", line) == "-"
      && value("bigMoveShare", line) == "-" && value("restartGapMed", line) == "-" && value("errors", line) == "0"
      && value("ready", line) == "-")

// The line holds numbers and key names only, never the words of the text.
log = SpeechTimingLog(text: "secret words in the script", at: 0)
speak(&log, 0, 1)
log.move(from: 0, to: 7, voiceActive: true, at: 1)
log.move(from: 7, to: 14, voiceActive: true, at: 1.2)
line = log.summary(at: 2, SpeechTimingLog.Context())
check("the summary has no words of the text", !line.contains("secret") && !line.contains("script"))
check("each part is key=value", line.split(separator: " ").allSatisfy { $0.split(separator: "=").count == 2 })

// A text edit (Director Mode): the moves after it count the words of the new
// text. The same move crosses 2 word ends in the old text and 3 in the new one.
log = SpeechTimingLog(text: "secret words in the script", at: 0)   // word ends 6, 12, 15, 19, 26
log.setText("one two six ten")                                       // word ends 3, 7, 11, 15
log.move(from: 0, to: 12, voiceActive: true, at: 1)
line = log.summary(at: 2, SpeechTimingLog.Context())
check("a text edit counts words in the new text", value("wordsPerMoveMed", line) == "3.0")

print(fails == 0 ? "all pass" : "\(fails) FAILED")
exit(fails == 0 ? 0 : 1)
