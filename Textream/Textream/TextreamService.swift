//
//  TextreamService.swift
//  Textream
//
//  Created by Fatih Kadir Akın on 8.02.2026.
//

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

class TextreamService: NSObject, ObservableObject {
    static let shared = TextreamService()
    private static let lastDocumentURLDefaultsKey = "lastDocumentURL"
    let overlayController = NotchOverlayController()
    let externalDisplayController = ExternalDisplayController()
    let browserServer = BrowserServer()
    let directorServer = DirectorServer()
    var onOverlayDismissed: (() -> Void)?
    var launchedExternally = false
    @Published var directorIsReading = false

    @Published var pages: [String] = [""] {
        didSet {
            ScriptQueue.shared.pagesDidChange(from: oldValue, to: pages)
            scheduleDraftSave()
        }
    }
    @Published var currentPageIndex: Int = 0 {
        didSet { scheduleDraftSave() }
    }
    @Published var readPages: Set<Int> = []

    var hasNextPage: Bool {
        for i in (currentPageIndex + 1)..<pages.count {
            if !pages[i].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
        }
        return false
    }

    var currentPageText: String {
        guard currentPageIndex < pages.count else { return "" }
        return pages[currentPageIndex]
    }

    func readText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        launchedExternally = true
        hideMainWindow()

        overlayController.show(text: trimmed, hasNextPage: hasNextPage) { [weak self] in
            self?.externalDisplayController.dismiss()
            self?.browserServer.hideContent()
            self?.onOverlayDismissed?()
        }
        updatePageInfo()

        // Also show on external display if configured (same parsing as overlay)
        let words = splitTextIntoWords(trimmed)
        let totalCharCount = words.joined(separator: " ").count
        let paragraphBreaks = paragraphBreakWordIndices(in: trimmed)
        externalDisplayController.show(
            speechRecognizer: overlayController.speechRecognizer,
            words: words,
            totalCharCount: totalCharCount,
            paragraphBreakBeforeWordIndices: paragraphBreaks,
            hasNextPage: hasNextPage,
            scrollProgress: overlayController.scrollProgress
        )

        if browserServer.isRunning {
            browserServer.showContent(
                speechRecognizer: overlayController.speechRecognizer,
                words: words,
                totalCharCount: totalCharCount,
                hasNextPage: hasNextPage,
                scrollProgress: overlayController.scrollProgress
            )
        }
    }

    func readCurrentPage() {
        let trimmed = currentPageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        readPages.insert(currentPageIndex)
        readText(trimmed)
    }

    func advanceToNextPage() {
        // Skip empty pages
        var nextIndex = currentPageIndex + 1
        while nextIndex < pages.count {
            let text = pages[nextIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { break }
            nextIndex += 1
        }
        guard nextIndex < pages.count else { return }
        jumpToPage(index: nextIndex)
    }

    func jumpToPage(index: Int) {
        guard index >= 0 && index < pages.count else { return }
        let text = pages[index].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // Mute mic before switching page content
        let wasListening = overlayController.speechRecognizer.isListening
        if wasListening {
            overlayController.speechRecognizer.stop()
        }

        currentPageIndex = index
        readPages.insert(currentPageIndex)

        let trimmed = currentPageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Update content in-place without recreating the panel
        overlayController.updateContent(text: trimmed, hasNextPage: hasNextPage)
        updatePageInfo()

        // Also update external display content in-place
        let words = splitTextIntoWords(trimmed)
        externalDisplayController.overlayContent.words = words
        externalDisplayController.overlayContent.paragraphBreakBeforeWordIndices = paragraphBreakWordIndices(in: trimmed)
        externalDisplayController.overlayContent.totalCharCount = words.joined(separator: " ").count
        externalDisplayController.overlayContent.hasNextPage = hasNextPage

        if browserServer.isRunning {
            browserServer.updateContent(
                words: words,
                totalCharCount: words.joined(separator: " ").count,
                hasNextPage: hasNextPage
            )
        }

        // Unmute after new page content is loaded
        if wasListening {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let recognizer = self?.overlayController.speechRecognizer,
                      !recognizer.isListening,
                      !recognizer.isStarting else { return }
                recognizer.resume()
            }
        }
    }

    func updatePageInfo() {
        let pagePreviews = pages.enumerated().map { (i, text) in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return "" }
            let preview = String(trimmed.prefix(40))
            return preview + (trimmed.count > 40 ? "…" : "")
        }
        for content in [overlayController.overlayContent, externalDisplayController.overlayContent] {
            content.pageCount = pages.count
            content.currentPageIndex = currentPageIndex
            content.pagePreviews = pagePreviews
        }
    }

    func startAllPages() {
        readPages.removeAll()
        currentPageIndex = 0
        readCurrentPage()
    }

    func hideMainWindow() {
        DispatchQueue.main.async {
            for window in NSApp.windows where !(window is NSPanel) {
                window.makeFirstResponder(nil)
                window.orderOut(nil)
            }
        }
    }

    @Published var currentFileURL: URL? {
        didSet {
            // The sandbox lets the next launch open this file again only
            // through a security-scoped bookmark, made while access is granted.
            currentFileBookmark = try? currentFileURL?.bookmarkData(
                options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            if let scoped = scopedFileURL, scoped != currentFileURL {
                scoped.stopAccessingSecurityScopedResource()
                scopedFileURL = nil
            }
        }
    }
    @Published var savedPages: [String] = [""]
    /// Bookmark of currentFileURL, saved with the draft.
    private var currentFileBookmark: Data?
    /// The draft's file, opened from its bookmark at launch. Its access stays
    /// on while it is the current file, so Save can write to it.
    private var scopedFileURL: URL?

    // MARK: - Draft Autosave

    // Pages only ever lived in memory, so quitting without an explicit save to
    // a .textream file lost the work outright. Mirror them to UserDefaults so
    // the editor comes back as it was left.
    private enum DraftKey {
        static let pages = "draftPages"
        static let pageIndex = "draftPageIndex"
        static let fileURL = "draftFileURL"
        static let fileBookmark = "draftFileBookmark"
    }

    private var draftSaveWork: DispatchWorkItem?
    /// The first restoreDraft result. Nil until the draft is restored.
    private var draftRestoreResult: Bool?
    private var draftRestored: Bool { draftRestoreResult != nil }

    private func scheduleDraftSave() {
        guard draftRestored else { return }
        draftSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveDraft() }
        draftSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Writes immediately. Called on quit and on hide, where a debounce would lose the tail.
    func saveDraft() {
        // Before the restore, `pages` is not the draft: never write it over the saved one.
        guard draftRestored else { return }
        draftSaveWork?.cancel()
        let defaults = UserDefaults.standard
        // While Director text fills the pages, the draft keeps the pages from before.
        let draft = directorSnapshot ?? (pages: pages, index: currentPageIndex)
        defaults.set(draft.pages, forKey: DraftKey.pages)
        defaults.set(draft.index, forKey: DraftKey.pageIndex)
        defaults.set(currentFileURL?.path, forKey: DraftKey.fileURL)
        defaults.set(currentFileBookmark, forKey: DraftKey.fileBookmark)
        ScriptQueue.shared.scheduleSync()
    }

    /// Puts back the saved pages (see draftState). Returns false only when no
    /// draft was ever saved (a first launch), so the caller can show the
    /// sample script. Runs once: a later call returns the first result.
    @discardableResult
    func restoreDraft() -> Bool {
        if let restored = draftRestoreResult { return restored }
        let defaults = UserDefaults.standard
        guard let draft = Self.draftState(stored: defaults.stringArray(forKey: DraftKey.pages),
                                          index: defaults.integer(forKey: DraftKey.pageIndex),
                                          keepBlankPages: defaults.string(forKey: DraftKey.fileURL) != nil)
        else {
            draftRestoreResult = false
            return false
        }

        pages = draft.pages
        currentPageIndex = draft.index

        ScriptQueue.shared.restoreOrigins()

        // Reattach to the file it came from, so Save still targets it and the
        // unsaved-changes dot stays accurate.
        if let url = reopenDraftFile(defaults),
           let data = try? Data(contentsOf: url),
           let onDisk = try? JSONDecoder().decode([String].self, from: data), !onDisk.isEmpty {
            currentFileURL = url
            savedPages = onDisk
        } else if let scoped = scopedFileURL {
            scoped.stopAccessingSecurityScopedResource()
            scopedFileURL = nil
        }
        draftRestoreResult = true
        return true
    }

    /// The saved draft without its blank pages. Copies stay, and one page
    /// always stays. A draft of a file keeps its blank pages: they can be
    /// pages of the file, and without them the file shows as changed. The
    /// same page stays selected; when it was blank, the nearest page before
    /// it (or the first page). Nil when no draft was ever saved.
    static func draftState(stored: [String]?, index: Int, keepBlankPages: Bool) -> (pages: [String], index: Int)? {
        guard let stored else { return nil }
        let selected = min(max(0, index), stored.count - 1)
        var pages: [String] = []
        var newIndex = 0
        for (i, page) in stored.enumerated() {
            if keepBlankPages || !page.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pages.append(page)
            }
            if i == selected { newIndex = max(0, pages.count - 1) }
        }
        return pages.isEmpty ? ([""], 0) : (pages, newIndex)
    }

    /// The file the draft came from. In the sandbox only its bookmark can open
    /// it again. That access starts here and stays on while it is the current
    /// file (see currentFileURL). A file on a disk that is not connected is
    /// skipped: launch never waits for a disk or shows a dialog.
    private func reopenDraftFile(_ defaults: UserDefaults) -> URL? {
        var stale = false   // a stale bookmark is made again when currentFileURL is set
        if let bookmark = defaults.data(forKey: DraftKey.fileBookmark),
           let url = try? URL(resolvingBookmarkData: bookmark,
                              options: [.withSecurityScope, .withoutUI, .withoutMounting],
                              relativeTo: nil, bookmarkDataIsStale: &stale),
           url.startAccessingSecurityScopedResource() {
            scopedFileURL = url
            return url
        }
        return defaults.string(forKey: DraftKey.fileURL).map { URL(fileURLWithPath: $0) }
    }

    // MARK: - File Operations

    private var lastDocumentDirectoryURL: URL? {
        guard let path = UserDefaults.standard.string(forKey: Self.lastDocumentURLDefaultsKey),
              !path.isEmpty else { return nil }

        let directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: directoryURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else { return nil }
        return directoryURL
    }

    func rememberDocumentURL(_ url: URL) {
        guard url.isFileURL else { return }
        UserDefaults.standard.set(
            url.standardizedFileURL.path,
            forKey: Self.lastDocumentURLDefaultsKey
        )
    }

    func saveFile() {
        if let url = currentFileURL {
            saveToURL(url)
        } else {
            saveFileAs()
        }
    }

    func saveFileAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "textream")!]
        panel.nameFieldStringValue = "Untitled.textream"
        panel.canCreateDirectories = true
        panel.directoryURL = currentFileURL?.deletingLastPathComponent()
            ?? lastDocumentDirectoryURL

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.saveToURL(url)
        }
    }

    private func saveToURL(_ url: URL) {
        do {
            let toSave = userPages   // not the text of a running Director session
            let data = try JSONEncoder().encode(toSave)
            try data.write(to: url, options: .atomic)
            currentFileURL = url
            savedPages = toSave
            rememberDocumentURL(url)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Failed to save file"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    var hasUnsavedChanges: Bool {
        userPages != savedPages
    }

    /// The user's pages. During a Director session its text fills `pages`
    /// and the user's pages are held until the session ends. Save writes
    /// these pages and the unsaved-changes check compares them.
    static func userPages(_ pages: [String], held: [String]?) -> [String] {
        held ?? pages
    }

    var userPages: [String] { Self.userPages(pages, held: directorSnapshot?.pages) }

    /// Shows pages from a file or presentation. During a Director session they
    /// become the held pages: the session keeps its text, and the loaded pages
    /// show when it ends.
    private func showLoadedPages(_ loaded: [String]) {
        ScriptQueue.shared.resetSlot()
        if directorSnapshot != nil {
            directorSnapshot = (loaded, 0)
            scheduleDraftSave()
        } else {
            pages = loaded
            currentPageIndex = 0
        }
        savedPages = loaded
        readPages.removeAll()
    }

    func openFile() {
        guard confirmDiscardIfNeeded() else { return }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            .init(filenameExtension: "textream")!,
            .init(filenameExtension: "key")!,
            .init(filenameExtension: "pptx")!,
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = currentFileURL?.deletingLastPathComponent()
            ?? lastDocumentDirectoryURL

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            let ext = url.pathExtension.lowercased()
            if ext == "key" {
                let alert = NSAlert()
                alert.messageText = "Keynote files can't be imported directly"
                alert.informativeText = "Please export your Keynote presentation as PowerPoint (.pptx) first:\n\nIn Keynote: File → Export To → PowerPoint"
                alert.alertStyle = .informational
                alert.runModal()
            } else if ext == "pptx" {
                self?.importPresentation(from: url)
            } else {
                self?.openFileAtURL(url)
            }
        }
    }

    func importPresentation(from url: URL) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let notes = try PresentationNotesExtractor.extractNotes(from: url)
                DispatchQueue.main.async {
                    self?.showLoadedPages(notes)
                    self?.currentFileURL = nil
                    self?.rememberDocumentURL(url)
                }
            } catch {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Import Error"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }

    /// Returns true if it's safe to proceed (saved, discarded, or no changes).
    /// Returns false if the user cancelled.
    func confirmDiscardIfNeeded() -> Bool {
        guard hasUnsavedChanges else { return true }

        let alert = NSAlert()
        alert.messageText = "You have unsaved changes"
        alert.informativeText = "Do you want to save your changes before opening another file?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            saveFile()
            return true
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    /// Closing the main window quits Textream. The draft autosave keeps the
    /// pages, as it does for Cmd-Q, so only an open file with unsaved changes
    /// asks. Returns false when the user cancels or the save fails.
    func confirmCloseIfNeeded() -> Bool {
        restorePagesAfterDirector()   // compare and save the pages from before Director
        guard let url = currentFileURL, hasUnsavedChanges else { return true }

        let alert = NSAlert()
        alert.messageText = "Save changes to “\(url.deletingPathExtension().lastPathComponent)”?"
        alert.informativeText = "If you do not save, your changes to this file are lost."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            saveFile()
            return !hasUnsavedChanges     // the save failed: keep the window open
        case .alertSecondButtonReturn:
            // Unlink the vault page without saving it, so the file's older
            // text never reaches the note.
            ScriptQueue.shared.dropSlot()
            pages = savedPages
            currentPageIndex = min(currentPageIndex, pages.count - 1)
            return true
        default:
            return false
        }
    }

    func openFileAtURL(_ url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let loadedPages = try JSONDecoder().decode([String].self, from: data)
            guard !loadedPages.isEmpty else { return }
            showLoadedPages(loadedPages)
            currentFileURL = url
            rememberDocumentURL(url)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Failed to open file"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    // MARK: - Browser Server

    func updateBrowserServer() {
        if NotchSettings.shared.browserServerEnabled {
            if !browserServer.isRunning {
                browserServer.start()
            }
        } else {
            browserServer.stop()
        }
    }

    // MARK: - Director Server

    func updateDirectorServer() {
        if NotchSettings.shared.directorModeEnabled {
            if !directorServer.isRunning {
                directorServer.start()
                wireDirectorCallbacks()
            }
        } else {
            directorServer.stop()
            if directorIsReading {
                overlayController.dismiss()
                directorIsReading = false
            }
            restorePagesAfterDirector()   // the editor shows again
        }
    }

    /// The pages and the selected page from before a Director session. The
    /// draft keeps them, and they come back when the session ends.
    private var directorSnapshot: (pages: [String], index: Int)?

    /// Call before Director text replaces the pages. Before the draft is
    /// restored the pages are not the user's, so there is nothing to hold.
    private func holdPagesForDirector() {
        if directorSnapshot == nil, draftRestored {
            directorSnapshot = (pages, currentPageIndex)
        }
    }

    private func restorePagesAfterDirector() {
        guard let snapshot = directorSnapshot else { return }
        directorSnapshot = nil
        ScriptQueue.shared.resetSlot()
        pages = snapshot.pages
        currentPageIndex = min(snapshot.index, pages.count - 1)
    }

    private func wireDirectorCallbacks() {
        directorServer.onSetText = { [weak self] text in
            self?.setTextFromDirector(text)
        }
        directorServer.onUpdateText = { [weak self] text, readCharCount in
            self?.updateTextFromDirector(text, readCharCount: readCharCount)
        }
        directorServer.onStop = { [weak self] in
            self?.stopDirectorReading()
        }
    }

    func setTextFromDirector(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Director mode is single page
        ScriptQueue.shared.resetSlot()
        holdPagesForDirector()
        pages = [trimmed]
        currentPageIndex = 0
        readPages.removeAll()

        // Force word tracking mode for director
        let savedMode = NotchSettings.shared.listeningMode
        NotchSettings.shared.listeningMode = .wordTracking

        directorIsReading = true

        overlayController.show(text: trimmed, hasNextPage: false) { [weak self] in
            self?.directorIsReading = false
            self?.directorServer.hideContent()
            self?.externalDisplayController.dismiss()
            self?.browserServer.hideContent()
            // Restore listening mode
            NotchSettings.shared.listeningMode = savedMode
            self?.restorePagesAfterDirector()
        }

        // Feed director server with speech recognizer
        let words = splitTextIntoWords(trimmed)
        let totalCharCount = words.joined(separator: " ").count
        directorServer.showContent(
            speechRecognizer: overlayController.speechRecognizer,
            words: words,
            totalCharCount: totalCharCount
        )

        // Also show on external display & browser if configured
        let paragraphBreaks = paragraphBreakWordIndices(in: trimmed)
        externalDisplayController.show(
            speechRecognizer: overlayController.speechRecognizer,
            words: words,
            totalCharCount: totalCharCount,
            paragraphBreakBeforeWordIndices: paragraphBreaks,
            hasNextPage: false,
            scrollProgress: overlayController.scrollProgress
        )
        if browserServer.isRunning {
            browserServer.showContent(
                speechRecognizer: overlayController.speechRecognizer,
                words: words,
                totalCharCount: totalCharCount,
                hasNextPage: false,
                scrollProgress: overlayController.scrollProgress
            )
        }
    }

    func updateTextFromDirector(_ text: String, readCharCount: Int) {
        guard directorIsReading else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        ScriptQueue.shared.resetSlot()
        holdPagesForDirector()
        pages = [trimmed]

        let words = splitTextIntoWords(trimmed)
        let totalCharCount = words.joined(separator: " ").count

        // Preserve only the prefix that was both recognized by the Mac and
        // locked in the director's edit snapshot. Recognition can advance
        // while an update is in flight, so trusting either count alone could
        // make newly read text unexpectedly editable or overwriteable.
        let recognizedCharCount = overlayController.speechRecognizer.recognizedCharCount
        let preservedCharCount = min(
            totalCharCount,
            min(recognizedCharCount, max(0, readCharCount))
        )

        // Update overlay content without resetting speech progress
        overlayController.overlayContent.words = words
        overlayController.overlayContent.paragraphBreakBeforeWordIndices = paragraphBreakWordIndices(in: trimmed)
        overlayController.overlayContent.totalCharCount = totalCharCount
        overlayController.overlayContent.hasNextPage = false

        // Update the speech recognizer with new full text but keep char count
        overlayController.speechRecognizer.updateText(trimmed, preservingCharCount: preservedCharCount)

        // Update director server
        directorServer.updateContent(words: words, totalCharCount: totalCharCount)

        // Update external display & browser
        externalDisplayController.overlayContent.words = words
        externalDisplayController.overlayContent.paragraphBreakBeforeWordIndices = paragraphBreakWordIndices(in: trimmed)
        externalDisplayController.overlayContent.totalCharCount = totalCharCount
        if browserServer.isRunning {
            browserServer.updateContent(
                words: words,
                totalCharCount: totalCharCount,
                hasNextPage: false
            )
        }
    }

    func stopDirectorReading() {
        guard directorIsReading else { return }
        overlayController.dismiss()
        directorIsReading = false
    }

    func updateKeepAwakeActivity(enabled: Bool) {
        overlayController.updateKeepAwakeActivity(enabled: enabled)
    }

    // macOS Services handler
    @objc func readInTextream(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = pboard.string(forType: .string) else {
            error.pointee = "No text found on pasteboard" as NSString
            return
        }
        readText(text)
    }

    // URL scheme handler: textream://read?text=Hello%20World
    func handleURL(_ url: URL) {
        guard url.scheme == "textream" else { return }

        if url.host == "read" || url.path == "/read" {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let textParam = components.queryItems?.first(where: { $0.name == "text" })?.value {
                readText(textParam)
            }
        }
    }
}
