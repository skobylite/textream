//
//  EngineTranscript.swift
//  Textream
//

import Foundation

/// The running text that the matcher reads, made from the results of Apple's
/// macOS 26 speech model (SpeechTranscriber): the final text so far, then the
/// newest live guess. The model runs for the whole session without restarts,
/// so the text grows. `shouldDrop` says when the matched final text can go.
/// A plain struct with no macOS 26 types, so LocalTests can test it.
struct EngineTranscript {
    /// The final text since the last drop.
    private(set) var finalText = ""
    /// The newest live (volatile) guess for the audio after the final text.
    private(set) var liveText = ""
    /// True after a final result when the live guess before it had no words
    /// after the final words. Then no words of this text come back in the
    /// next live guess, and the text can be dropped.
    private(set) var settled = false

    /// Drop only text longer than this (about one 55 s task of today's engine).
    static let dropMinChars = 1000
    /// No drop this soon after a jump: the matcher ignores results for 0.3 s
    /// after a jump, and the words after a tap must be matched first.
    static let dropAfterJumpSeconds = 1.0

    /// The running text: the final text, then the live guess, with no space at the start.
    var text: String {
        let joined = Self.join(finalText, liveText)
        return String(joined.drop(while: { $0.isWhitespace }))
    }

    /// Applies one result. A final result adds its text to the final text
    /// and ends the live guess. A live result replaces the live guess, and an
    /// empty one removes it.
    mutating func apply(_ resultText: String, isFinal: Bool) {
        if isFinal {
            let liveEnd = Self.lastWord(liveText)
            settled = liveEnd == nil || liveEnd == Self.lastWord(resultText)
            finalText = Self.join(finalText, resultText)
            liveText = ""
        } else {
            liveText = resultText
            settled = false
        }
    }

    /// Removes the final text. Call it only when `shouldDrop` is true, and
    /// reset the matcher as for a new recognition task.
    mutating func dropFinalText() {
        finalText = ""
        settled = false
    }

    /// True when the running text can be dropped after a result: the text is
    /// long, the result was final with no live guess after it (`settled`), no
    /// re-read waits for confirmation or for its check, and the last jump is
    /// at least `dropAfterJumpSeconds` ago.
    static func shouldDrop(textLength: Int, settled: Bool, rereadPending: Bool,
                           rereadCheckPending: Bool, secondsSinceJump: TimeInterval) -> Bool {
        textLength > dropMinChars && settled && !rereadPending && !rereadCheckPending
            && secondsSinceJump >= dropAfterJumpSeconds
    }

    /// The two parts with one space between them when neither has a space at the join.
    static func join(_ a: String, _ b: String) -> String {
        guard let last = a.last, let first = b.first else { return a + b }
        return last.isWhitespace || first.isWhitespace ? a + b : a + " " + b
    }

    /// The last word of `text` in lower case, letters and digits only.
    static func lastWord(_ text: String) -> String? {
        text.split(whereSeparator: { $0.isWhitespace })
            .lazy
            .map { $0.lowercased().filter { $0.isLetter || $0.isNumber } }
            .last { !$0.isEmpty }
    }
}
