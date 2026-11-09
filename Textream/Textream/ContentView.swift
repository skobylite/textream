//
//  ContentView.swift
//  Textream
//
//  Created by Fatih Kadir Akın on 8.02.2026.
//

import SwiftUI
import UniformTypeIdentifiers
import CoreImage.CIFilterBuiltins

struct ContentView: View {
    @ObservedObject private var service = TextreamService.shared
    @State private var isRunning = false
    @State private var dictation = DictationManager()
    @State private var dictationHighlightRange: NSRange? = nil
    @State private var dictationCaretPosition: Int? = nil
    @State private var editorCaretPosition: Int = 0
    @State private var isDroppingPresentation = false
    @State private var dropError: String?
    @State private var dropAlertTitle: String = "Import Error"
    @State private var markDoneError: String?
    @State private var showSettings = false
    @State private var showAbout = false
    @State private var languageSuggestion: SpeechLanguageSuggestion?
    @State private var ignoredLanguageIdentifier: String?
    @State private var languageDetectionTask: Task<Void, Never>?
    @FocusState private var isTextFocused: Bool
    /// Sidebar search for the Scripts list. Not saved.
    @State private var scriptQuery = ""
    @FocusState private var isScriptSearchFocused: Bool
    /// Bound so that ⌘F can show a hidden sidebar.
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    private let defaultText = """
Welcome to Textream! This is your personal teleprompter that sits right below your MacBook's notch. [smile]

As you read aloud, the text will highlight in real-time, following your voice. The speech recognition matches your words and keeps track of your progress. [pause]

You can pause at any time, go back and re-read sections, and the highlighting will follow along. When you finish reading all the text, the overlay will automatically close with a smooth animation. [nod]

Try reading this passage out loud to see how the highlighting works. The waveform at the bottom shows your voice activity, and you'll see the last few words you spoke displayed next to it.

Happy presenting! [wave]
"""

    private var languageLabel: String {
        let locale = NotchSettings.shared.speechLocale
        return Locale.current.localizedString(forIdentifier: locale)
            ?? locale
    }

    private var currentText: Binding<String> {
        Binding(
            get: {
                guard service.currentPageIndex < service.pages.count else { return "" }
                return service.pages[service.currentPageIndex]
            },
            set: { newValue in
                guard service.currentPageIndex < service.pages.count else { return }
                service.pages[service.currentPageIndex] = newValue
            }
        )
    }

    private var hasAnyContent: Bool {
        service.pages.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private var isRecording: Bool {
        dictation.isRecording || dictation.isStarting
    }

    private func scheduleLanguageDetection(for text: String) {
        languageDetectionTask?.cancel()
        languageSuggestion = nil
        let pageIndex = service.currentPageIndex
        let localeIdentifier = NotchSettings.shared.speechLocale

        languageDetectionTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 2_500_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  service.currentPageIndex == pageIndex,
                  service.currentPageText == text,
                  NotchSettings.shared.speechLocale == localeIdentifier else { return }

            let suggestion = SpeechLanguageDetector.suggestion(
                for: text,
                currentLocaleIdentifier: localeIdentifier
            )
            guard !Task.isCancelled,
                  suggestion?.detectedLanguageIdentifier != ignoredLanguageIdentifier else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                languageSuggestion = suggestion
            }
        }
    }

    private func languageSuggestionBanner(_ suggestion: SpeechLanguageSuggestion) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "character.bubble.fill")
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("This text looks like \(suggestion.languageName).")
                    .font(.system(size: 12, weight: .semibold))
                Text("Speech is currently set to \(languageLabel).")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button("Use \(suggestion.languageName)") {
                if isRecording {
                    stopRecording()
                }
                ignoredLanguageIdentifier = nil
                languageSuggestion = nil
                NotchSettings.shared.speechLocale = suggestion.localeIdentifier
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help("Switch speech recognition to \(suggestion.localeName)")

            Button {
                ignoredLanguageIdentifier = suggestion.detectedLanguageIdentifier
                withAnimation(.easeInOut(duration: 0.2)) {
                    languageSuggestion = nil
                }
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Dismiss language suggestion")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.accentColor.opacity(0.2))
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var waveformPill: some View {
        let pill = AudioWaveformView(levels: dictation.audioLevels, color: .red)
            .frame(height: 34)
            .frame(maxWidth: 240)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            pill
                .glassEffect(in: .capsule)
        } else {
            pill
                .background(.ultraThinMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        }
        #else
        pill
            .background(.ultraThinMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        #endif
    }

    @State private var highlightClearTimer: Timer?

    // Segment tracking: each recognition session is a "segment"
    @State private var segmentStart: Int = 0
    @State private var segmentLength: Int = 0
    @State private var segmentNeedsSeparator: Bool = false
    // How many chars of the raw recognition result to skip (already committed before cursor move)
    @State private var spokenSkipOffset: Int = 0
    @State private var lastRawSpokenLength: Int = 0

    private func beginNewSegment() {
        let pageIndex = service.currentPageIndex
        guard pageIndex < service.pages.count else { return }
        let text = service.pages[pageIndex]
        let caret = min(editorCaretPosition, text.count)

        // Skip everything already recognized up to this point
        spokenSkipOffset = lastRawSpokenLength

        // Check if we need a space before the new segment
        let charBefore = caret > 0 ? text[text.index(text.startIndex, offsetBy: caret - 1)] : "\n"
        segmentNeedsSeparator = !(charBefore == " " || charBefore == "\n" || caret == 0)
        segmentStart = caret
        segmentLength = 0
    }

    private func startRecording() {
        lastRawSpokenLength = 0
        spokenSkipOffset = 0
        beginNewSegment()

        dictation.onNewSegment = { [self] in
            // Recognition restarted — raw counter resets to 0
            lastRawSpokenLength = 0
            spokenSkipOffset = 0
            beginNewSegment()
        }

        dictation.onTextUpdate = { [self] spokenText in
            lastRawSpokenLength = spokenText.count

            // Only use the portion after the skip offset
            let effectiveText: String
            if spokenSkipOffset < spokenText.count {
                effectiveText = String(spokenText.suffix(spokenText.count - spokenSkipOffset))
            } else {
                effectiveText = ""
            }
            guard !effectiveText.isEmpty else { return }

            let pageIndex = service.currentPageIndex
            guard pageIndex < service.pages.count else { return }
            var text = service.pages[pageIndex]

            // Remove the old segment text
            let safeStart = min(segmentStart, text.count)
            let removeStart = text.index(text.startIndex, offsetBy: safeStart)
            let safeLen = min(segmentLength, text.count - safeStart)
            let removeEnd = text.index(removeStart, offsetBy: safeLen)
            text.removeSubrange(removeStart..<removeEnd)

            // Build the new segment content
            let sep = segmentNeedsSeparator ? " " : ""
            let newSegment = sep + effectiveText
            text.insert(contentsOf: newSegment, at: text.index(text.startIndex, offsetBy: min(segmentStart, text.count)))

            let prevLen = segmentLength
            segmentLength = newSegment.count
            service.pages[pageIndex] = text

            // Highlight only the newly added characters
            let newChars = segmentLength - prevLen
            if newChars > 0 {
                let highlightStart = segmentStart + prevLen
                dictationHighlightRange = NSRange(location: highlightStart, length: newChars)
            }

            // Move caret to end of segment
            dictationCaretPosition = segmentStart + segmentLength

            // Clear highlight after 1s of silence
            highlightClearTimer?.invalidate()
            highlightClearTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { _ in
                DispatchQueue.main.async {
                    dictationHighlightRange = nil
                }
            }
        }
        dictation.start()
    }

    private func stopRecording() {
        highlightClearTimer?.invalidate()
        highlightClearTimer = nil
        dictationHighlightRange = nil
        dictation.stop()
        dictation.onTextUpdate = nil
        dictation.onNewSegment = nil
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            if let languageSuggestion {
                languageSuggestionBanner(languageSuggestion)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            ZStack {
                HighlightingTextEditor(
                    text: currentText,
                    font: .systemFont(ofSize: 16, weight: .regular).rounded,
                    highlightRange: dictationHighlightRange,
                    caretPosition: $dictationCaretPosition,
                    editorCaretPosition: $editorCaretPosition
                )
                .onChange(of: editorCaretPosition) { _, newPos in
                    guard isRecording else { return }
                    // If caret moved away from end of current segment, user clicked elsewhere
                    let segmentEnd = segmentStart + segmentLength
                    if newPos != segmentEnd {
                        beginNewSegment()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 8)
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .white, location: 0.03),
                            .init(color: .white, location: 0.93),
                            .init(color: .clear, location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                // Bottom bar
                VStack {
                    Spacer()
                    ZStack {
                        // Waveform pill centered to full width
                        if dictation.isRecording {
                            waveformPill
                                .transition(.scale(scale: 0.8).combined(with: .opacity))
                        }

                        // Buttons pinned right
                        HStack(spacing: 10) {
                            Spacer()

                            Button {
                                if isRecording {
                                    stopRecording()
                                } else {
                                    startRecording()
                                }
                            } label: {
                                Group {
                                    if dictation.isStarting {
                                        ProgressView()
                                            .controlSize(.small)
                                            .tint(.white)
                                    } else {
                                        Image(systemName: isRecording ? "pause.fill" : "mic.fill")
                                            .font(.system(size: 16, weight: .semibold))
                                    }
                                }
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(isRecording ? Color.orange : Color.red)
                                .clipShape(Circle())
                                .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                            }
                            .buttonStyle(.plain)
                            .disabled(isRunning)
                            .opacity(isRunning ? 0.4 : 1)

                            Button {
                                if isRunning {
                                    stop()
                                } else {
                                    run()
                                }
                            } label: {
                                Image(systemName: isRunning ? "stop.fill" : "play.fill")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 44, height: 44)
                                    .background(isRunning ? Color.red : Color.accentColor)
                                    .clipShape(Circle())
                                    .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                            }
                            .buttonStyle(.plain)
                            .disabled((!isRunning && !hasAnyContent) || isRecording)
                            .opacity((!hasAnyContent && !isRunning) || isRecording ? 0.4 : 1)
                        }
                    }
                    .padding(20)
                }
                .animation(.easeInOut(duration: 0.25), value: isRecording)

                // Drop zone overlay — sits on top so TextEditor doesn't steal the drop
                if isDroppingPresentation {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(Color.accentColor)
                    Text("Drop PowerPoint (.pptx) file")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                    Text("For Keynote or Google Slides,\nexport as PPTX first.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8]))
                        .background(Color.accentColor.opacity(0.08).clipShape(RoundedRectangle(cornerRadius: 12)))
                )
                .padding(8)
            }

            // Invisible drop target covering entire window
            Color.clear
                .contentShape(Rectangle())
                .onDrop(of: [.fileURL], isTargeted: $isDroppingPresentation) { providers in
                    guard let provider = providers.first else { return false }
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        let ext = url.pathExtension.lowercased()
                        if ext == "key" {
                            DispatchQueue.main.async {
                                dropAlertTitle = "Conversion Required"
                                dropError = "Keynote files can't be imported directly. Please export your Keynote presentation as PowerPoint (.pptx) first, then drop the exported file here."
                            }
                            return
                        }
                        guard ext == "pptx" else {
                            DispatchQueue.main.async {
                                dropAlertTitle = "Import Error"
                                dropError = "Unsupported file. Drop a PowerPoint (.pptx) file."
                            }
                            return
                        }
                        DispatchQueue.main.async {
                            handlePresentationDrop(url: url)
                        }
                    }
                    return true
                }
                .allowsHitTesting(isDroppingPresentation)
            }
        }
    }

    private var directorOverlay: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "megaphone.fill")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)

            Text("Director Mode")
                .font(.system(size: 22, weight: .bold))

            Text(service.directorIsReading ? "Reading from director…" : "Waiting for director to send script…")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            if let ip = BrowserServer.localIPAddress() {
                let url = "http://\(ip):\(NotchSettings.shared.directorServerPort)"

                if let qrImage = generateDirectorQRCode(from: url) {
                    Image(nsImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 140, height: 140)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                HStack(spacing: 8) {
                    Text(url)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.accentColor)
                        .textSelection(.enabled)

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                showSettings = true
            } label: {
                Text("Open Settings")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func generateDirectorQRCode(from string: String) -> NSImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let ciImage = filter.outputImage else { return nil }
        let scale = 10.0
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }

    var body: some View {
        Group {
            if NotchSettings.shared.directorModeEnabled {
                directorOverlay
            } else {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    pageSidebar
                } detail: {
                    mainContent
                }
                .navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 260)
            }
        }
        .alert(dropAlertTitle, isPresented: Binding(get: { dropError != nil }, set: { if !$0 { dropError = nil } })) {
            Button("OK") { dropError = nil }
        } message: {
            Text(dropError ?? "")
        }
        .alert("Microphone Unavailable", isPresented: Binding(
            get: { dictation.error != nil },
            set: { if !$0 { dictation.error = nil } }
        )) {
            Button("OK") { dictation.error = nil }
        } message: {
            Text(dictation.error ?? "")
        }
        .alert("Script Not Marked Done", isPresented: Binding(
            get: { markDoneError != nil },
            set: { if !$0 { markDoneError = nil } }
        )) {
            Button("OK") { markDoneError = nil }
        } message: {
            Text(markDoneError ?? "")
        }
        .frame(minWidth: 360, minHeight: 240)
        .background(.ultraThinMaterial)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 8) {
                    Button {
                        if isRecording {
                            stopRecording()
                        }
                        service.openFile()
                    } label: {
                        HStack(spacing: 4) {
                            if service.currentFileURL != nil && service.hasUnsavedChanges {
                                Circle()
                                    .fill(.orange)
                                    .frame(width: 6, height: 6)
                            }
                            Text(service.currentFileURL?.deletingPathExtension().lastPathComponent ?? "Untitled")
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                        }
                        .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)

                    // Add page button in toolbar
                    Button {
                        if isRecording {
                            stopRecording()
                        }
                        withAnimation(.easeInOut(duration: 0.2)) {
                            service.pages.append("")
                            moveToPage(service.pages.count - 1)
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Page")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)

                    if ScriptQueue.shared.pageOrigins[service.currentPageIndex] != nil {
                        Button {
                            markPageDone(at: service.currentPageIndex)
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "checkmark.circle")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("Mark Script Done")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.green.opacity(0.12))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Adds the 'done' tag to this note in your vault and removes it here")
                    }

                    Button {
                        showSettings = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: NotchSettings.shared.listeningMode.icon)
                                .font(.system(size: 10))
                            Text(NotchSettings.shared.listeningMode == .wordTracking
                                 ? languageLabel
                                 : NotchSettings.shared.listeningMode.label)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(settings: NotchSettings.shared)
        }
        .sheet(isPresented: $showAbout) {
            AboutView()
        }
        .onReceive(NotificationCenter.default.publisher(for: .newPage)) { _ in
            guard !isRunning else { return }
            if isRecording {
                stopRecording()
            }
            withAnimation(.easeInOut(duration: 0.2)) {
                service.pages.append("")
                moveToPage(service.pages.count - 1)
            }
            // The cursor goes to the new page, also from the search field.
            NotificationCenter.default.post(name: .focusEditor, object: nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: .searchScripts)) { _ in
            // ⌘F. The field shows only once a script vault is chosen.
            // Director mode has no sidebar.
            guard !isRunning, !NotchSettings.shared.directorModeEnabled,
                  ScriptQueue.shared.vaultURL != nil else { return }
            // A hidden sidebar is shown first. Otherwise the cursor stays
            // in the editor, and the search words go into the script. Until
            // the field can take the cursor, keys only beep.
            if columnVisibility != .all {
                NSApp.keyWindow?.makeFirstResponder(nil)
                columnVisibility = .all
            }
            focusScriptSearch()
        }
        .onReceive(NotificationCenter.default.publisher(for: .startPrompter)) { _ in
            // ⌘↩ from the editor. The main window hides while the prompter runs,
            // so this only ever starts; Esc stops from the overlay.
            guard !isRunning, !isRecording, hasAnyContent else { return }
            isTextFocused = false
            run()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
            showSettings = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .openAbout)) { _ in
            showAbout = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Sync button state when app is re-activated (e.g. dock click)
            isRunning = service.overlayController.isShowing
            // Scripts can change in Obsidian while Textream is in the background.
            ScriptQueue.shared.rescan()
        }
        .onChange(of: service.currentPageText, initial: true) { _, text in
            scheduleLanguageDetection(for: text)
        }
        .onChange(of: service.currentPageIndex) { _, _ in
            if isRecording {
                stopRecording()
            }
            ignoredLanguageIdentifier = nil
            scheduleLanguageDetection(for: service.currentPageText)
        }
        .onChange(of: NotchSettings.shared.speechLocale) { _, _ in
            if isRecording {
                stopRecording()
            }
            ignoredLanguageIdentifier = nil
            scheduleLanguageDetection(for: service.currentPageText)
        }
        .onDisappear {
            languageDetectionTask?.cancel()
            if isRecording {
                stopRecording()
            }
        }
        .onAppear {
            // Restore the previous session before seeding the sample script,
            // so a returning draft is not overwritten.
            let restored = service.restoreDraft()
            if !restored, service.pages.count == 1, service.pages[0].isEmpty {
                service.pages[0] = defaultText
            }
            // Sync button state with overlay
            if service.overlayController.isShowing {
                isRunning = true
            }
            if TextreamService.shared.launchedExternally {
                DispatchQueue.main.async {
                    for window in NSApp.windows where !(window is NSPanel) {
                        window.orderOut(nil)
                    }
                }
            } else {
                isTextFocused = true
            }
        }
    }

    // MARK: - Page Sidebar

    private func pagePreview(_ page: String) -> String {
        let trimmed = page.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Empty" }
        let words = trimmed.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        let preview = words.prefix(5).joined(separator: " ")
        return preview.count > 30 ? String(preview.prefix(30)) + "…" : preview
    }

    private var sidebarSelection: Binding<Int?> {
        Binding<Int?>(
            get: { service.currentPageIndex },
            set: { newValue in
                if let index = newValue {
                    if isRecording {
                        stopRecording()
                    }
                    withAnimation(.easeInOut(duration: 0.15)) {
                        moveToPage(index)
                    }
                }
            }
        )
    }

    /// Selects another page. A blank page that is left is removed (never the
    /// only page). Only the user's own page moves do this (and loadScript): a
    /// replaced page list (file open, import, Director) or a page change made
    /// by the prompter must never lose a page.
    private func moveToPage(_ index: Int) {
        let move = Self.leavingBlankPage(service.pages, from: service.currentPageIndex, to: index)
        if let blank = move.remove {
            service.pages.remove(at: blank)
        }
        service.currentPageIndex = move.target
    }

    /// Moving from page `old` to page `target`: the blank page that is left
    /// is removed, unless it is the only page. Returns the page to remove
    /// and the index of `target` after that.
    private static func leavingBlankPage(_ pages: [String], from old: Int, to target: Int) -> (remove: Int?, target: Int) {
        guard old != target, old < pages.count, pages.count > 1,
              pages[old].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return (nil, target) }
        return (old, target > old ? target - 1 : target)
    }

    /// Puts the cursor in the search field. While a hidden sidebar opens,
    /// the field cannot take focus yet, so this tries again for up to 0.5 s.
    private func focusScriptSearch(triesLeft: Int = 10) {
        isScriptSearchFocused = true
        guard triesLeft > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if !isScriptSearchFocused { focusScriptSearch(triesLeft: triesLeft - 1) }
        }
    }

    /// Search for the Scripts list, pinned at the top of the sidebar. ⌘F
    /// focuses it. Esc clears it, and a second Esc puts the cursor back in
    /// the editor. Local-only.
    private var scriptSearchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .onTapGesture { isScriptSearchFocused = true }
                .accessibilityHidden(true)
            TextField("Search scripts", text: $scriptQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .focused($isScriptSearchFocused)
                .onExitCommand {
                    if scriptQuery.isEmpty {
                        NotificationCenter.default.post(name: .focusEditor, object: nil)
                    } else {
                        scriptQuery = ""
                    }
                }
            if !scriptQuery.isEmpty {
                Button {
                    scriptQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.06))
                .onTapGesture { isScriptSearchFocused = true }
        )
        .help("Search scripts (⌘F)")
        .padding(.horizontal, 10)
        .padding(.top, 2)
        .padding(.bottom, 4)
    }

    private var pageSidebar: some View {
        List(selection: sidebarSelection) {
            ForEach(Array(service.pages.enumerated()), id: \.offset) { index, page in
                Label {
                    Text(pagePreview(page))
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.tail)
                } icon: {
                    Text("\(index + 1)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary)
                        .frame(width: 20, height: 20)
                        .background(service.readPages.contains(index) ? Color.green.opacity(0.3) : Color.primary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .tag(index)
                .contextMenu {
                    // Only the vault page has a note to mark done. Other
                    // pages use Delete Page.
                    if ScriptQueue.shared.pageOrigins[index] != nil {
                        Button {
                            markPageDone(at: index)
                        } label: {
                            Label("Mark Done", systemImage: "checkmark.circle")
                        }
                    }
                    if service.pages.count > 1 {
                        Button(role: .destructive) {
                            removePage(at: index)
                        } label: {
                            Label("Delete Page", systemImage: "trash")
                        }
                    }
                }
            }

            ScriptQueueSection(
                currentPageIndex: service.currentPageIndex,
                query: scriptQuery,
                onLoad: { loadScript($0) },
                onMarkDone: { markScriptDone($0) }
            )
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) {
            if ScriptQueue.shared.vaultURL != nil {
                scriptSearchField
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                ScriptQueueMessage()
                RemoteQRPanel()

                Button {
                    if isRecording {
                        stopRecording()
                    }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        service.pages.append("")
                        moveToPage(service.pages.count - 1)
                    }
                } label: {
                    Label("Add Page", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
            .background(.regularMaterial)
        }
    }

    // MARK: - Actions

    /// Done = recorded: tag the vault page's note done (markDone saves the
    /// page's edits to the note first), then drop the page from the
    /// scratchpad. When the edits or the tag cannot be saved, the page stays
    /// (it can lose its link to the note), and an alert shows why.
    private func markPageDone(at index: Int) {
        let queue = ScriptQueue.shared
        guard index < service.pages.count, let path = queue.pageOrigins[index] else { return }
        if isRecording {
            stopRecording()                         // dictation must not write into the page now
        }
        guard queue.markDone(path) else {
            showMarkDoneProblem()
            return
        }
        if service.pages.count > 1 {
            removePage(at: index)
        } else {
            service.pages[0] = ""
        }
    }

    /// A Scripts row was clicked. Dictation stops first, so it cannot write
    /// into the note that replaces the page text. When the note opens on
    /// another page, the blank page the owner was on is removed, as in
    /// moveToPage.
    private func loadScript(_ item: QueueItem) {
        if isRecording {
            stopRecording()
        }
        let left = service.currentPageIndex
        ScriptQueue.shared.load(item)
        let now = service.currentPageIndex
        // Not when the note's page is blank too: then the two blank pages
        // cannot be told apart, and the note would lose its page.
        guard now < service.pages.count,
              !service.pages[now].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let move = Self.leavingBlankPage(service.pages, from: left, to: now)
        if let blank = move.remove {
            service.pages.remove(at: blank)
            service.currentPageIndex = move.target
        }
    }

    /// Mark Done from the Scripts list. The note in the vault page goes
    /// through the page's Mark Done; another note only gets the tag.
    private func markScriptDone(_ item: QueueItem) {
        let queue = ScriptQueue.shared
        if item.id == queue.slotPath, let index = queue.slotIndex {
            markPageDone(at: index)
        } else if !queue.markDone(item.id) {
            showMarkDoneProblem()
        }
    }

    /// The sidebar also shows the reason, but it can be hidden while the
    /// toolbar's Mark Script Done is used.
    private func showMarkDoneProblem() {
        markDoneError = ScriptQueue.shared.noteError ?? "The note is not marked done."
    }

    private func removePage(at index: Int) {
        guard service.pages.count > 1 else { return }
        if isRecording {
            stopRecording()
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            service.pages.remove(at: index)
            if service.currentPageIndex >= service.pages.count {
                service.currentPageIndex = service.pages.count - 1
            } else if service.currentPageIndex > index {
                service.currentPageIndex -= 1
            }
        }
    }

    private func run() {
        guard hasAnyContent else { return }
        // Resign text editor focus before hiding the window to avoid ViewBridge crashes
        isTextFocused = false
        service.onOverlayDismissed = { [self] in
            isRunning = false
            service.readPages.removeAll()
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
        service.readPages.removeAll()
        // If the current page is empty, find the first non-empty page
        let currentText = service.currentPageText.trimmingCharacters(in: .whitespacesAndNewlines)
        if currentText.isEmpty {
            if let firstNonEmpty = service.pages.firstIndex(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                service.currentPageIndex = firstNonEmpty
            }
        }
        service.readCurrentPage()
        isRunning = true
    }

    @State private var isImporting = false

    private func handlePresentationDrop(url: URL) {
        guard service.confirmDiscardIfNeeded() else { return }
        if isRecording {
            stopRecording()
        }
        isImporting = true

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let notes = try PresentationNotesExtractor.extractNotes(from: url)
                DispatchQueue.main.async {
                    ScriptQueue.shared.resetSlot()
                    service.pages = notes
                    service.savedPages = notes
                    service.currentPageIndex = 0
                    service.readPages.removeAll()
                    service.currentFileURL = nil
                    service.rememberDocumentURL(url)
                    isImporting = false
                }
            } catch {
                DispatchQueue.main.async {
                    dropError = error.localizedDescription
                    isImporting = false
                }
            }
        }
    }

    private func stop() {
        service.overlayController.dismiss()
        service.readPages.removeAll()
        isRunning = false
    }
}

// MARK: - About View

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var body: some View {
        VStack(spacing: 16) {
            // App icon
            if let icon = NSImage(named: "AppIcon") {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
            }

            // App name & version
            VStack(spacing: 4) {
                Text("Textream")
                    .font(.system(size: 20, weight: .bold))
                Text("Version \(appVersion)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            // Description
            Text("A free, open-source teleprompter that highlights your script in real-time as you speak.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)

            // Links
            HStack(spacing: 12) {
                Link(destination: URL(string: "https://github.com/f/textream")!) {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                        Text("GitHub")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.primary.opacity(0.08))
                    .clipShape(Capsule())
                }

                Link(destination: URL(string: "https://textream.net/privacy.html")!) {
                    HStack(spacing: 5) {
                        Image(systemName: "hand.raised.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Privacy")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.primary.opacity(0.08))
                    .clipShape(Capsule())
                }

                #if !APP_STORE
                Link(destination: URL(string: "https://donate.stripe.com/aFa8wO4NF2S96jDfn4dMI09")!) {
                    HStack(spacing: 5) {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.pink)
                        Text("Donate")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.pink.opacity(0.1))
                    .clipShape(Capsule())
                }
                #endif
            }

            Divider().padding(.horizontal, 20)

            VStack(spacing: 4) {
                Text("Made by Fatih Kadir Akin")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Original idea by Semih Kışlar")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Button("OK") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 320)
        .background(.ultraThinMaterial)
    }
}

#Preview {
    ContentView()
}


// MARK: - Remote QR Panel

/// Keeps the Remote Connection QR code on screen in the main window, so a phone
/// can be pointed at it without opening Settings. Hidden when Remote is off.
private struct RemoteQRPanel: View {
    @State private var localIP: String?
    @State private var qrImage: NSImage?

    private var url: String? {
        guard NotchSettings.shared.browserServerEnabled, let ip = localIP else { return nil }
        return "http://\(ip):\(NotchSettings.shared.browserServerPort)"
    }

    var body: some View {
        // A VStack, not a Group: with no QR yet a Group has no view, so its
        // onAppear never runs and the address is never read.
        VStack(spacing: 0) {
            if let url {
                VStack(spacing: 6) {
                    Divider()

                    if let qrImage {
                        Image(nsImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .padding(.top, 10)
                    }

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                    } label: {
                        Text(url)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.plain)
                    .help("Copy the remote URL")
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
                // Regenerate only when the address or port actually changes.
                .task(id: url) { qrImage = Self.qrCode(for: url) }
            }
        }
        .onAppear { localIP = BrowserServer.localIPAddress() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            localIP = BrowserServer.localIPAddress()
        }
    }

    private static func qrCode(for string: String) -> NSImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let ciImage = filter.outputImage else { return nil }
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage,
                       size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}


// MARK: - Script Queue Section

/// The last vault problem, at the bottom of the sidebar, so it stays in view
/// when the Scripts list scrolls. The list can have hundreds of rows, so a
/// message at its end is not seen. The sidebar can be hidden, so a refused
/// Mark Done also shows its reason in an alert. Local-only.
private struct ScriptQueueMessage: View {
    @State private var queue = ScriptQueue.shared

    var body: some View {
        if let err = queue.lastError {
            Text(err)
                .font(.system(size: 10))
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
        }
    }
}

/// Sidebar section listing vault notes tagged `script` and not `done`. Local-only.
private struct ScriptQueueSection: View {
    /// The selected page, so the row of the note shown in the editor is marked.
    let currentPageIndex: Int
    /// Text from the sidebar search field. Notes whose title does not match are hidden.
    let query: String
    /// ContentView handles the row actions: they stop dictation first.
    let onLoad: (QueueItem) -> Void
    let onMarkDone: (QueueItem) -> Void
    @State private var queue = ScriptQueue.shared

    var body: some View {
        let shown = queue.items.filter { ScriptQueue.titleMatches($0.title, query: query) }
        // Spaces alone do not filter, so they do not count as a search.
        let searching = query.contains { !$0.isWhitespace }
        Section {
            ForEach(shown) { item in
                Button {
                    onLoad(item)
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                        if !item.status.isEmpty || item.completion != nil {
                            Text([item.completion.map { "\($0)%" }, item.status.isEmpty ? nil : item.status]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                        if let base = item.duplicateOf {
                            Text("Possible copy of “\(base)”")
                                .font(.system(size: 9))
                                .foregroundStyle(.orange)
                                .lineLimit(1)
                        }
                    }
                    .foregroundStyle(queue.pageOrigins[currentPageIndex] == item.id ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 8))
                .listRowBackground(queue.pageOrigins[currentPageIndex] == item.id
                    ? Color.accentColor.opacity(0.15) : nil)
                .contextMenu {
                    Button("Mark Done") { onMarkDone(item) }
                }
            }
            if shown.isEmpty, searching {
                Text("No matches")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 8))
            }
        } header: {
            Button {
                if queue.vaultURL == nil { queue.pickVault() } else { queue.rescan() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "tray.full")
                        .font(.system(size: 10, weight: .semibold))
                    Text(queue.vaultURL == nil
                         ? "Choose Script Vault…"
                         : searching
                           ? "Scripts (\(shown.count) of \(queue.items.count))"
                           : "Scripts (\(queue.items.count))")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Rescan") { queue.rescan() }
                Button("Change Vault…") { queue.pickVault() }
            }
        }
    }
}
