// include: Textream/Textream/EngineTranscript.swift
// Tests for the running text of the macOS 26 engine (EngineTranscript): how
// final results and live guesses join, and when matched text can be dropped.
// The result texts follow what SpeechTranscriber sent for a recorded reading:
// each result after the first starts with a space.
import Foundation

var fails = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  pass" : "  FAIL", name)
    if !ok { fails += 1 }
}

// Joining.
var t = EngineTranscript()
t.apply("W", isFinal: false)
t.apply("Welcome back to", isFinal: false)
check("a live guess is the running text", t.text == "Welcome back to")
t.apply("Welcome back to the channel.", isFinal: true)
check("a final result ends the live guess", t.text == "Welcome back to the channel." && t.liveText.isEmpty)
t.apply(" Today I want", isFinal: false)
check("the live guess follows the final text", t.text == "Welcome back to the channel. Today I want")
t.apply(" Today I want to show you exactly how", isFinal: false)
check("a new live guess replaces the old one", t.text == "Welcome back to the channel. Today I want to show you exactly how")
t.apply(" Today I want to show you exactly how Sarah Mitchell, a personal trainer from Manchester,", isFinal: true)
t.apply(" went", isFinal: false)
check("final results join in order", t.text == "Welcome back to the channel. Today I want to show you exactly how Sarah Mitchell, a personal trainer from Manchester, went")

t = EngineTranscript()
t.apply("one two", isFinal: true)
t.apply("three", isFinal: true)
t.apply("four", isFinal: false)
check("parts without a space at the join get one space", t.text == "one two three four")
t = EngineTranscript()
t.apply(" one", isFinal: false)
check("the running text has no space at the start", t.text == "one")

// A live guess that the model replaces with the final words.
t = EngineTranscript()
t.apply("went from 3 clowns to 42", isFinal: false)
t.apply("went from 3 clients to 42 clients", isFinal: true)
check("the final words replace a wrong live guess", t.text == "went from 3 clients to 42 clients" && !t.text.contains("clowns"))

// An empty result removes a guess.
t = EngineTranscript()
t.apply("Thanks for watching.", isFinal: true)
t.apply(" um", isFinal: false)
t.apply("", isFinal: false)
check("an empty live result removes the guess", t.text == "Thanks for watching.")
t.apply(" and", isFinal: false)
t.apply("", isFinal: true)
check("an empty final result removes the guess and adds nothing", t.text == "Thanks for watching.")

// Settled: no words of the live guess after the final words.
t = EngineTranscript()
t.apply(" a month to more than $10,000 a month.", isFinal: false)
t.apply(" a month to more than $10,000 a month.", isFinal: true)
check("a final result that ends like the live guess is settled", t.settled)
t.apply(" When", isFinal: false)
check("a new live guess is not settled", !t.settled)
t = EngineTranscript()
t.apply(" a month. When", isFinal: false)
t.apply(" a month.", isFinal: true)
check("a live word after the final words is not settled", !t.settled)
t = EngineTranscript()
t.apply("hello there", isFinal: true)
check("a final result with no live guess before it is settled", t.settled)
t = EngineTranscript()
t.apply("Sarah Mitc", isFinal: false)
t.apply("Sarah Mitchell, a", isFinal: true)
check("a live guess that ends inside a word is not settled", !t.settled)

// A drop removes the final text. The next live guess starts a fresh text.
t = EngineTranscript()
t.apply("the first sentence.", isFinal: true)
t.dropFinalText()
check("a drop empties the running text", t.text.isEmpty && !t.settled)
t.apply(" When Sarah", isFinal: false)
check("after a drop the next words start the text", t.text == "When Sarah")

// The drop rule.
let long = EngineTranscript.dropMinChars + 1
func drop(length: Int = long, settled: Bool = true, pending: Bool = false, check undo: Bool = false,
          sinceJump: Double = 10) -> Bool {
    EngineTranscript.shouldDrop(textLength: length, settled: settled, rereadPending: pending,
                                rereadCheckPending: undo, secondsSinceJump: sinceJump)
}
check("a long settled text far from a jump can be dropped", drop())
check("a short text is not dropped", !drop(length: EngineTranscript.dropMinChars))
check("no drop while a live guess follows the final words", !drop(settled: false))
check("no drop just after a tap jump", !drop(sinceJump: 0.2))
check("no drop within 1 s of a jump", !drop(sinceJump: EngineTranscript.dropAfterJumpSeconds - 0.01))
check("a drop is allowed 1 s after a jump", drop(sinceJump: EngineTranscript.dropAfterJumpSeconds))
check("no drop while a re-read waits for confirmation", !drop(pending: true))
check("no drop while a re-read jump waits for its check", !drop(check: true))
// The check of a re-read jump ends when the next words keep or undo it.
// SpeechModelCallSiteTests checks that an undo ends it, and that the drop
// reads this state from the matcher.

// Helpers.
check("the last word is lower case, letters and digits only", EngineTranscript.lastWord("More than $10,000.") == "10000")
check("no last word in an empty text", EngineTranscript.lastWord("  ") == nil)
check("a last token of only marks is skipped", EngineTranscript.lastWord("well -") == "well")

print(fails == 0 ? "all pass" : "\(fails) FAILED")
exit(fails == 0 ? 0 : 1)
