//
//  SharedScrollProgress.swift
//  Textream
//
//  One reading position for every Mac prompter screen in Classic and
//  Voice-Activated mode. The session overlay and the External display read
//  and write the same object, so they show the same word.
//

import Foundation
import Observation

/// Pure helpers for the shared reading position. LocalTests copies these, so
/// they use only their parameters.
enum ScrollProgressMath {
    /// Convert fractional word index to char offset using actual word lengths
    static func charOffset(forWordProgress progress: Double, words: [String], totalCharCount: Int) -> Int {
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

    /// Convert char offset back to fractional word index (for taps)
    static func wordProgress(forCharOffset charOffset: Int, words: [String]) -> Double {
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

    /// Whether the clock moves on this tick. Classic moves unless it is
    /// paused, held by a scroll or done. Voice-Activated also needs the mic
    /// to hear speech.
    static func shouldAdvance(
        isClassic: Bool,
        isPaused: Bool,
        isHeld: Bool,
        isDone: Bool,
        isListening: Bool,
        isSpeaking: Bool
    ) -> Bool {
        if isDone || isHeld || isPaused { return false }
        return isClassic || (isListening && isSpeaking)
    }

    /// The words that one 0.05 s timer tick adds to the shared position.
    /// Only the screen that drives the clock (the session overlay) adds
    /// words. Every other screen gets 0: a second screen that also ticks
    /// doubles the reading speed. Word Tracking follows the mic instead.
    static func tickStep(
        drivesProgress: Bool,
        isWordTracking: Bool,
        isClassic: Bool,
        isPaused: Bool,
        isHeld: Bool,
        isDone: Bool,
        isListening: Bool,
        isSpeaking: Bool,
        scrollSpeed: Double
    ) -> Double {
        guard drivesProgress, !isWordTracking,
              shouldAdvance(
                  isClassic: isClassic,
                  isPaused: isPaused,
                  isHeld: isHeld,
                  isDone: isDone,
                  isListening: isListening,
                  isSpeaking: isSpeaking
              ) else { return 0 }
        return scrollSpeed * 0.05 // words per second
    }
}

/// The Classic and Voice-Activated reading position of the current session.
/// NotchOverlayController owns it; every prompter screen of the session
/// reads it.
///
/// Only the session overlay advances it (its 0.05 s timer). A second screen
/// that also ticks doubles the reading speed.
@Observable
final class SharedScrollProgress {
    /// Continuous word progress (3.7 = 70% through the 4th word).
    var wordProgress: Double = 0
    /// The Classic Pause button. It stays across a page turn.
    var isPaused = false
    /// The screen whose manual scroll holds the clock, or nil. Only that
    /// screen's scroll release writes the progress and ends the hold.
    private(set) var holdOwner: UUID?

    var isUserScrolling: Bool { holdOwner != nil }

    /// A smooth-mode scroll on screen `owner` holds the clock.
    func beginHold(by owner: UUID) {
        if holdOwner != owner { holdOwner = owner }
    }

    /// The scroll on screen `owner` ended at `progress`. A release from a
    /// screen that no longer holds the clock (a tap or a scroll on another
    /// screen came later) changes nothing.
    func endHold(by owner: UUID, at progress: Double, wordCount: Int) {
        guard holdOwner == owner else { return }
        wordProgress = max(0, min(Double(wordCount), progress))
        holdOwner = nil
    }

    /// A tap sets the word and ends any hold.
    func jump(to progress: Double) {
        wordProgress = progress
        if holdOwner != nil { holdOwner = nil }
    }

    func resetForNewPage() {
        wordProgress = 0
        holdOwner = nil
    }

    func resetForNewSession() {
        resetForNewPage()
        isPaused = false
    }
}
