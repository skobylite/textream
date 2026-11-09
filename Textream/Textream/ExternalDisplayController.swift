//
//  ExternalDisplayController.swift
//  Textream
//
//  Created by Fatih Kadir Akın on 8.02.2026.
//

import AppKit
import SwiftUI
import Combine

class ExternalDisplayController {
    private var panel: NSPanel?
    private var cancellables = Set<AnyCancellable>()
    let overlayContent = OverlayContent()

    /// Find the target external screen based on saved screen ID, or first non-main screen
    func targetScreen() -> NSScreen? {
        let settings = NotchSettings.shared
        let screens = NSScreen.screens.filter { $0 != NSScreen.main }
        guard !screens.isEmpty else { return nil }

        // Try to find saved screen
        if settings.externalScreenID != 0 {
            if let match = screens.first(where: { $0.displayID == settings.externalScreenID }) {
                return match
            }
        }
        return screens.first
    }

    func show(
        speechRecognizer: SpeechRecognizer,
        words: [String],
        totalCharCount: Int,
        paragraphBreakBeforeWordIndices: Set<Int> = [],
        hasNextPage: Bool = false,
        scrollProgress: SharedScrollProgress
    ) {
        let settings = NotchSettings.shared
        guard settings.externalDisplayMode != .off else { return }
        guard let screen = targetScreen() else { return }

        dismiss()

        overlayContent.words = words
        overlayContent.paragraphBreakBeforeWordIndices = paragraphBreakBeforeWordIndices
        overlayContent.totalCharCount = totalCharCount
        overlayContent.hasNextPage = hasNextPage

        let mirrorAxis = settings.externalDisplayMode == .mirror ? settings.mirrorAxis : nil
        let screenFrame = screen.frame

        let content = ExternalDisplayView(
            content: overlayContent,
            speechRecognizer: speechRecognizer,
            mirrorAxis: mirrorAxis,
            handlesAutoNextPage: false,
            usesExternalSizing: true,
            scrollProgress: scrollProgress
        )

        let hostingView = NSHostingView(rootView: content)

        let panel = PrompterPanel(
            contentRect: screenFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = true
        panel.backgroundColor = .black
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hostingView
        panel.setFrame(screenFrame, display: true)
        panel.orderFront(nil)
        self.panel = panel

        // Poll for dismiss signal
        Timer.publish(every: 0.1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, speechRecognizer.shouldDismiss else { return }
                self.cancellables.removeAll()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.dismiss()
                }
            }
            .store(in: &cancellables)
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
        cancellables.removeAll()
    }
}

// MARK: - NSScreen extension to get display ID

extension NSScreen {
    var displayID: UInt32 {
        guard let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return 0
        }
        return screenNumber.uint32Value
    }

    var displayName: String {
        return localizedName
    }
}

// MARK: - External Display SwiftUI View

struct ExternalDisplayView: View {
    @Bindable var content: OverlayContent
    @Bindable var speechRecognizer: SpeechRecognizer
    let mirrorAxis: MirrorAxis?
    let handlesAutoNextPage: Bool
    /// The External tab's text size and column width. Fullscreen on the Mac's
    /// own screen shares this view but keeps the automatic layout.
    var usesExternalSizing: Bool = false
    /// The session's reading position, shared with the overlay.
    let scrollProgress: SharedScrollProgress
    /// True only when this view is the session overlay (Fullscreen). Only one
    /// screen may run the clock: a second one that ticks doubles the speed.
    var drivesProgress = false

    private var words: [String] { content.words }
    private var totalCharCount: Int { content.totalCharCount }
    private var hasNextPage: Bool { content.hasNextPage }

    // Timer-based scroll for classic & silence-paused modes. The position
    // itself is scrollProgress, shared with the overlay.
    @State private var scrollHoldID = UUID()
    @State private var countdownRemaining: Int = 0
    @State private var countdownTimer: Timer? = nil
    private let scrollTimer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    private var listeningMode: ListeningMode {
        NotchSettings.shared.listeningMode
    }

    private var effectiveCharCount: Int {
        switch listeningMode {
        case .wordTracking:
            return speechRecognizer.recognizedCharCount
        case .classic, .silencePaused:
            return ScrollProgressMath.charOffset(
                forWordProgress: scrollProgress.wordProgress,
                words: words,
                totalCharCount: totalCharCount
            )
        }
    }

    var isDone: Bool {
        totalCharCount > 0 && effectiveCharCount >= totalCharCount
    }

    private var isEffectivelyListening: Bool {
        switch listeningMode {
        case .wordTracking, .silencePaused:
            return speechRecognizer.isListening
        case .classic:
            // The Pause button on the Mac window also stops this screen.
            return !scrollProgress.isPaused
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isDone && (listeningMode == .wordTracking || hasNextPage) {
                doneView
            } else {
                prompterView
            }
        }
        .overlay(alignment: .topTrailing) {
            if NotchSettings.shared.showElapsedTime {
                ElapsedTimeView(fontSize: 24)
                    .padding(.top, 20)
                    .padding(.trailing, 40)
            }
        }
        .scaleEffect(x: mirrorAxis?.scaleX ?? 1, y: mirrorAxis?.scaleY ?? 1)
        .animation(.easeInOut(duration: 0.5), value: isDone)
        .onChange(of: isDone) { _, done in
            if done {
                if listeningMode == .wordTracking {
                    speechRecognizer.stop()
                }
                if handlesAutoNextPage && hasNextPage && NotchSettings.shared.autoNextPage {
                    startCountdown()
                }
            } else {
                cancelCountdown()
            }
        }
        .onDisappear { cancelCountdown() }
        .onReceive(scrollTimer) { _ in
            // Only the session overlay advances the shared clock. The
            // External display only reads it (drivesProgress is false).
            let step = ScrollProgressMath.tickStep(
                drivesProgress: drivesProgress,
                isWordTracking: listeningMode == .wordTracking,
                isClassic: listeningMode == .classic,
                isPaused: scrollProgress.isPaused,
                isHeld: scrollProgress.isUserScrolling,
                isDone: isDone,
                isListening: speechRecognizer.isListening,
                isSpeaking: speechRecognizer.isSpeaking,
                scrollSpeed: NotchSettings.shared.scrollSpeed
            )
            if step > 0 { scrollProgress.wordProgress += step }
        }
        .onChange(of: content.currentPageIndex) { _, _ in
            // NotchOverlayController.updateContent resets the shared position.
            cancelCountdown()
        }
    }

    private var prompterView: some View {
        GeometryReader { geo in
            let settings = NotchSettings.shared
            let textScale = usesExternalSizing ? settings.externalTextScale : 1
            let column = usesExternalSizing ? settings.externalColumnWidth : 1
            let fontSize = max(48, min(96, geo.size.width / 14)) * textScale
            let hPad = Self.sidePadding(screenWidth: geo.size.width, column: column)

            VStack(spacing: 0) {
                Spacer().frame(height: 20)

                SpeechScrollView(
                    words: words,
                    highlightedCharCount: effectiveCharCount,
                    font: .systemFont(ofSize: fontSize, weight: .semibold),
                    highlightColor: NotchSettings.shared.fontColorPreset.color,
                    cueColor: NotchSettings.shared.cueColorPreset.color,
                    cueUnreadOpacity: NotchSettings.shared.cueBrightness.unreadOpacity,
                    cueReadOpacity: NotchSettings.shared.cueBrightness.readOpacity,
                    onWordTap: { charOffset in
                        if listeningMode == .wordTracking {
                            speechRecognizer.jumpTo(charOffset: charOffset)
                        } else {
                            scrollProgress.jump(to: ScrollProgressMath.wordProgress(forCharOffset: charOffset, words: words))
                        }
                    },
                    onManualScroll: { scrolling, newProgress in
                        if scrolling {
                            scrollProgress.beginHold(by: scrollHoldID)
                        } else {
                            scrollProgress.endHold(by: scrollHoldID, at: newProgress, wordCount: words.count)
                        }
                    },
                    smoothScroll: listeningMode != .wordTracking,
                    smoothWordProgress: scrollProgress.wordProgress,
                    isListening: isEffectivelyListening,
                    readingPosition: NotchSettings.shared.readingPosition,
                paragraphBreakBeforeWordIndices: NotchSettings.shared.showParagraphDividers
                    ? content.paragraphBreakBeforeWordIndices
                    : []
            )
            .id(content.currentPageIndex)
            .padding(.horizontal, hPad)

                Spacer().frame(height: 20)

                HStack(alignment: .center, spacing: 16) {
                    AudioWaveformProgressView(
                        levels: speechRecognizer.audioLevels,
                        progress: totalCharCount > 0
                            ? Double(effectiveCharCount) / Double(totalCharCount)
                            : 0
                    )
                    .frame(width: 240, height: 32)

                    if listeningMode == .wordTracking,
                       NotchSettings.shared.showLastSpokenWords {
                        Text(speechRecognizer.lastSpokenText.split(separator: " ").suffix(5).joined(separator: " "))
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                            .truncationMode(.head)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Spacer()
                    }

                    if listeningMode != .classic {
                        Button {
                            if speechRecognizer.isListening {
                                speechRecognizer.stop()
                            } else {
                                speechRecognizer.resume()
                            }
                        } label: {
                            Image(systemName: speechRecognizer.isListening ? "mic.fill" : "mic.slash.fill")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(speechRecognizer.isListening ? .yellow.opacity(0.8) : .white.opacity(0.4))
                                .frame(width: 40, height: 40)
                                .background(.white.opacity(0.15))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, hPad)
                .padding(.bottom, 40)
            }
        }
    }

    /// Side margin that makes the text column `column` times the automatic
    /// width (the screen less a margin of max(40, 8%) on each side). At 1 it
    /// is that automatic margin.
    static func sidePadding(screenWidth: CGFloat, column: Double) -> CGFloat {
        let base = max(40, screenWidth * 0.08)
        return base + (screenWidth - 2 * base) * (1 - column) / 2
    }

    private var doneView: some View {
        VStack(spacing: 12) {
            if hasNextPage {
                if countdownRemaining > 0 {
                    Text("\(countdownRemaining)")
                        .font(.system(size: 40, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                        .animation(.easeInOut(duration: 0.3), value: countdownRemaining)
                }
                Button {
                    cancelCountdown()
                    speechRecognizer.shouldAdvancePage = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 28, weight: .bold))
                        Text("Next Page")
                            .font(.system(size: 28, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 16)
                    .background(Color.accentColor)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.green)
                Text("Done!")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .transition(.scale.combined(with: .opacity))
    }

    private func startCountdown() {
        countdownTimer?.invalidate()
        countdownRemaining = NotchSettings.shared.autoNextPageDelay
        guard countdownRemaining > 0 else {
            countdownTimer = nil
            DispatchQueue.main.async {
                speechRecognizer.shouldAdvancePage = true
            }
            return
        }
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            DispatchQueue.main.async {
                countdownRemaining -= 1
                if countdownRemaining <= 0 {
                    timer.invalidate()
                    countdownTimer = nil
                    speechRecognizer.shouldAdvancePage = true
                }
            }
        }
    }

    private func cancelCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownRemaining = 0
    }
}
