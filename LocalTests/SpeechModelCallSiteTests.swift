// include: Textream/Textream/EngineTranscript.swift
// (run.sh needs at least one extract or include line.)
// Source check for the call sites of the macOS 26 engine. EngineTranscriptTests
// tests the drop rule (shouldDrop) as a pure function. LocalTests cannot run
// SpeechRecognizer, so this test checks the lines that give the rule the
// matcher state and the lines that handle a failed model or a stopped audio.
// A change to one of them passes the type-check and every other suite, but
// can drop text while a re-read waits (that breaks re-read tracking), or
// leave Word Tracking stuck after the model fails or its audio stops.
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

/// The text from `start` up to the next `end` after it (empty and a FAIL when not found).
func section(_ text: String, from start: String, to end: String) -> Substring {
    guard let s = text.range(of: start),
          let e = text.range(of: end, range: s.upperBound..<text.endIndex) else {
        check("\(start) found", false)
        return ""
    }
    return text[s.upperBound..<e.lowerBound]
}

/// True when `first` is in `text` and `second` comes after it.
func inOrder(_ text: Substring, _ first: String, _ second: String) -> Bool {
    guard let a = text.range(of: first) else { return false }
    return text.range(of: second, range: a.upperBound..<text.endIndex) != nil
}

/// True when `text` has the `wanted` lines one after the other. Each line
/// must match as a whole line (spaces at the ends do not count).
func hasLines(_ text: Substring, _ wanted: [String]) -> Bool {
    let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    guard lines.count >= wanted.count else { return false }
    return (0...(lines.count - wanted.count)).contains { Array(lines[$0..<($0 + wanted.count)]) == wanted }
}

let recognizer = code("Textream/Textream/SpeechRecognizer.swift")
let engine = code("Textream/Textream/SpeechAnalyzerEngine.swift")

// The drop after a result: only after a final result, never while a re-read
// waits for confirmation or for its check, not just after a jump, and with
// the same matcher reset as a new task of today's engine.
let handle = section(recognizer, from: "private func handleSpeechModelResult(", to: "private func speechModelEnded(")
check("a drop comes only after a final result", handle.contains("guard result.isFinal, EngineTranscript.shouldDrop("))
check("a drop reads whether a re-read waits for confirmation", handle.contains("rereadPending: regressionPending != nil"))
check("a drop reads whether a re-read jump waits for its check", handle.contains("rereadCheckPending: regressionUndo != nil"))
check("a drop reads the time since the last jump", handle.contains("secondsSinceJump: Date().timeIntervalSince(lastJumpAt)"))
check("a drop resets the matcher", inOrder(handle, "engineTranscript.dropFinalText()", "resetForNewTranscript()"))
let restart = section(recognizer, from: "private func restartTask() {", to: "private func startPreemptiveTimer()")
check("a new task of today's engine uses the same reset", restart.contains("resetForNewTranscript()"))

// The check of a re-read jump ends when the next words keep or undo the
// jump. Then nothing waits, and a drop can come again.
let undo = section(recognizer, from: "private func undoWrongRegression(", to: "private func regressionUndoForNewTask(")
check("an undo of a wrong re-read jump ends its check", inOrder(undo, "regressionUndo = nil", "guard !kept else { return false }"))

// A far jump keeps the model only while the model and its audio run.
let jump = section(recognizer, from: "func jumpTo(charOffset: Int) {", to: "func start(with text: String) {")
check("a far jump restarts recognition unless the model can keep running",
      inOrder(jump, "if farJumpKeepsModel?() != true {", "restartRecognition(resetRetryCount: false)"))
let begin = section(recognizer, from: "private func beginRecognition() {", to: "private func restartRecognition(")
check("the model gets the audio of the tap", begin.contains("speechModelFeed = model.feed"))
check("a model keeps far jumps only while its audio runs",
      begin.contains("farJumpKeepsModel = { [weak self] in self?.audioEngine.isRunning == true }"))
let stopModel = section(recognizer, from: "private func stopSpeechModel() {", to: "private func handleSpeechModelResult(")
check("a stopped model keeps no far jumps", stopModel.contains("farJumpKeepsModel = nil"))

// A failed model: the session goes on with today's engine.
let setup = section(recognizer, from: "private func setUpSpeechModel(", to: "private func stopSpeechModel() {")
check("no setup error is ignored while the session is current", !setup.contains("catch is CancellationError"))
check("a setup error falls back while the session is current",
      inOrder(setup, "guard let self, isCurrent() else { return }", "self.fallBackFromSpeechModel("))
let ended = section(recognizer, from: "private func speechModelEnded(", to: "private func fallBackFromSpeechModel(")
check("an end of the results, with or without an error, falls back",
      ended.components(separatedBy: "fallBackFromSpeechModel(").count - 1 == 2)
let fallback = section(recognizer, from: "private func fallBackFromSpeechModel(", to: "private func matchCharacters(")
check("the fallback turns the model off and starts today's engine",
      inOrder(fallback, "speechModelFailed = true", "requestSpeechAuthAndBegin(for: sessionGeneration)"))

// The audio watch: the model has no 55 s restart. When its audio stops
// without a handled configuration change, a timer starts recognition again.
// It runs only for the model, only after the audio started, and it stops
// at each cleanup and after a session change.
check("the audio watch starts only for the model, and the 55 s timer only for today's engine",
      hasLines(begin, ["if requiresSpeechRecognition && model == nil && !onDeviceRecognition {",
                       "startPreemptiveTimer()",
                       "} else if model != nil {",
                       "startAudioWatch()",
                       "}"]))
check("the audio watch starts only after the audio started",
      inOrder(begin, "try audioEngine.start()", "startAudioWatch()"))
// The definition and the one call in beginRecognition.
check("the audio watch starts nowhere else", recognizer.components(separatedBy: "startAudioWatch()").count - 1 == 2)
let cleanupTask = section(recognizer, from: "private func cleanupRecognitionTask() {", to: "private func cleanupAudioEngine() {")
check("each cleanup stops the audio watch",
      hasLines(cleanupTask, ["audioWatchTimer?.invalidate()", "audioWatchTimer = nil"]))
for (name, from, to) in [("start", "func start(with text: String) {", "private func requestMicrophoneAccessAndBegin("),
                         ("stop", "func stop() {", "func forceStop() {"),
                         ("forceStop", "func forceStop() {", "func resume() {"),
                         ("resume", "func resume() {", "private func cleanupRecognitionTask() {")] {
    check("\(name) cleans up, so it stops the audio watch",
          hasLines(section(recognizer, from: from, to: to), ["cleanupRecognition()"]))
}
let watch = section(recognizer, from: "private func startAudioWatch() {", to: "private func matchResult(")
let interval = watch.range(of: #"withTimeInterval: [0-9.]+, repeats: true"#, options: .regularExpression)
    .flatMap { Double(watch[$0].dropFirst("withTimeInterval: ".count).prefix(while: { $0 != "," })) }
check("the audio watch checks every 2 to 5 s", interval.map { (2...5).contains($0) } == true)
check("the audio watch does nothing after a session change",
      inOrder(watch, "let generation = sessionGeneration", "self.sessionGeneration == generation"))
check("the audio watch acts only while the model listens",
      watch.contains("self.shouldListen") && watch.contains("self.isListening") && watch.contains("self.speechModel != nil"))
check("the audio watch acts only when the audio stopped", watch.contains("!self.audioEngine.isRunning"))
check("the audio watch starts recognition again, as a tap does",
      hasLines(watch, ["self.restartRecognition(resetRetryCount: false)"]))
// restartTask builds a request for today's engine, and the fallback would
// end the model for the rest of the session.
check("the audio watch neither starts a task of today's engine nor falls back",
      !watch.contains("restartTask()") && !watch.contains("fallBackFromSpeechModel("))

// The engine: SpeechRecognizer ignores an end of the results that comes
// before it has the model. So the setup fails when the results end first.
let start = section(engine, from: "static func start(", to: "private func listen(")
check("the setup fails when the results ended before it returns",
      inOrder(start, "try await analyzer.start(inputSequence: stream)", "if let end = engine.resultsEnd { throw end }"))
let listen = section(engine, from: "private func listen(", to: "func stop() -> Task<Void, Never> {")
check("the engine keeps why its results ended",
      listen.contains("self?.resultsEnd = error") && listen.contains("self?.resultsEnd = SetupError.stopped"))

if fails > 0 { print("\(fails) FAIL"); exit(1) }
print("all pass")
