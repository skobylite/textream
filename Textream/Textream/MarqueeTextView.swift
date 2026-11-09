//
//  MarqueeTextView.swift
//  Textream
//
//  Created by Fatih Kadir Akın on 8.02.2026.
//

import SwiftUI

private let paragraphDividerExtraSpacing: CGFloat = 14
private let paragraphDividerDotSize: CGFloat = 3
private let paragraphDividerDotSpacing: CGFloat = 5
private let paragraphDividerDotOpacity: Double = 0.16
/// WordFlowLayout renders only the lines within this distance of the viewport.
private let wordFlowCullingBuffer: CGFloat = 400
/// A live scroll shorter than this is a nudge, not a peek: the next word ends it.
private let minimumPeekOffset: CGFloat = 8

// MARK: - CJK-aware word splitting

extension Unicode.Scalar {
    var isCJK: Bool {
        let v = value
        return (v >= 0x4E00 && v <= 0x9FFF)    // CJK Unified Ideographs
            || (v >= 0x3400 && v <= 0x4DBF)    // CJK Extension A
            || (v >= 0x20000 && v <= 0x2A6DF)  // CJK Extension B
            || (v >= 0xF900 && v <= 0xFAFF)    // CJK Compatibility Ideographs
            || (v >= 0x3040 && v <= 0x309F)    // Hiragana
            || (v >= 0x30A0 && v <= 0x30FF)    // Katakana
            || (v >= 0xAC00 && v <= 0xD7AF)    // Hangul Syllables
    }
}

/// Splits text into display-ready words. CJK characters (Chinese, Japanese, Korean)
/// are split into individual characters so the flow layout can wrap them properly.
func splitTextIntoWords(_ text: String) -> [String] {
    let tokens = text.replacingOccurrences(of: "\n", with: " ")
        .split(omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
        .map { String($0) }

    var result: [String] = []
    for token in tokens {
        guard token.unicodeScalars.contains(where: { $0.isCJK }) else {
            result.append(token)
            continue
        }
        // Token contains CJK characters — split each CJK char individually;
        // consecutive non-CJK chars (e.g. Latin letters, digits) stay grouped.
        var buffer = ""
        for char in token {
            if char.unicodeScalars.first.map({ $0.isCJK }) == true {
                if !buffer.isEmpty {
                    result.append(buffer)
                    buffer = ""
                }
                result.append(String(char))
            } else {
                buffer.append(char)
            }
        }
        if !buffer.isEmpty {
            result.append(buffer)
        }
    }
    return result
}

/// Returns the word indices that begin a new paragraph. Consecutive and
/// whitespace-only lines collapse into a single visual separator.
func paragraphBreakWordIndices(in text: String) -> Set<Int> {
    let normalizedLineEndings = text
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
    let lines = normalizedLineEndings.split(
        separator: "\n",
        omittingEmptySubsequences: false
    )

    var result = Set<Int>()
    var wordCount = 0
    var hasContent = false
    var hasPendingBreak = false

    for (index, line) in lines.enumerated() {
        let lineWords = splitTextIntoWords(String(line))
        if !lineWords.isEmpty {
            if hasContent && hasPendingBreak {
                result.insert(wordCount)
            }
            wordCount += lineWords.count
            hasContent = true
            hasPendingBreak = false
        }

        if index < lines.count - 1, hasContent {
            hasPendingBreak = true
        }
    }

    return result
}

// MARK: - Data

struct WordItem: Identifiable {
    let id: Int
    let word: String
    let charOffset: Int // char offset of this word in the full text (counting spaces)
    let isAnnotation: Bool // true for [bracket] words and emoji-only words
}

// MARK: - Preference key to report word Y positions

struct WordYPreferenceKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

// MARK: - Shown offset

/// The offset that a prompter view shows now, also while SwiftUI animates
/// it. ShownOffsetEffect writes it on each frame. A look-around reads it to
/// stop a running glide where the text is.
nonisolated final class ShownOffset: @unchecked Sendable {
    private let lock = NSLock()
    private var shown: CGFloat?

    var value: CGFloat? {
        get { lock.withLock { shown } }
        set { lock.withLock { shown = newValue } }
    }
}

/// The y offset of .offset(y:), which also writes the offset that it shows
/// to `shown`.
struct ShownOffsetEffect: GeometryEffect {
    var y: CGFloat
    let shown: ShownOffset

    var animatableData: CGFloat {
        get { y }
        set { y = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        shown.value = y
        return ProjectionTransform(CGAffineTransform(translationX: 0, y: y))
    }
}

// MARK: - Teleprompter

struct SpeechScrollView: View {
    let words: [String]
    let highlightedCharCount: Int
    var font: NSFont = .systemFont(ofSize: 18, weight: .semibold)
    var highlightColor: Color = .white
    var cueColor: Color = .white
    var cueUnreadOpacity: Double = 0.2
    var cueReadOpacity: Double = 0.5
    var onWordTap: ((Int) -> Void)? = nil
    /// Called when user starts/stops manual scrolling in smooth mode.
    /// Bool: true = scrolling started (pause timer), false = scrolling ended (resume timer).
    /// Double: new word progress to resume from (only meaningful when false).
    var onManualScroll: ((Bool, Double) -> Void)? = nil
    var smoothScroll: Bool = false
    /// Continuous word progress (e.g. 3.7 = 70% through 4th word). Drives scroll in smooth mode.
    var smoothWordProgress: Double = 0

    var isListening: Bool = true
    var readingPosition: ReadingPosition = .centered
    /// Optional preview-only transition. Live overlays keep their existing behavior.
    var readingPositionTransitionDuration: Double? = nil
    var paragraphBreakBeforeWordIndices: Set<Int> = []
    /// The session's shared reading position. With it, a look-around scroll
    /// on this screen moves the other screens too (as a word, not pixels).
    /// Nil (the Settings preview) keeps the one-screen behaviour.
    var sharedProgress: SharedScrollProgress? = nil
    @State private var scrollOffset: CGFloat = 0
    @State private var manualOffset: CGFloat = 0
    @State private var wordYPositions: [Int: CGFloat] = [:]
    @State private var containerHeight: CGFloat = 0
    @State private var isUserScrolling: Bool = false
    @State private var stableTopLineCenter: CGFloat?
    @State private var stableLineAdvance: CGFloat?
    @State private var allowsNextBackwardTrackingUpdate = false
    @State private var peekResetGeneration = 0
    @State private var hasAppliedTrackingTarget = false
    @State private var anchoredLayoutWidth: CGFloat = 0
    @State private var anchoredParagraphBreakBeforeWordIndices: Set<Int> = []
    /// The width of the view. trackingWordY lays out the lines with this
    /// width. It is 0 until the view appears.
    @State private var layoutWidth: CGFloat = 0
    /// The highlight that word tracking last followed.
    @State private var trackedCharCount = 0
    @State private var isAnimatingReadingPositionChange = false
    @State private var readingPositionAnimationGeneration = 0
    /// This screen's id as the source of a shared look-around scroll.
    @State private var peekSourceID = UUID()
    /// True while manualOffset shows a look-around scroll made on another
    /// screen.
    @State private var isFollowingPeek = false
    /// The offset that the text shows now (scrollOffset + manualOffset as
    /// SwiftUI animates it).
    @State private var shownOffset = ShownOffset()
    /// Word Tracking: the system uptime of the last quick glide for its own
    /// reason (a tap, a re-read, a catch-up or a glide back). A settle
    /// glide does not change it. See trackingMove.
    @State private var lastQuickGlide: TimeInterval = -.infinity
    /// Word Tracking: true while the last glide of the base used the quick
    /// spring.
    @State private var lastGlideWasQuick = false

    private var readingPositionTransitionAnimation: Animation? {
        guard let duration = readingPositionTransitionDuration, duration > 0 else {
            return nil
        }
        return .smooth(duration: duration, extraBounce: 0)
    }

    private var scrollOffsetAnimation: Animation? {
        if isAnimatingReadingPositionChange {
            return readingPositionTransitionAnimation
        }
        return smoothScroll ? .linear(duration: 0.06) : .easeOut(duration: 0.5)
    }

    var body: some View {
        GeometryReader { geo in
            WordFlowLayout(
                words: words,
                highlightedCharCount: highlightedCharCount,
                font: font,
                highlightColor: highlightColor,
                cueColor: cueColor,
                cueUnreadOpacity: cueUnreadOpacity,
                cueReadOpacity: cueReadOpacity,
                highlightWords: !smoothScroll,
                paragraphBreakBeforeWordIndices: paragraphBreakBeforeWordIndices,
                containerWidth: geo.size.width,
                onWordTap: { charOffset in
                    // Word Tracking: the highlight lands past a [bracket]
                    // annotation, so the scroll aims there too.
                    let landing = smoothScroll
                        ? charOffset
                        : Self.tapLandingOffset(words: words, charOffset: charOffset)
                    let tappedWordIndex = wordIndex(at: landing)
                    peekResetGeneration += 1
                    manualOffset = 0
                    // A tap ends the look-around on every screen.
                    isFollowingPeek = false
                    handlePeekEvent(.tap)
                    if charOffset < highlightedCharCount {
                        allowsNextBackwardTrackingUpdate = true
                    }
                    // The tap moves the view below, so the highlight change
                    // that follows is not a move back to follow again.
                    trackedCharCount = landing
                    onWordTap?(charOffset)
                    // Reposition from the tapped word itself instead of waiting
                    // for the parent progress update. That update can arrive
                    // after a stale recalculation has consumed the one-time
                    // backward allowance.
                    repositionTracking(toWordIndex: tappedWordIndex, charCount: landing)
                },
                scrollOffset: scrollOffset + manualOffset,
                viewportHeight: geo.size.height
            )
            .onPreferenceChange(WordYPreferenceKey.self) { positions in
                let wasEmpty = wordYPositions.isEmpty
                let widthChanged = abs(anchoredLayoutWidth - geo.size.width) > 0.5
                let paragraphLayoutChanged = anchoredParagraphBreakBeforeWordIndices
                    != paragraphBreakBeforeWordIndices
                if widthChanged || paragraphLayoutChanged {
                    hasAppliedTrackingTarget = false
                }
                // This runs before onChange(of: geo.size.width). Give the line
                // layout the new width now, so tracking below uses it. A new
                // view keeps layoutWidth 0 until it appears.
                if layoutWidth > 0, layoutWidth != geo.size.width {
                    layoutWidth = geo.size.width
                }
                captureStableLineMetrics(from: positions)
                wordYPositions = positions
                // Re-anchor after a page switch or any live layout reflow. Keep
                // the stable vertical metrics during width changes: the visible
                // preference values may be culled from the middle of the text.
                // A large width change can cull every line (empty positions);
                // the line layout still gives the reader's line then.
                if (wasEmpty || widthChanged || paragraphLayoutChanged),
                   !positions.isEmpty || layoutWidth > 0 {
                    anchoredLayoutWidth = geo.size.width
                    anchoredParagraphBreakBeforeWordIndices = paragraphBreakBeforeWordIndices
                    recalculateTracking(containerHeight: containerHeight)
                }
            }
            .modifier(ShownOffsetEffect(y: scrollOffset + manualOffset, shown: shownOffset))
            .animation(scrollOffsetAnimation, value: scrollOffset)
            .animation(.easeOut(duration: 0.15), value: manualOffset)
            .onChange(of: geo.size.width, initial: true) { _, newWidth in
                layoutWidth = newWidth
            }
            .onChange(of: geo.size.height) { _, newHeight in
                containerHeight = newHeight
                hasAppliedTrackingTarget = false
                if highlightedCharCount == 0 && smoothWordProgress == 0 {
                    scrollOffset = initialScrollOffset(containerHeight: newHeight)
                } else if isListening {
                    recalculateTracking(containerHeight: newHeight)
                }
            }
            .onChange(of: highlightedCharCount) { _, _ in
                if isListening && !smoothScroll {
                    // Reading progress does not end a live peek (its timer or a
                    // tap does). The tracking base follows the reader and the
                    // peek offset takes up the same distance, so the text
                    // stays still. The next word ends a nudge.
                    let isPeeking = abs(manualOffset) >= minimumPeekOffset
                    // During a look-around on this screen or another one,
                    // write the base and the peek offset in one transaction
                    // with animations off. A write in a transaction of its
                    // own moves the text, and then it glides back.
                    let holdsStill = isPeeking
                        || Self.peekOwner(source: sharedProgress?.peek?.source, this: peekSourceID) == .other
                    let followReader = {
                        if !isPeeking {
                            manualOffset = 0
                        }
                        let baseBefore = scrollOffset
                        recalculateTracking(containerHeight: containerHeight, step: holdsStill ? .still : .reading)
                        if isPeeking {
                            manualOffset -= scrollOffset - baseBefore
                        }
                        handlePeekEvent(.highlightMoved)
                    }
                    if holdsStill {
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction, followReader)
                    } else {
                        followReader()
                    }
                } else if !smoothScroll {
                    // Paused word tracking: the highlight moves only on a
                    // deliberate event, such as a tap on another screen or a
                    // far tap that restarts the recognizer. Follow it.
                    peekResetGeneration += 1
                    manualOffset = 0
                    isFollowingPeek = false
                    handlePeekEvent(.highlightMoved)
                    recalculateTracking(containerHeight: containerHeight)
                }
            }
            .onChange(of: smoothWordProgress) { _, _ in
                // Also while paused: the shared position can move from a tap
                // on another screen, and this screen follows it.
                guard smoothScroll else { return }
                if isFollowingPeek {
                    endFollowedSmoothPeek()
                } else {
                    manualOffset = 0
                    recalculateTracking(containerHeight: containerHeight)
                }
                handlePeekEvent(.smoothProgressMoved)
            }
            .onChange(of: isListening) { _, listening in
                // Pause and resume cancel a pending peek glide back. A paused
                // view stays where the user scrolled it.
                peekResetGeneration += 1
                if listening {
                    manualOffset = 0
                    isFollowingPeek = false
                }
                // Resume ends the look-around on every screen. Pause keeps
                // it, as it keeps it on this screen.
                handlePeekEvent(.listeningChanged, isListening: listening)
                if listening {
                    recalculateTracking(containerHeight: containerHeight)
                }
            }
            .onChange(of: sharedProgress?.peek) { _, _ in
                followSharedPeek()
            }
            .onChange(of: words) { _, _ in
                scrollOffset = initialScrollOffset(containerHeight: containerHeight)
                manualOffset = 0
                wordYPositions = [:]
                stableTopLineCenter = nil
                stableLineAdvance = nil
                allowsNextBackwardTrackingUpdate = false
                hasAppliedTrackingTarget = false
                anchoredLayoutWidth = 0
                anchoredParagraphBreakBeforeWordIndices = []
            }
            .onChange(of: readingPosition) { _, _ in
                manualOffset = 0
                stableTopLineCenter = nil
                stableLineAdvance = nil
                allowsNextBackwardTrackingUpdate = false
                hasAppliedTrackingTarget = false

                if let transitionDuration = readingPositionTransitionDuration {
                    captureStableLineMetrics(from: wordYPositions)
                    readingPositionAnimationGeneration &+= 1
                    let generation = readingPositionAnimationGeneration
                    isAnimatingReadingPositionChange = transitionDuration > 0

                    if let animation = readingPositionTransitionAnimation {
                        withAnimation(animation) {
                            recalculateTracking(containerHeight: containerHeight)
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + transitionDuration) {
                            guard generation == readingPositionAnimationGeneration else { return }
                            isAnimatingReadingPositionChange = false
                        }
                    } else {
                        recalculateTracking(containerHeight: containerHeight)
                    }
                } else {
                    scrollOffset = initialScrollOffset(containerHeight: containerHeight)
                    DispatchQueue.main.async {
                        recalculateTracking(containerHeight: containerHeight)
                    }
                }
            }
            .onAppear {
                containerHeight = geo.size.height
                // A screen that opens, or is rebuilt, during a look-around on
                // another screen shows the shared word at once. onChange of
                // the peek does not run for a value that is already set.
                defer {
                    if let peek = sharedProgress?.peek, peek.source != peekSourceID {
                        if layoutWidth == 0 { layoutWidth = geo.size.width }
                        applyFollowerPeek(peek)
                    }
                }
                // A live view made mid-script (for example when the page
                // picker closes) shows the highlighted line, not the top. The
                // first preference change ran before this with no height, so
                // track again here. Write scrollOffset only once: a second
                // write in this update leaves the word positions stale. A
                // smooth view opened mid-session (a late External display)
                // goes to the shared word in the same way.
                if smoothScroll ? smoothWordProgress > 0 : highlightedCharCount > 0,
                   readingPositionTransitionDuration == nil {
                    layoutWidth = geo.size.width
                    hasAppliedTrackingTarget = false
                    recalculateTracking(containerHeight: containerHeight)
                    if hasAppliedTrackingTarget { return }
                }
                scrollOffset = initialScrollOffset(containerHeight: containerHeight)
            }
            .onDisappear {
                // Never leave the shared hold on when this view goes away
                // during a scroll.
                if smoothScroll && isUserScrolling {
                    isUserScrolling = false
                    onManualScroll?(false, smoothWordProgress)
                }
                handlePeekEvent(.disappear)
            }
            .overlay(
                ScrollWheelView(
                    onScroll: { delta in
                        // Word tracking scrolls live and paused. While live, a
                        // scroll is a peek: it does not fight the tracker, and
                        // it glides back 6 s after the last scroll.
                        let canScroll = smoothScroll ? isListening : true
                        guard canScroll else { return }

                        if !smoothScroll {
                            // Every scroll event cancels the earlier timer, so it
                            // cannot fire during or after this scroll. A mouse
                            // wheel sends no end phase, so the timer starts here.
                            peekResetGeneration += 1
                            if isListening {
                                // A look-around starts where the text is. Else
                                // its first step ends a running glide in 0.15 s,
                                // and the text jumps on by the rest of the glide.
                                if manualOffset == 0, delta != 0 {
                                    holdTextWhereShown()
                                }
                                schedulePeekGlideBack()
                            }
                        }

                        // Pause timer when user scrolls in smooth mode. Report
                        // every event: the hold has one owner screen, and a
                        // tap or a scroll on another screen can take it.
                        if smoothScroll {
                            isUserScrolling = true
                            onManualScroll?(true, 0)
                        }

                        let bounds = manualOffsetBounds(containerHeight: geo.size.height)
                        let newOffset = manualOffset + delta

                        if newOffset > bounds.upper {
                            let over = newOffset - bounds.upper
                            manualOffset = bounds.upper + over * 0.2
                        } else if newOffset < bounds.lower {
                            let over = bounds.lower - newOffset
                            manualOffset = bounds.lower - over * 0.2
                        } else {
                            manualOffset = newOffset
                        }
                        publishSharedPeek()
                    },
                    onScrollEnd: {
                        if smoothScroll && isUserScrolling {
                            isUserScrolling = false
                            // A late end after another screen took over the
                            // scroll: that screen now owns the hold and the
                            // look-around, and this one follows it.
                            let peekEnd = peekDecision(.scrollEnded)
                            if peekEnd.skipsRelease { return }
                            defer { applyPeekDecision(peekEnd) }
                            if scrollKeepsCurrentWord() {
                                // A release that stays near the line of the
                                // word keeps the word. A read from a line gives
                                // its first word, so the shared word would go
                                // back or forward by up to one line.
                                withAnimation(.easeOut(duration: 0.15)) {
                                    manualOffset = 0
                                }
                                onManualScroll?(false, smoothWordProgress)
                                return
                            }
                            // Find the word at the active tracking anchor.
                            let newProgress = wordProgressAtCurrentOffset()
                            if !Self.smoothReleaseChangesProgress(read: newProgress, current: smoothWordProgress, wordCount: words.count) {
                                // The same word, for example a pull past the
                                // top at word 0: the progress does not change,
                                // so no onChange puts the text back. Spring
                                // back to the tracked position here.
                                withAnimation(.easeOut(duration: 0.15)) {
                                    manualOffset = 0
                                }
                                onManualScroll?(false, smoothWordProgress)
                                return
                            }
                            // The text is already where the reader left it, and
                            // the new progress puts the same place at the
                            // reading line. Fold the scroll into the base offset
                            // without animation: two animations on one offset
                            // would add up and jolt the text.
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                scrollOffset += manualOffset
                                manualOffset = 0
                            }
                            allowsNextBackwardTrackingUpdate = true
                            onManualScroll?(false, newProgress)
                        } else if isListening {
                            // Live word tracking: onScroll starts the glide-back
                            // timer, so the end of a gesture changes nothing.
                        } else {
                            let bounds = manualOffsetBounds(containerHeight: geo.size.height)
                            if manualOffset > bounds.upper || manualOffset < bounds.lower {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    manualOffset = min(bounds.upper, max(bounds.lower, manualOffset))
                                }
                                publishSharedPeek()
                            }
                        }
                    }
                )
            )
        }
        .clipped()
        .mask(
            LinearGradient(
                stops: readingPosition == .nearTop
                    ? [
                        .init(color: .white, location: 0),
                        .init(color: .white, location: 0.05),
                        .init(color: .white, location: 0.95),
                        .init(color: .clear, location: 1.0)
                    ]
                    : [
                        .init(color: .clear, location: 0),
                        .init(color: .white, location: 0.05),
                        .init(color: .white, location: 0.95),
                        .init(color: .clear, location: 1.0)
                    ],
                startPoint: .top,
                endPoint: .bottom
            )
            .animation(readingPositionTransitionAnimation, value: readingPosition)
        )
    }

    private func initialScrollOffset(containerHeight: CGFloat) -> CGFloat {
        switch readingPosition {
        case .centered:
            let lineHeight = font.pointSize * 1.4
            return containerHeight * 0.5 - lineHeight * 0.5
        case .nearTop:
            return 0
        }
    }

    /// The range of manualOffset that keeps the rendered position
    /// (scrollOffset + manualOffset) between the top of the script and its
    /// lowest rendered word, wherever tracking is. 0 is always in the range.
    static func manualOffsetBounds(
        scrollOffset: CGFloat,
        topOffset: CGFloat,
        maxWordY: CGFloat,
        containerHeight: CGFloat
    ) -> (lower: CGFloat, upper: CGFloat) {
        let bottomOffset = -max(0, maxWordY - containerHeight * 0.5)
        return (min(0, bottomOffset - scrollOffset), max(0, topOffset - scrollOffset))
    }

    private func manualOffsetBounds(containerHeight: CGFloat) -> (lower: CGFloat, upper: CGFloat) {
        Self.manualOffsetBounds(
            scrollOffset: scrollOffset,
            topOffset: initialScrollOffset(containerHeight: containerHeight),
            maxWordY: wordYPositions.values.max() ?? 0,
            containerHeight: containerHeight
        )
    }

    /// Live word tracking: glide back to the tracked line 6 s after the last
    /// scroll. A newer scroll, a tap, a pause or a resume changes
    /// peekResetGeneration, and that cancels this timer.
    private func schedulePeekGlideBack() {
        let generation = peekResetGeneration
        // Captured now: after a page rebuild this copy's state can be stale.
        let source = peekSourceID
        let shared = sharedProgress
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
            // Read only @State here. The plain properties of this copy still
            // hold their values from when the timer started.
            guard generation == peekResetGeneration else { return }
            // The other screens glide back with this one. The timer runs
            // only in live Word Tracking.
            let decision = Self.peekDecision(
                .glideBackTimer,
                owner: Self.peekOwner(source: shared?.peek?.source, this: source),
                smoothScroll: false,
                isListening: true,
                isFollowing: isFollowingPeek,
                manualOffset: manualOffset
            )
            applyPeekMove(decision.move, peek: shared?.peek)
            applyPeekClear(decision.clear, to: shared, source: source)
        }
    }

    /// Word tracking: end a look-around. Glide back to the tracked line.
    private func glideBackToTrackedLine() {
        isFollowingPeek = false
        // A look-around that starts during a glide holds the base where
        // the text was (holdTextWhereShown). Aim the base at the tracked
        // line again, also back, with the text still: the peek offset takes
        // up the move. So the glide below ends on the tracked line, also
        // when the peek offset is 0 now.
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            let baseBefore = scrollOffset
            allowsNextBackwardTrackingUpdate = true
            recalculateTracking(containerHeight: containerHeight, step: .still)
            manualOffset -= scrollOffset - baseBefore
        }
        guard manualOffset != 0 else { return }
        // Only the lines near the tracked line are rendered at the end, so
        // a longer glide would pass through empty space. Jump instead.
        let glide: Animation? = abs(manualOffset) <= wordFlowCullingBuffer
            ? .easeInOut(duration: 0.4)
            : nil
        var transaction = Transaction(animation: glide)
        // Keep the implicit 0.15 s manualOffset animation from replacing it.
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            manualOffset = 0
        }
        // A reading step during the glide back must not slow it down.
        lastQuickGlide = ProcessInfo.processInfo.systemUptime
    }

    /// Live Word Tracking: stop a running glide where the text is now. A
    /// write with animations off ends the glide, and this one keeps the text
    /// where it is. The next tracking target moves the text on from there.
    /// A glide never has more than wordFlowCullingBuffer to go (a longer
    /// move jumps), so a larger gap is a jump that the shown offset does not
    /// show yet.
    private func holdTextWhereShown() {
        guard let shown = shownOffset.value else { return }
        let base = shown - manualOffset
        let gap = abs(base - scrollOffset)
        guard gap > 0.5, gap <= wordFlowCullingBuffer else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            scrollOffset = base
        }
    }

    // MARK: Shared look-around scroll

    /// The word progress that a scroll on this screen shares: the word at
    /// the reading line, or the current word after a move too small to leave
    /// its line. A smooth-mode release writes the same value.
    private func scrollReadProgress() -> Double {
        scrollKeepsCurrentWord() ? currentScrollWord : wordProgressAtCurrentOffset()
    }

    /// The word that tracking puts at the reading line.
    private var currentScrollWord: Double {
        smoothScroll ? smoothWordProgress : trackingProgress
    }

    private func scrollKeepsCurrentWord() -> Bool {
        if !smoothScroll, layoutWidth > 0 {
            return Self.trackingScrollKeepsWord(manualOffset: manualOffset, minimumMove: minimumPeekOffset)
        }
        return Self.smoothReleaseKeepsWord(
            manualOffset: manualOffset,
            minimumMove: minimumPeekOffset,
            readY: releaseReadLineY() - (scrollOffset + manualOffset),
            wordY: layoutY(forWordProgress: currentScrollWord),
            rowAdvance: WordFlowLayout.rowHeight(for: font) + WordFlowLayout.lineSpacing(for: font)
        )
    }

    /// Word Tracking: true when a scroll keeps the current word progress.
    /// slidProgress gives each height its own progress, so only a nudge (a
    /// trackpad touch that moves the text less than `minimumMove`) keeps it.
    static func trackingScrollKeepsWord(manualOffset: CGFloat, minimumMove: CGFloat) -> Bool {
        abs(manualOffset) < minimumMove
    }

    /// This screen was scrolled: share the word at its reading line.
    private func publishSharedPeek() {
        guard let sharedProgress else { return }
        isFollowingPeek = false
        sharedProgress.publishPeek(scrollReadProgress(), from: peekSourceID)
    }

    /// The shared look-around changed. A look-around from another screen
    /// puts its word at this screen's reading line. When it ends, every
    /// screen goes back to its tracked position.
    private func followSharedPeek() {
        let decision = peekDecision(.sharedChanged)
        // Never follow the echo of this screen's own scroll.
        guard decision.move != .none else { return }
        // This cancels a pending glide back of this screen.
        peekResetGeneration += 1
        applyPeekDecision(decision)
    }

    /// Put the shared word at this screen's reading line, inside the scroll
    /// bounds. The bounds come from the line layout, so a culled line does
    /// not limit a long move.
    private func applyFollowerPeek(_ peek: SharedScrollProgress.Peek) {
        guard let wordY = readingY(forProgress: peek.wordProgress) else { return }
        let bounds = Self.manualOffsetBounds(
            scrollOffset: scrollOffset,
            topOffset: initialScrollOffset(containerHeight: containerHeight),
            maxWordY: trackingWordY(words.count - 1) ?? wordYPositions.values.max() ?? 0,
            containerHeight: containerHeight
        )
        let offset = Self.followerPeekOffset(
            readLineY: releaseReadLineY(),
            wordY: wordY,
            scrollOffset: scrollOffset,
            lower: bounds.lower,
            upper: bounds.upper
        )
        isFollowingPeek = true
        guard offset != manualOffset else { return }
        if abs(offset - manualOffset) > wordFlowCullingBuffer {
            // Only the lines near the target are rendered, so a glide this
            // long would pass through empty space. Jump instead.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                manualOffset = offset
            }
        } else {
            manualOffset = offset
        }
    }

    /// Classic and Voice-Activated follower: the look-around ended. The text
    /// already shows the shared word at the reading line, so move to the
    /// tracked position without animation. Two animations on one offset
    /// would add up and jolt the text.
    private func endFollowedSmoothPeek() {
        isFollowingPeek = false
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            scrollOffset += manualOffset
            manualOffset = 0
            allowsNextBackwardTrackingUpdate = true
            recalculateTracking(containerHeight: containerHeight)
        }
    }

    /// The manualOffset that puts a word at layout Y `wordY` on the read line
    /// `readLineY` of a view with base offset `scrollOffset`, inside the
    /// bounds of manualOffsetBounds.
    static func followerPeekOffset(
        readLineY: CGFloat,
        wordY: CGFloat,
        scrollOffset: CGFloat,
        lower: CGFloat,
        upper: CGFloat
    ) -> CGFloat {
        min(upper, max(lower, readLineY - wordY - scrollOffset))
    }

    /// Who started the shared look-around, seen from one screen.
    enum PeekOwner { case none, this, other }

    static func peekOwner(source: UUID?, this: UUID) -> PeekOwner {
        guard let source else { return .none }
        return source == this ? .this : .other
    }

    /// An event at which a screen can follow or end the shared look-around.
    enum PeekEvent {
        /// A tap on a word of this screen.
        case tap
        /// Word Tracking moved the highlight. Live: after this screen
        /// tracked it (a nudge offset is already 0). Paused: a deliberate move.
        case highlightMoved
        /// Classic or Voice-Activated moved the shared word progress.
        case smoothProgressMoved
        /// Resume (isListening true) or pause (false).
        case listeningChanged
        /// A Classic or Voice-Activated scroll on this screen ended.
        case scrollEnded
        /// The 6 s Word Tracking glide-back timer of this screen fired.
        case glideBackTimer
        /// This screen goes away.
        case disappear
        /// The shared look-around changed.
        case sharedChanged
    }

    /// What one screen does with the shared look-around at a PeekEvent.
    struct PeekDecision: Equatable {
        /// keep: leave it. all: end it on every screen. own: end it only
        /// when this screen is its source (a late end changes nothing).
        enum Clear { case keep, all, own }
        enum Move {
            case none
            /// Put the shared word at this screen's reading line.
            case follow
            /// Word Tracking: glide back to the tracked line.
            case glideBack
            /// Classic/Voice-Activated follower: fold the followed offset into
            /// the base offset without animation.
            case foldFollowed
            /// Classic/Voice-Activated: drop the scroll offset.
            case reset
        }
        var clear: Clear = .keep
        var move: Move = .none
        /// Another screen took over the scroll: skip this screen's release.
        var skipsRelease = false
    }

    /// The shared look-around rules of one screen. `manualOffset` is the
    /// offset after the event's own local change.
    static func peekDecision(
        _ event: PeekEvent,
        owner: PeekOwner,
        smoothScroll: Bool,
        isListening: Bool,
        isFollowing: Bool,
        manualOffset: CGFloat
    ) -> PeekDecision {
        switch event {
        case .tap:
            return PeekDecision(clear: .all)
        case .highlightMoved:
            guard !smoothScroll else { return PeekDecision() }
            guard isListening else { return PeekDecision(clear: .all) }
            switch owner {
            case .other: return PeekDecision(move: .follow)
            // The next word ended this screen's nudge: end it everywhere.
            case .this: return manualOffset == 0 ? PeekDecision(clear: .own) : PeekDecision()
            case .none: return PeekDecision()
            }
        case .smoothProgressMoved:
            return smoothScroll && owner == .other ? PeekDecision(move: .follow) : PeekDecision()
        case .listeningChanged:
            return isListening ? PeekDecision(clear: .all) : PeekDecision()
        case .scrollEnded:
            guard smoothScroll else { return PeekDecision() }
            return owner == .other ? PeekDecision(skipsRelease: true) : PeekDecision(clear: .own)
        case .glideBackTimer:
            return PeekDecision(clear: .own, move: .glideBack)
        case .disappear:
            return PeekDecision(clear: .own)
        case .sharedChanged:
            switch owner {
            case .other: return PeekDecision(move: .follow)
            case .this: return PeekDecision()
            case .none:
                if !smoothScroll { return PeekDecision(move: .glideBack) }
                return PeekDecision(move: isFollowing ? .foldFollowed : .reset)
            }
        }
    }

    private func peekDecision(_ event: PeekEvent, isListening listening: Bool? = nil) -> PeekDecision {
        Self.peekDecision(
            event,
            owner: Self.peekOwner(source: sharedProgress?.peek?.source, this: peekSourceID),
            smoothScroll: smoothScroll,
            isListening: listening ?? isListening,
            isFollowing: isFollowingPeek,
            manualOffset: manualOffset
        )
    }

    private func applyPeekDecision(_ decision: PeekDecision) {
        applyPeekMove(decision.move, peek: sharedProgress?.peek)
        applyPeekClear(decision.clear, to: sharedProgress, source: peekSourceID)
    }

    private func handlePeekEvent(_ event: PeekEvent, isListening listening: Bool? = nil) {
        applyPeekDecision(peekDecision(event, isListening: listening))
    }

    private func applyPeekMove(_ move: PeekDecision.Move, peek: SharedScrollProgress.Peek?) {
        switch move {
        case .none: break
        case .follow: if let peek { applyFollowerPeek(peek) }
        case .glideBack: glideBackToTrackedLine()
        case .foldFollowed: endFollowedSmoothPeek()
        case .reset:
            isFollowingPeek = false
            manualOffset = 0
        }
    }

    private func applyPeekClear(_ clear: PeekDecision.Clear, to shared: SharedScrollProgress?, source: UUID) {
        switch clear {
        case .keep: break
        case .all: shared?.clearPeek()
        case .own: shared?.clearPeek(from: source)
        }
    }

    /// `step` tells Word Tracking what moved the target, which picks its
    /// animation (see trackingMove).
    private func recalculateTracking(containerHeight: CGFloat, step: TrackingStep = .other) {
        // The highlight moves back only on deliberate events: a confirmed
        // re-read, a tap in another view, a new session or a text edit. The
        // view follows such a move, however short it is.
        let highlightMovedBack = highlightedCharCount < trackedCharCount
        // Word Tracking: the words that this step adds (see trackingMove).
        let words = smoothScroll ? 0 : trackingProgress - trackingProgress(atCharCount: trackedCharCount)
        trackedCharCount = highlightedCharCount

        if readingPosition == .nearTop {
            recalcTopWithPreviousLine(highlightMovedBack: highlightMovedBack, step: step, words: words)
            return
        }

        let center = containerHeight * 0.5

        if smoothScroll {
            // Classic/silence-paused: keep the active word on the reading line
            // (0.8h, see smoothReadingAnchor), scrolling up.
            // The line layout gives the word also when its line is culled.
            guard let interpolatedY = layoutY(forWordProgress: smoothWordProgress) else { return }
            applyTrackingTarget(
                Self.smoothCenteredTarget(
                    anchor: activeReadingLineY(containerHeight: containerHeight),
                    wordY: interpolatedY,
                    topOffset: initialScrollOffset(containerHeight: containerHeight)
                ),
                followsBack: highlightMovedBack
            )
        } else {
            // Word tracking: the reading Y slides along the line of the
            // active word, and it sits at the vertical center.
            if let wordY = readingY(forProgress: trackingProgress) {
                applyTrackingTarget(
                    Self.wordTrackingTarget(lineY: wordY, readingLineY: center, nearTop: false),
                    followsBack: highlightMovedBack,
                    step: step,
                    words: words
                )
            }
        }
    }

    private func recalcTopWithPreviousLine(highlightMovedBack: Bool, step: TrackingStep, words: Double) {
        if smoothScroll {
            guard let interpolatedY = layoutY(forWordProgress: smoothWordProgress) else { return }
            let target = min(interpolatedY, topReadingAnchor) - interpolatedY
            applyTrackingTarget(target, followsBack: highlightMovedBack)
        } else {
            guard let wordY = readingY(forProgress: trackingProgress) else { return }
            applyTrackingTarget(
                Self.wordTrackingTarget(lineY: wordY, readingLineY: topReadingAnchor, nearTop: true),
                followsBack: highlightMovedBack,
                step: step,
                words: words
            )
        }
    }

    /// Word Tracking: the words read so far, from the highlight (3.5 is
    /// half of word 3). The highlight at the start of word 4 gives 4.
    private var trackingProgress: Double {
        trackingProgress(atCharCount: highlightedCharCount)
    }

    /// The words read at highlight `charCount`, as trackingProgress.
    private func trackingProgress(atCharCount charCount: Int) -> Double {
        let (index, fraction) = activeWordFraction(charCount)
        return Double(index) + fraction
    }

    /// Word Tracking: the line midY of every word, from the line layout. Nil
    /// before the view has a width.
    private func trackingLineYs() -> [CGFloat]? {
        guard layoutWidth > 0 else { return nil }
        let lineYs = WordFlowLayout(
            words: words,
            highlightedCharCount: highlightedCharCount,
            font: font,
            paragraphBreakBeforeWordIndices: paragraphBreakBeforeWordIndices,
            containerWidth: layoutWidth
        ).wordMidYs()
        return !lineYs.isEmpty && lineYs.count == words.count ? lineYs : nil
    }

    /// The layout Y that tracking puts on the reading line at word progress
    /// `progress`. Word Tracking slides it along the line (slidLineY), so
    /// tracking, a look-around read and a follower all use one map. Classic
    /// and Voice-Activated use smoothLayoutY.
    private func readingY(forProgress progress: Double) -> CGFloat? {
        if !smoothScroll, let lineYs = trackingLineYs() {
            return Self.slidLineY(progress: progress, lineYs: lineYs)
        }
        return layoutY(forWordProgress: progress)
    }

    /// The Y of a word for word tracking, from the line layout. The measured
    /// positions are only a fallback: while the text scrolls, they are off by
    /// the distance that the scroll still has to go, and a word that is not
    /// rendered has none.
    private func trackingWordY(_ wordIndex: Int) -> CGFloat? {
        if layoutWidth > 0, let layoutY = WordFlowLayout(
            words: words,
            highlightedCharCount: highlightedCharCount,
            font: font,
            paragraphBreakBeforeWordIndices: paragraphBreakBeforeWordIndices,
            containerWidth: layoutWidth
        ).midY(ofWordAt: wordIndex) {
            return layoutY
        }
        return wordYPositions[wordIndex]
    }

    /// The Y of a fractional word progress for smooth scrolling, from the line
    /// layout: between the word and the next one.
    private func layoutY(forWordProgress progress: Double) -> CGFloat? {
        Self.smoothLayoutY(progress: progress, wordCount: words.count, wordY: trackingWordY)
    }

    /// The Y of a fractional word progress, between the Y of the word and
    /// the Y of the next one. `wordY` gives the Y of a word index.
    static func smoothLayoutY(progress: Double, wordCount: Int, wordY: (Int) -> CGFloat?) -> CGFloat? {
        let wordIdx = Int(progress)
        let fraction = progress - Double(wordIdx)
        let clampedIdx = max(0, min(wordIdx, wordCount - 1))
        guard let y = wordY(clampedIdx) else { return nil }
        let nextY = wordY(clampedIdx + 1) ?? y
        return y + (nextY - y) * CGFloat(fraction)
    }

    // MARK: Word Tracking scroll target

    /// Word Tracking: the response in seconds of the no-bounce spring that
    /// moves the text for a reading step. ScrollTargetTests chose it with a
    /// model of made-up readings: with a shorter spring the text stops and
    /// starts again between results. A longer one leaves the text further
    /// behind the reader.
    static let readingSpringResponse: Double = 3.5

    /// Word Tracking: the response in seconds of the no-bounce spring for
    /// every other glide (a tap, a re-read, a catch-up, a resume or a new
    /// layout). It ends in about 0.5 s, as the 0.5 s ease-out did.
    static let quickSpringResponse: Double = 0.5

    /// Word Tracking: a reading step this soon (in seconds) after a quick
    /// glide for its own reason or a glide back is quick too: a settle
    /// glide. A slow spring that takes over a fast glide keeps its speed,
    /// so it would carry the text past the target and back. A settle glide
    /// does not start this time again.
    static let quickGlideSettle: Double = 0.8

    /// Word Tracking: true when a quick glide that still has `left` to go
    /// is too fast for the reading spring to take over a step of `step`.
    /// The spring that takes over keeps the speed of the glide. A quick
    /// glide moves at less than 2π / quickSpringResponse times the distance
    /// that it has left. So when it has at most a sixth of the step left
    /// (quickSpringResponse / (readingSpringResponse - quickSpringResponse)),
    /// the reading spring does not carry the text past the new target.
    static func quickGlideTooFast(left: CGFloat, step: CGFloat) -> Bool {
        left * CGFloat(readingSpringResponse - quickSpringResponse) > step * CGFloat(quickSpringResponse)
    }

    /// Word Tracking: a forward step of more words than this is not one
    /// result of normal reading (results bring 1 to 5 words). It is a
    /// catch-up after a hold, the undo of a wrong re-read or a resume after
    /// an ad-lib, and it takes the quick spring.
    static let readingStepWords: Double = 5

    /// Word Tracking: the layout Y that tracking puts on the reading line at
    /// word progress `progress` (the words read: 3.5 is half of word 3). The
    /// Y slides along each line as the reader moves through it: from the
    /// line's own Y, at its first word, to the next line's Y, after its last
    /// word. The last line stays at its own Y. The Y never goes back at a
    /// new line. The reading spring keeps the text about half a line behind
    /// this target while the reader speaks, so the line being read stays
    /// near the reading line. `lineYs` has the line midY of each word
    /// (WordFlowLayout.perWordMidYs).
    static func slidLineY(progress: Double, lineYs: [CGFloat]) -> CGFloat? {
        guard !lineYs.isEmpty, progress.isFinite else { return nil }
        let count = lineYs.count
        let clamped = min(max(progress, 0), Double(count))
        let word = min(Int(clamped), count - 1)
        let y = lineYs[word]
        var first = word
        while first > 0, lineYs[first - 1] == y { first -= 1 }
        var end = word + 1
        while end < count, lineYs[end] == y { end += 1 }
        let next = end < count ? lineYs[end] : y
        let fraction = CGFloat((clamped - Double(first)) / Double(end - first))
        return y + (next - y) * fraction
    }

    /// Word Tracking: the word progress whose slidLineY is `y`. A Y above
    /// the first line gives 0, and a Y on or below the last line gives the
    /// word count. A look-around read uses it, so every screen puts the same
    /// place on its reading line.
    static func slidProgress(atY y: CGFloat, lineYs: [CGFloat]) -> Double? {
        guard let firstY = lineYs.first, let lastY = lineYs.last else { return nil }
        if y <= firstY { return 0 }
        if y >= lastY { return Double(lineYs.count) }
        var first = 0
        while first < lineYs.count {
            let lineY = lineYs[first]
            var end = first + 1
            while end < lineYs.count, lineYs[end] == lineY { end += 1 }
            guard end < lineYs.count else { break }
            let next = lineYs[end]
            if y < next {
                let fraction = (y - lineY) / (next - lineY)
                return Double(first) + Double(end - first) * Double(min(1, max(0, fraction)))
            }
            first = end
        }
        return Double(lineYs.count)
    }

    /// Word Tracking: the scroll offset that puts layout Y `lineY` (from
    /// slidLineY) on the reading line `readingLineY`. Near Top keeps the
    /// text at the top until that Y reaches the reading line.
    static func wordTrackingTarget(lineY: CGFloat, readingLineY: CGFloat, nearTop: Bool) -> CGFloat {
        nearTop ? min(lineY, readingLineY) - lineY : readingLineY - lineY
    }

    /// What asks Word Tracking for a new scroll target.
    enum TrackingStep {
        /// The live highlight moved, and no look-around shows.
        case reading
        /// The live highlight moved during a look-around. The caller writes
        /// the base and the peek offset in one transaction with animations
        /// off, so the text stays still.
        case still
        /// Any other change: a tap, a pause, a resume, a page or a layout.
        case other
    }

    /// How applyTrackingTarget shows a new tracking target.
    enum TrackingMove: Equatable {
        /// Not applied: a short move back that no deliberate event asked for.
        case skip
        /// Applied at once, in a transaction of its own.
        case jump
        /// Applied with the slow reading spring.
        case readingGlide
        /// Word Tracking: applied with the quick spring.
        case quickGlide
        /// Word Tracking: a reading step that takes the quick spring only
        /// because a quick glide may still run (`settling`). It does not
        /// start the settle time again.
        case settleGlide
        /// A plain write: Classic and Voice-Activated (scrollOffsetAnimation
        /// applies), or the caller's transaction during a look-around.
        case plain
    }

    /// The tracking rules. Normal reading moves the text only forward. A
    /// `deliberate` move (a re-read, a tap or a new layout) or one that
    /// `allowsBack` is followed in either direction, and so is a move back
    /// of more than `regressionThreshold`. In Word Tracking, a move of more
    /// than `jumpLimit` is a jump with no animation. A forward reading step
    /// that adds `words` (more than 0, at most readingStepWords) glides with
    /// the reading spring. While a quick glide may still run (`settling`),
    /// such a step is a settle glide. Every other move takes the quick
    /// spring.
    static func trackingMove(
        from current: CGFloat,
        to target: CGFloat,
        step: TrackingStep,
        words: Double,
        deliberate: Bool,
        allowsBack: Bool,
        settling: Bool,
        regressionThreshold: CGFloat,
        jumpLimit: CGFloat,
        smoothScroll: Bool
    ) -> TrackingMove {
        let applies = deliberate
            || allowsBack
            || target < current - 1
            || target > current + regressionThreshold
        guard applies else { return .skip }
        if smoothScroll || step == .still { return .plain }
        if abs(target - current) > jumpLimit { return .jump }
        if step == .reading, !deliberate, target < current,
           words > 0, words <= readingStepWords {
            return settling ? .settleGlide : .readingGlide
        }
        return .quickGlide
    }

    /// The height in this view where the active word sits.
    private func activeReadingLineY(containerHeight: CGFloat) -> CGFloat {
        Self.readingLineY(
            containerHeight: containerHeight,
            smoothScroll: smoothScroll,
            nearTop: readingPosition == .nearTop,
            topAnchor: topReadingAnchor
        )
    }

    /// The height in this view where a smooth scroll release reads the word:
    /// the reading line, or the current word while the start clamp of
    /// smoothCenteredTarget holds the text.
    private func releaseReadLineY() -> CGFloat {
        let line = activeReadingLineY(containerHeight: containerHeight)
        guard smoothScroll, readingPosition == .centered else { return line }
        return Self.smoothReadLineY(
            anchor: line,
            wordY: layoutY(forWordProgress: smoothWordProgress),
            topOffset: initialScrollOffset(containerHeight: containerHeight)
        )
    }

    /// Classic and Voice-Activated, Centered: the active word sits this high.
    /// 0.8h on every screen taller than 100 pt, so the notch, the floating
    /// window and the External read at the same height. 20 pt from the bottom
    /// on smaller screens.
    static func smoothReadingAnchor(containerHeight: CGFloat) -> CGFloat {
        containerHeight - max(20, containerHeight * 0.2)
    }

    /// Classic and Voice-Activated, Centered: the scroll offset that puts a
    /// word at layout Y `wordY` on the reading line `anchor`, but never lower
    /// than the start offset `topOffset`. At the start of a page the text
    /// stays with line 0 near the centre, and it starts to move when the word
    /// reaches the reading line.
    static func smoothCenteredTarget(anchor: CGFloat, wordY: CGFloat, topOffset: CGFloat) -> CGFloat {
        min(anchor - wordY, topOffset)
    }

    /// Classic and Voice-Activated, Centered: the screen height where a scroll
    /// release reads the word. While smoothCenteredTarget holds the text at
    /// `topOffset`, the current word (layout Y `wordY`) sits above `anchor`, at
    /// wordY + topOffset. A release reads there, so it does not jump forward
    /// by the rows between the word and the reading line.
    static func smoothReadLineY(anchor: CGFloat, wordY: CGFloat?, topOffset: CGFloat) -> CGFloat {
        guard let wordY else { return anchor }
        return min(anchor, wordY + topOffset)
    }

    /// The one reading line of a view: the line that tracking puts the active
    /// word on, and where a scroll release reads the word.
    static func readingLineY(
        containerHeight: CGFloat,
        smoothScroll: Bool,
        nearTop: Bool,
        topAnchor: CGFloat
    ) -> CGFloat {
        if nearTop { return topAnchor }
        return smoothScroll
            ? smoothReadingAnchor(containerHeight: containerHeight)
            : containerHeight * 0.5
    }

    /// The fractional word progress at height `atY`, from word Y positions
    /// sorted by word index.
    static func wordProgress(atY targetY: CGFloat, positions sorted: [(Int, CGFloat)], wordCount: Int, fallback: Double) -> Double {
        // Find the closest word and interpolate
        guard !sorted.isEmpty else { return fallback }

        for i in 0..<sorted.count {
            let (wordIdx, wordY) = sorted[i]
            if i + 1 < sorted.count {
                let (_, nextY) = sorted[i + 1]
                if targetY >= wordY && targetY <= nextY {
                    let frac = (nextY - wordY) > 0 ? Double(targetY - wordY) / Double(nextY - wordY) : 0
                    return Double(wordIdx) + frac
                }
            } else if targetY >= wordY {
                return Double(wordIdx)
            }
        }
        // If scrolled above all words, return 0
        if targetY < (sorted.first?.1 ?? 0) {
            return 0
        }
        return Double(wordCount)
    }

    /// Smooth scroll release: true when the word read at the reading line,
    /// clamped as SharedScrollProgress.endHold clamps it, differs from the
    /// current word. When it does not, the progress does not change and no
    /// onChange puts the text back, so the release must spring back itself.
    static func smoothReleaseChangesProgress(read: Double, current: Double, wordCount: Int) -> Bool {
        max(0, min(Double(wordCount), read)) != current
    }

    /// Smooth scroll release: true keeps the current word, false takes the
    /// word read at the reading line. A touch that moved the text less than
    /// `minimumMove` (a trackpad touch with no real move) keeps it. A release
    /// whose reading line (`readY`, in layout space) is less than half a row
    /// from `wordY`, the layout Y of the current word, also keeps it: one
    /// mouse-wheel notch is 10 px. Words on one line share a Y, so a read from
    /// that line gives its first or last word, and every screen would go back
    /// or forward by up to one line.
    static func smoothReleaseKeepsWord(
        manualOffset: CGFloat,
        minimumMove: CGFloat,
        readY: CGFloat,
        wordY: CGFloat?,
        rowAdvance: CGFloat
    ) -> Bool {
        if abs(manualOffset) < minimumMove { return true }
        guard let wordY else { return false }
        return abs(readY - wordY) < rowAdvance / 2
    }

    private func repositionTracking(toWordIndex wordIndex: Int, charCount: Int) {
        // Word Tracking aims at the slid Y of the highlight that the tap
        // sets (`charCount`), as tracking does. So the highlight update that
        // follows the tap does not move the text again.
        let wordY = smoothScroll
            ? trackingWordY(wordIndex)
            : readingY(forProgress: trackingProgress(atCharCount: charCount))
        guard let wordY else { return }

        let target: CGFloat
        switch readingPosition {
        case .centered where smoothScroll:
            target = Self.smoothCenteredTarget(
                anchor: activeReadingLineY(containerHeight: containerHeight),
                wordY: wordY,
                topOffset: initialScrollOffset(containerHeight: containerHeight)
            )
        case .centered, .nearTop:
            target = Self.wordTrackingTarget(
                lineY: wordY,
                readingLineY: activeReadingLineY(containerHeight: containerHeight),
                nearTop: readingPosition == .nearTop
            )
        }

        applyTrackingTarget(target, force: true)
    }

    /// Word Tracking: the highlight that a tap at `charOffset` sets. The
    /// recognizer's jumpTo skips a [bracket] annotation, so a tap on one
    /// lands on the next word that the reader says.
    static func tapLandingOffset(words: [String], charOffset: Int) -> Int {
        let text = words.joined(separator: " ")
        return SpeechTextAlignment.advancePastAnnotations(
            in: text,
            ranges: SpeechTextAlignment.annotationRanges(in: text),
            from: max(0, min(charOffset, text.count))
        )
    }

    private var topReadingAnchor: CGFloat {
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let fallbackAdvance = lineHeight + (lineHeight / font.pointSize > 1.5 ? 2 : 8)

        // The live notch briefly returns to offset zero before measuring Near Top,
        // so it always captures the document's first two rows. The animated
        // preview cannot do that without visibly jumping through the beginning.
        // Use the equivalent row geometry directly instead of treating the
        // first currently rendered (and possibly culled) row as line zero.
        if readingPositionTransitionDuration != nil {
            return lineHeight * 0.5 + fallbackAdvance
        }

        return (stableTopLineCenter ?? lineHeight * 0.5)
            + (stableLineAdvance ?? fallbackAdvance)
    }

    /// Capture the actual row geometry once, before visibility culling changes
    /// which word frames participate in the preference dictionary.
    private func captureStableLineMetrics(from positions: [Int: CGFloat]) {
        guard readingPosition == .nearTop,
              stableTopLineCenter == nil || stableLineAdvance == nil else { return }

        let positionedWords = positions.sorted { $0.value < $1.value }
        let measuredLines = positionedWords.reduce(into: [(y: CGFloat, wordIDs: [Int])]()) { result, entry in
            if let lastIndex = result.indices.last,
               abs(result[lastIndex].y - entry.value) <= 0.5 {
                result[lastIndex].wordIDs.append(entry.key)
            } else {
                result.append((y: entry.value, wordIDs: [entry.key]))
            }
        }
        guard let firstLineY = measuredLines.first?.y else { return }
        if stableTopLineCenter == nil {
            stableTopLineCenter = firstLineY
        }
        if stableLineAdvance == nil, measuredLines.count > 1 {
            for index in 1..<measuredLines.count {
                let firstWordID = measuredLines[index].wordIDs.min() ?? -1
                guard !paragraphBreakBeforeWordIndices.contains(firstWordID) else { continue }
                stableLineAdvance = measuredLines[index].y - measuredLines[index - 1].y
                break
            }
        }
    }

    /// Normal reading progress may only move the text upward. Brief backward
    /// corrections from speech recognition must not produce a down/up bounce.
    /// Explicit taps and manual scrolling opt into one backward reposition,
    /// and a highlight that moved back is followed in either direction.
    private func applyTrackingTarget(
        _ target: CGFloat,
        force: Bool = false,
        followsBack: Bool = false,
        step: TrackingStep = .other,
        words: Double = 0
    ) {
        // Other backward targets come from measured positions (smooth
        // scrolling) or from a layout change, such as a smaller font. Follow
        // only a large one.
        let regressionThreshold = (stableLineAdvance ?? 40) * 0.9
        let now = ProcessInfo.processInfo.systemUptime
        // A quick glide may still run in the settle time, and also after
        // it: a settle glide late in the settle time still moves fast when
        // the next result comes soon after it.
        let left = abs((shownOffset.value ?? scrollOffset + manualOffset) - (scrollOffset + manualOffset))
        let move = Self.trackingMove(
            from: scrollOffset,
            to: target,
            step: step,
            words: words,
            deliberate: followsBack || force || !hasAppliedTrackingTarget,
            allowsBack: allowsNextBackwardTrackingUpdate,
            settling: now - lastQuickGlide < Self.quickGlideSettle
                || (lastGlideWasQuick && Self.quickGlideTooFast(left: left, step: abs(target - scrollOffset))),
            regressionThreshold: regressionThreshold,
            jumpLimit: wordFlowCullingBuffer,
            smoothScroll: smoothScroll
        )
        switch move {
        case .skip:
            break
        case .jump:
            // Only the lines near the target are rendered, so a glide
            // this long would pass through empty space. Jump instead.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                scrollOffset = target
            }
        case .readingGlide:
            // A spring that replaces a running spring keeps its speed, so
            // the reading steps join into one movement.
            lastGlideWasQuick = false
            glide(to: target, response: Self.readingSpringResponse)
        case .quickGlide, .settleGlide:
            // Only a move that is quick for its own reason starts the
            // settle time. Else each result in it starts it again, and the
            // text stops at each result.
            if move == .quickGlide { lastQuickGlide = now }
            lastGlideWasQuick = true
            if isAnimatingReadingPositionChange {
                // The Settings preview moves to a new reading position with
                // its own curve.
                scrollOffset = target
            } else {
                glide(to: target, response: Self.quickSpringResponse)
            }
        case .plain:
            scrollOffset = target
        }
        hasAppliedTrackingTarget = true
        allowsNextBackwardTrackingUpdate = false
    }

    /// Word Tracking: move the base to `target` with a spring with no
    /// bounce. The spring replaces the glide that runs, from where the text
    /// is. Animations off keep the implicit 0.5 s curve from replacing it.
    private func glide(to target: CGFloat, response: Double) {
        var transaction = Transaction(animation: .spring(response: response, dampingFraction: 1))
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            scrollOffset = target
        }
    }

    private func wordIndex(at charOffset: Int) -> Int {
        var offset = 0
        for (index, word) in words.enumerated() {
            let end = offset + word.count
            if charOffset <= end { return index }
            offset = end + 1
        }
        return max(0, words.count - 1)
    }

    /// Find the word progress at the current visual position (scrollOffset + manualOffset)
    private func wordProgressAtCurrentOffset() -> Double {
        let targetY = releaseReadLineY() - (scrollOffset + manualOffset)
        // Word Tracking: the inverse of the slid reading Y, so a follower
        // puts the same place on its own reading line.
        if !smoothScroll, let lineYs = trackingLineYs(),
           let progress = Self.slidProgress(atY: targetY, lineYs: lineYs) {
            return progress
        }
        // The line layout has every word, also on culled lines. The measured
        // positions are a fallback before the view has a width.
        let positions: [(Int, CGFloat)]
        if layoutWidth > 0 {
            positions = WordFlowLayout(
                words: words,
                highlightedCharCount: highlightedCharCount,
                font: font,
                paragraphBreakBeforeWordIndices: paragraphBreakBeforeWordIndices,
                containerWidth: layoutWidth
            ).wordMidYs().enumerated().map { ($0.offset, $0.element) }
        } else {
            positions = wordYPositions.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        }
        return Self.wordProgress(
            atY: targetY,
            positions: positions,
            wordCount: words.count,
            fallback: smoothWordProgress
        )
    }

    /// Returns (wordIndex, fractionThroughWord) at highlight `charCount`.
    private func activeWordFraction(_ charCount: Int) -> (Int, Double) {
        var offset = 0
        for (i, word) in words.enumerated() {
            let end = offset + word.count
            if charCount <= end {
                let wordLen = max(1, word.count)
                let into = charCount - offset
                return (i, Double(into) / Double(wordLen))
            }
            offset = end + 1
        }
        return (max(0, words.count - 1), 1.0)
    }
}

// MARK: - Word Flow Layout

struct WordFlowLayout: View {
    let words: [String]
    let highlightedCharCount: Int
    let font: NSFont
    var highlightColor: Color = .white
    var cueColor: Color = .white
    var cueUnreadOpacity: Double = 0.2
    var cueReadOpacity: Double = 0.5
    var highlightWords: Bool = true
    var paragraphBreakBeforeWordIndices: Set<Int> = []
    let containerWidth: CGFloat
    var onWordTap: ((Int) -> Void)? = nil
    var scrollOffset: CGFloat = 0
    var viewportHeight: CGFloat = 0

    // Compute line spacing based on font metrics — fonts with large built-in
    // line height (e.g. OpenDyslexic) need less extra spacing
    private var lineSpacing: CGFloat { Self.lineSpacing(for: font) }

    static func lineSpacing(for font: NSFont) -> CGFloat {
        let intrinsicHeight = font.ascender - font.descender + font.leading
        let ratio = intrinsicHeight / font.pointSize
        // System fonts: ratio ~1.2, OpenDyslexic: ratio ~1.7+
        return ratio > 1.5 ? 2 : 8
    }

    /// Height of one row of text. body gives every row this height, so the
    /// culling spacers and layoutMidY match the rendered rows.
    static func rowHeight(for font: NSFont) -> CGFloat {
        (font.ascender - font.descender + font.leading).rounded(.up)
    }

    /// The midY that the view of word `wordIndex` reports in "flowLayout"
    /// space, computed as body places the rows: lineTop, the paragraph
    /// divider space, then half a row. Nil when no line holds the word.
    static func layoutMidY(
        ofWordAt wordIndex: Int,
        lines: [[WordItem]],
        paragraphPrefixCounts: [Int],
        rowHeight: CGFloat,
        lineSpacing: CGFloat,
        paragraphSpacing: CGFloat
    ) -> CGFloat? {
        guard let lineIndex = lines.firstIndex(where: { ($0.last?.id ?? -1) >= wordIndex }),
              let firstWord = lines[lineIndex].first, firstWord.id <= wordIndex,
              lineIndex + 1 < paragraphPrefixCounts.count else { return nil }
        return lineMidY(
            lineIndex,
            paragraphPrefixCounts: paragraphPrefixCounts,
            rowHeight: rowHeight,
            lineSpacing: lineSpacing,
            paragraphSpacing: paragraphSpacing
        )
    }

    /// The midY of line `lineIndex`, as body places it: lineTop, the
    /// paragraph divider space, then half a row.
    static func lineMidY(
        _ lineIndex: Int,
        paragraphPrefixCounts: [Int],
        rowHeight: CGFloat,
        lineSpacing: CGFloat,
        paragraphSpacing: CGFloat
    ) -> CGFloat {
        let beginsParagraph = paragraphPrefixCounts[lineIndex + 1]
            > paragraphPrefixCounts[lineIndex]
        return CGFloat(lineIndex) * (rowHeight + lineSpacing)
            + CGFloat(paragraphPrefixCounts[lineIndex]) * paragraphSpacing
            + (beginsParagraph ? paragraphSpacing : 0)
            + rowHeight * 0.5
    }

    // Layout cache to avoid re-measuring words on every highlight update.
    // Several entries, because every prompter screen (overlay and External
    // display, each with its own font and width) reads it on each tick.
    private static var _layoutCache: [String: ([WordItem], [[WordItem]], [Int])] = [:]
    private static let layoutCacheLimit = 4

    private func cachedLayout() -> ([WordItem], [[WordItem]], [Int]) {
        let paragraphKey = paragraphBreakBeforeWordIndices.sorted()
            .map(String.init)
            .joined(separator: ",")
        let key = "\(words.count)|\(words.first ?? "")|\(words.last ?? "")|"
            + "\(font.fontName)|\(font.pointSize)|\(Int(containerWidth))|\(paragraphKey)"
        if let cached = Self._layoutCache[key] {
            return cached
        }
        let items = buildItems()
        let lines = buildLines(items: items)
        var paragraphPrefixCounts = [0]
        for line in lines {
            let beginsParagraph = line.first.map {
                paragraphBreakBeforeWordIndices.contains($0.id)
            } ?? false
            paragraphPrefixCounts.append(
                paragraphPrefixCounts[paragraphPrefixCounts.count - 1] + (beginsParagraph ? 1 : 0)
            )
        }
        if Self._layoutCache.count >= Self.layoutCacheLimit {
            Self._layoutCache.removeAll()
        }
        Self._layoutCache[key] = (items, lines, paragraphPrefixCounts)
        return (items, lines, paragraphPrefixCounts)
    }

    /// Where word `wordIndex` sits in this layout, also when its line is
    /// culled and so reports no position. Uses the keyed cache, so it never
    /// reads the lines of another view.
    func midY(ofWordAt wordIndex: Int) -> CGFloat? {
        let (_, lines, paragraphPrefixCounts) = cachedLayout()
        return Self.layoutMidY(
            ofWordAt: wordIndex,
            lines: lines,
            paragraphPrefixCounts: paragraphPrefixCounts,
            rowHeight: Self.rowHeight(for: font),
            lineSpacing: lineSpacing,
            paragraphSpacing: paragraphDividerExtraSpacing
        )
    }

    /// The layout midY of every word, by word index. Each word gets the midY
    /// of the first word on its line, as the rendered positions do.
    func wordMidYs() -> [CGFloat] {
        let (_, lines, paragraphPrefixCounts) = cachedLayout()
        let rowHeight = Self.rowHeight(for: font)
        // One pass over the lines. Word Tracking calls this for each word
        // and each look-around step, so it must not scan the lines again
        // for each line, as layoutMidY does.
        return Self.perWordMidYs(lines: lines.indices.map { index in
            (lines[index].count, lines[index].isEmpty ? nil : Self.lineMidY(
                index,
                paragraphPrefixCounts: paragraphPrefixCounts,
                rowHeight: rowHeight,
                lineSpacing: lineSpacing,
                paragraphSpacing: paragraphDividerExtraSpacing
            ))
        })
    }

    /// One midY for each word: each line gives its midY to each of its words.
    /// A line with no midY adds nothing.
    static func perWordMidYs(lines: [(wordCount: Int, midY: CGFloat?)]) -> [CGFloat] {
        var result: [CGFloat] = []
        for line in lines {
            guard let midY = line.midY else { continue }
            result.append(contentsOf: repeatElement(midY, count: line.wordCount))
        }
        return result
    }

    // Find the index of the next word to read (first non-fully-lit, non-annotation word)
    private func nextWordIndex(items: [WordItem]) -> Int {
        for item in items {
            if item.isAnnotation { continue }
            let charsIntoWord = highlightedCharCount - item.charOffset
            let litCount = max(0, min(item.word.count, charsIntoWord))
            let letterCount = max(1, item.word.filter { $0.isLetter || $0.isNumber }.count)
            if litCount < letterCount {
                return item.id
            }
        }
        return -1
    }

    private func isRightToLeft(items: [WordItem]) -> Bool {
        for item in items where !item.isAnnotation {
            switch textBaseDirection(in: item.word) {
            case .rightToLeft:
                return true
            case .leftToRight:
                return false
            case .natural:
                continue
            }
        }
        return false
    }

    var body: some View {
        let (items, lines, paragraphPrefixCounts) = cachedLayout()
        let nextIdx = nextWordIndex(items: items)
        let totalLines = lines.count
        let rtl = isRightToLeft(items: items)

        // Row height from the font metrics. Each row gets this height below,
        // so the culling math is exact.
        let rowHeight = Self.rowHeight(for: font)
        let lineH = rowHeight + lineSpacing
        let lineTop: (Int) -> CGFloat = { lineIndex in
            CGFloat(lineIndex) * lineH
                + CGFloat(paragraphPrefixCounts[lineIndex]) * paragraphDividerExtraSpacing
        }
        let lineRowHeight: (Int) -> CGFloat = { lineIndex in
            let beginsParagraph = paragraphPrefixCounts[lineIndex + 1]
                > paragraphPrefixCounts[lineIndex]
            return rowHeight + (beginsParagraph ? paragraphDividerExtraSpacing : 0)
        }
        let totalContentHeight = max(0, lineTop(totalLines) - lineSpacing)

        // Determine visible range of lines
        let canCull = viewportHeight > 0 && totalLines > 0
        let buffer = wordFlowCullingBuffer
        let startLine: Int = {
            guard canCull else { return 0 }
            let visibleMinY = -scrollOffset - buffer
            var candidate = max(0, min(totalLines, Int(floor(max(0, visibleMinY) / lineH))))
            while candidate > 0, lineTop(candidate) > visibleMinY {
                candidate -= 1
            }
            while candidate < totalLines,
                  lineTop(candidate) + lineRowHeight(candidate) < visibleMinY {
                candidate += 1
            }
            return candidate
        }()
        let endLine: Int = {
            guard canCull else { return totalLines }
            let visibleMaxY = viewportHeight - scrollOffset + buffer
            var candidate = max(startLine, min(totalLines, Int(ceil(max(0, visibleMaxY) / lineH))))
            while candidate > startLine, lineTop(candidate) > visibleMaxY {
                candidate -= 1
            }
            while candidate < totalLines, lineTop(candidate) < visibleMaxY {
                candidate += 1
            }
            return max(startLine, candidate)
        }()

        // For RTL scripts (Arabic, Hebrew, Persian, Urdu), flip the layout direction
        // so words within each line flow right-to-left instead of left-to-right.
        VStack(alignment: rtl ? .trailing : .leading, spacing: lineSpacing) {
            if startLine > 0 {
                Color.clear.frame(
                    height: max(0, lineTop(startLine) - lineSpacing)
                )
            }

            ForEach(startLine..<endLine, id: \.self) { lineIdx in
                let beginsParagraph = paragraphPrefixCounts[lineIdx + 1]
                    > paragraphPrefixCounts[lineIdx]
                HStack(spacing: 0) {
                    ForEach(lines[lineIdx], id: \.id) { item in
                        wordView(for: item, isNextWord: item.id == nextIdx)
                            .id(item.id)
                    }
                }
                // SwiftUI's own text height can be 1 pt more or less than
                // rowHeight, and that error adds up over the lines.
                .frame(height: rowHeight)
                .frame(maxWidth: .infinity, alignment: rtl ? .trailing : .leading)
                .padding(.top, beginsParagraph ? paragraphDividerExtraSpacing : 0)
                .overlay(alignment: .top) {
                    if beginsParagraph {
                        HStack(spacing: paragraphDividerDotSpacing) {
                            ForEach(0..<3, id: \.self) { _ in
                                Circle()
                                    .fill(Color.white.opacity(paragraphDividerDotOpacity))
                                    .frame(
                                        width: paragraphDividerDotSize,
                                        height: paragraphDividerDotSize
                                    )
                            }
                        }
                            .offset(
                                y: (
                                    paragraphDividerExtraSpacing
                                        - lineSpacing
                                        - paragraphDividerDotSize
                                ) * 0.5
                            )
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
            }

            if endLine < totalLines {
                Color.clear.frame(
                    height: max(0, totalContentHeight - lineTop(endLine))
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: rtl ? .trailing : .leading)
        .coordinateSpace(name: "flowLayout")
    }

    private func wordView(for item: WordItem, isNextWord: Bool) -> some View {
        let wordLen = item.word.count
        let charsIntoWord = highlightedCharCount - item.charOffset
        let litCount = max(0, min(wordLen, charsIntoWord))
        let letterCount = max(1, item.word.filter { $0.isLetter || $0.isNumber }.count)
        let isFullyLit = litCount >= letterCount
        let isCurrentWord = isNextWord || (charsIntoWord >= 0 && !isFullyLit)

        // When highlighting is off (classic/silence-paused), use uniform color
        if !highlightWords {
            let uniformColor: Color = item.isAnnotation
                ? cueColor.opacity(cueUnreadOpacity)
                : highlightColor

            return Text(item.word + " ")
                .font(item.isAnnotation ? Font(font).italic() : Font(font))
                .foregroundStyle(uniformColor)
                .background(
                    GeometryReader { wordGeo in
                        Color.clear.preference(
                            key: WordYPreferenceKey.self,
                            value: [item.id: wordGeo.frame(in: .named("flowLayout")).midY]
                        )
                    }
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    onWordTap?(item.charOffset)
                }
        }

        // Annotations: italic, dimmed with cue color
        if item.isAnnotation {
            let annotationColor: Color = isFullyLit
                ? cueColor.opacity(cueReadOpacity)
                : cueColor.opacity(cueUnreadOpacity)

            return Text(item.word + " ")
                .font(Font(font).italic())
                .foregroundStyle(annotationColor)
                .background(
                    GeometryReader { wordGeo in
                        Color.clear.preference(
                            key: WordYPreferenceKey.self,
                            value: [item.id: wordGeo.frame(in: .named("flowLayout")).midY]
                        )
                    }
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    onWordTap?(item.charOffset)
                }
        }

        // Dim color: highlight color variant for current word, full for unread
        let dimColor: Color = isCurrentWord
            ? highlightColor.opacity(0.6)
            : highlightColor

        // Base color for the whole word
        let wordColor: Color = isFullyLit ? highlightColor.opacity(0.3) : dimColor

        return Text(item.word + " ")
            .font(Font(font))
            .foregroundStyle(wordColor)
            .underline(isCurrentWord, color: wordColor)
            .background(
                GeometryReader { wordGeo in
                    Color.clear.preference(
                        key: WordYPreferenceKey.self,
                        value: [item.id: wordGeo.frame(in: .named("flowLayout")).midY]
                    )
                }
            )
            .contentShape(Rectangle())
            .onTapGesture {
                onWordTap?(item.charOffset)
            }
    }

    private func buildItems() -> [WordItem] {
        var items: [WordItem] = []
        var offset = 0
        let annotationFlags = SpeechTextAlignment.annotationFlags(for: words)
        for (i, word) in words.enumerated() {
            let isAnnotation = annotationFlags[i] || Self.isAnnotationWord(word)
            items.append(WordItem(id: i, word: word, charOffset: offset, isAnnotation: isAnnotation))
            offset += word.count + 1 // +1 for space
        }
        return items
    }

    static func isAnnotationWord(_ word: String) -> Bool {
        // Words inside square brackets like [smile]
        if word.hasPrefix("[") && word.hasSuffix("]") { return true }
        // Emoji-only words (no letters or numbers)
        let stripped = word.filter { $0.isLetter || $0.isNumber }
        if stripped.isEmpty { return true }
        return false
    }

    private func buildLines(items: [WordItem]) -> [[WordItem]] {
        var lines: [[WordItem]] = [[]]
        var currentLineWidth: CGFloat = 0
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: font]).width

        for item in items {
            if paragraphBreakBeforeWordIndices.contains(item.id),
               !lines[lines.count - 1].isEmpty {
                lines.append([])
                currentLineWidth = 0
            }
            let wordWidth = (item.word as NSString).size(withAttributes: [.font: font]).width + spaceWidth
            if currentLineWidth + wordWidth > containerWidth && !lines[lines.count - 1].isEmpty {
                lines.append([])
                currentLineWidth = 0
            }
            lines[lines.count - 1].append(item)
            currentLineWidth += wordWidth
        }
        return lines
    }
}

// MARK: - Elapsed Time

struct ElapsedTimeView: View {
    let fontSize: CGFloat

    @State private var startDate = Date()

    var body: some View {
        TimelineView(.periodic(from: startDate, by: 1)) { context in
            let elapsed = context.date.timeIntervalSince(startDate)
            let minutes = Int(elapsed) / 60
            let seconds = Int(elapsed) % 60
            Text(String(format: "%02d:%02d", minutes, seconds))
                .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
        }
    }
}

// MARK: - Audio Waveform + Progress

struct AudioWaveformProgressView: View {
    let levels: [CGFloat]
    let progress: Double // 0.0 to 1.0

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                let barProgress = Double(index) / Double(max(1, levels.count - 1))
                let isLit = barProgress <= progress

                RoundedRectangle(cornerRadius: 1.5)
                    .fill(isLit
                          ? Color.yellow.opacity(0.9)
                          : Color.white.opacity(0.15)
                    )
                    .frame(width: 3, height: max(3, level * 28))
                    .animation(.easeOut(duration: 0.08), value: level)
            }
        }
    }
}

// Keep the old one for backward compat
struct AudioWaveformView: View {
    let levels: [CGFloat]
    var color: Color = .white

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color.opacity(0.4 + Double(level) * 0.6))
                    .frame(width: 3, height: max(3, level * 28 + 3))
                    .animation(.easeOut(duration: 0.08), value: level)
            }
        }
    }
}

// MARK: - Scroll Wheel Handler

struct ScrollWheelView: NSViewRepresentable {
    var onScroll: (CGFloat) -> Void
    var onScrollEnd: (() -> Void)?

    init(onScroll: @escaping (CGFloat) -> Void, onScrollEnd: (() -> Void)? = nil) {
        self.onScroll = onScroll
        self.onScrollEnd = onScrollEnd
    }

    func makeNSView(context: Context) -> ScrollWheelNSView {
        let view = ScrollWheelNSView()
        view.onScroll = onScroll
        view.onScrollEnd = onScrollEnd
        return view
    }

    func updateNSView(_ nsView: ScrollWheelNSView, context: Context) {
        nsView.onScroll = onScroll
        nsView.onScrollEnd = onScrollEnd
    }
}

class ScrollWheelNSView: NSView {
    var onScroll: ((CGFloat) -> Void)?
    var onScrollEnd: (() -> Void)?
    private var scrollMonitor: Any?
    /// A mouse wheel sends no phases, so no end. This ends it 0.4 s after the
    /// last wheel event.
    private var wheelEndItem: DispatchWorkItem?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            cancelWheelEnd()
        }
        if window != nil && scrollMonitor == nil {
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window else { return event }
                // Only handle if event is in our window
                if event.window == window {
                    let delta = event.scrollingDeltaY
                    let scaled = event.hasPreciseScrollingDeltas ? delta : delta * 10
                    self.handleScroll(delta: scaled, phase: event.phase, momentumPhase: event.momentumPhase)
                }
                return event
            }
        }
    }

    /// One scroll event in this view's window.
    func handleScroll(delta: CGFloat, phase: NSEvent.Phase, momentumPhase: NSEvent.Phase) {
        cancelWheelEnd()
        onScroll?(delta)

        switch Self.scrollEndTiming(phase: phase, momentumPhase: momentumPhase) {
        case .now:
            onScrollEnd?()
        case .afterWheelPause:
            // Read onScrollEnd when the item runs: updateNSView may have
            // replaced it since.
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.wheelEndItem = nil
                self.onScrollEnd?()
            }
            wheelEndItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
        case .noEnd:
            break
        }
    }

    /// When a scroll event ends the scroll.
    enum ScrollEndTiming { case now, afterWheelPause, noEnd }

    /// A trackpad gesture ends at its .ended or .cancelled phase (a cancelled
    /// gesture sends no .ended). A mouse wheel sends no phases, so it ends
    /// 0.4 s after its last event. Other trackpad events do not end it.
    static func scrollEndTiming(phase: NSEvent.Phase, momentumPhase: NSEvent.Phase) -> ScrollEndTiming {
        if phase == .ended || phase == .cancelled
            || momentumPhase == .ended || momentumPhase == .cancelled {
            return .now
        }
        return phase.isEmpty && momentumPhase.isEmpty ? .afterWheelPause : .noEnd
    }

    private func cancelWheelEnd() {
        wheelEndItem?.cancel()
        wheelEndItem = nil
    }

    override func removeFromSuperview() {
        cancelWheelEnd()
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
        super.removeFromSuperview()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}
