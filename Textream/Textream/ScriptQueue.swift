//
//  ScriptQueue.swift
//  Textream
//
//  Local-only feature: browse an Obsidian vault for notes tagged `script`
//  in YAML frontmatter, load one into the editor, and mark it done by
//  adding `done` to its frontmatter tags. Not intended for upstream.
//

import SwiftUI
import UniformTypeIdentifiers

struct ScanError: Error { let message: String; init(_ m: String) { message = m } }

struct QueueItem: Identifiable, Equatable {
    let id: String        // file path
    let url: URL
    let title: String
    let status: String
    let completion: Int?   // frontmatter "completion %"
    /// Set when this note looks like an iCloud copy of `<duplicateOf>.md`.
    var duplicateOf: String? = nil
}

@Observable
class ScriptQueue {
    static let shared = ScriptQueue()

    var items: [QueueItem] = []
    var vaultURL: URL?

    /// Shown in red at the bottom of the sidebar: the last load, save or Mark
    /// Done problem, then any scan problem. Setting it sets only the first
    /// part, so a scan can never hide or clear a message about a note.
    var lastError: String? {
        get {
            let parts = [noteError, scanError].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        }
        set { noteError = newValue }
    }
    /// The first part of lastError. A refused Mark Done shows it in an alert.
    private(set) var noteError: String?
    private var scanError: String?

    private static let bookmarkKey = "scriptQueueVaultBookmark"

    init() {
        restoreBookmark()
        if vaultURL != nil { rescan() }
    }

    // MARK: - Vault access

    func pickVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose your Obsidian vault folder"
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                let data = try url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil, relativeTo: nil)
                // Another folder: save and unlink the vault page while the old
                // vault's access still works. Its note is not in the new vault.
                if url.standardizedFileURL.path != self.vaultURL?.standardizedFileURL.path {
                    self.resetSlot()
                }
                UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
                self.vaultURL = url
                self.scanGeneration += 1      // a scan of the old vault is now stale
                self.scanCache = [:]
                self.items = []
                self.scanError = nil
                self.rescan()
            } catch {
                self.lastError = "Could not save vault access: \(error.localizedDescription)"
            }
        }
    }

    private func restoreBookmark() {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        var stale = false
        if let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil, bookmarkDataIsStale: &stale) {
            vaultURL = url
            if stale, url.startAccessingSecurityScopedResource() {
                defer { url.stopAccessingSecurityScopedResource() }
                if let fresh = try? url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil, relativeTo: nil) {
                    UserDefaults.standard.set(fresh, forKey: Self.bookmarkKey)
                }
            }
        }
    }

    // MARK: - Scan

    private(set) var scanning = false
    private var rescanPending = false
    private var scanGeneration = 0
    /// Last result per note path, so a rescan reads only the notes that changed.
    private var scanCache: [String: ScanCacheEntry] = [:]

    struct ScanCacheEntry {
        let modified: Date?
        let size: Int?
        let item: QueueItem?   // nil: not a listed script
    }

    struct ScanResult {
        let items: [QueueItem]
        let cache: [String: ScanCacheEntry]
        let note: String?
    }

    /// Safe to call often. A call during a scan runs one more scan when that
    /// scan ends, and notes that did not change are not read again.
    func rescan() {
        guard let vault = vaultURL else { return }
        guard !scanning else { rescanPending = true; return }
        scanning = true
        rescanPending = false
        let generation = scanGeneration
        let cache = scanCache
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Self.scan(vault: vault, cache: cache)
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanning = false
                if generation == self.scanGeneration {
                    switch result {
                    case .success(let found):
                        if self.items != found.items { self.items = found.items }
                        self.scanCache = found.cache
                        if self.scanError != found.note { self.scanError = found.note }
                    case .failure(let e):
                        self.scanError = e.message
                    }
                }
                if self.rescanPending { self.rescan() }
            }
        }
    }

    private static func scan(vault: URL, cache: [String: ScanCacheEntry]) -> Result<ScanResult, ScanError> {
        guard vault.startAccessingSecurityScopedResource() else {
            return .failure(ScanError("Vault access denied. Choose the vault folder again."))
        }
        defer { vault.stopAccessingSecurityScopedResource() }

        var found: [QueueItem] = []
        var newCache: [String: ScanCacheEntry] = [:]
        var created: [String: Date] = [:]      // every note, for the copy check
        var notDownloaded = 0
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .creationDateKey]
        let walker = FileManager.default.enumerator(
            at: vault, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles])
        while let file = walker?.nextObject() as? URL {
            guard file.pathExtension == "md" else { continue }
            let path = file.path
            let values = try? file.resourceValues(forKeys: Set(keys))
            created[path] = values?.creationDate
            let modified = values?.contentModificationDate, size = values?.fileSize
            if let hit = cache[path], modified != nil, hit.modified == modified, hit.size == size {
                newCache[path] = hit
                if let item = hit.item { found.append(item) }
                continue
            }
            // iCloud removed this note's content from the Mac. Reading it
            // would wait for a download, or fail when offline. Ask for the
            // download: a later scan can read the note when it is here.
            if isDataless(path) {
                notDownloaded += 1
                try? FileManager.default.startDownloadingUbiquitousItem(at: file)
                continue
            }
            guard let head = readNoteHead(file) else { continue }
            var item: QueueItem?
            if let fm = frontmatter(of: head) {
                let noteTags = tags(in: fm)
                if noteTags.contains("script"), !noteTags.contains("done") {
                    item = QueueItem(
                        id: path, url: file,
                        title: file.deletingPathExtension().lastPathComponent,
                        status: statusValue(in: fm),
                        completion: completionPercent(in: fm))
                }
            }
            newCache[path] = ScanCacheEntry(modified: modified, size: size, item: item)
            if let item { found.append(item) }
        }
        for i in found.indices {
            found[i].duplicateOf = possibleDuplicate(of: found[i].id, created: created)
        }
        func rank(_ s: String) -> Int {
            if s.localizedCaseInsensitiveContains("ready") { return 0 }
            if s == "Next up" { return 1 }
            if s == "Scheduled" { return 3 }
            return 2
        }
        // Highest completion first; then ready to record, Next up, other or
        // no status, Scheduled; then title.
        let sorted = found.sorted {
            (-($0.completion ?? -1), rank($0.status), $0.title)
                < (-($1.completion ?? -1), rank($1.status), $1.title)
        }
        let note: String?
        switch notDownloaded {
        case 0: note = nil
        case 1: note = "1 vault note is not downloaded yet. Scan again later."
        default: note = "\(notDownloaded) vault notes are not downloaded yet. Scan again later."
        }
        return .success(ScanResult(items: sorted, cache: newCache, note: note))
    }

    /// True for an iCloud note whose content is not on this Mac.
    private static func isDataless(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_flags & UInt32(SF_DATALESS) != 0
    }

    /// The start of a note, enough to read its frontmatter: the first 16 KB,
    /// or the whole file when the frontmatter does not end in them or the
    /// cut falls inside a character.
    private static func readNoteHead(_ url: URL) -> String? {
        let limit = 16 * 1024
        if let handle = try? FileHandle(forReadingFrom: url) {
            let data = try? handle.read(upToCount: limit)
            try? handle.close()
            if let data, let text = String(data: data, encoding: .utf8),
               data.count < limit || !text.hasPrefix("---") || frontmatter(of: text) != nil {
                return text
            }
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// iCloud saves a sync conflict as "<base> <N>.md" next to "<base>.md",
    /// with the same creation time. Returns <base> for such a note. A real
    /// note with a number in its name has a creation time of its own.
    static func possibleDuplicate(of path: String, created: [String: Date]) -> String? {
        let stem = noteTitle(path)
        guard let number = stem.range(of: #" \d+$"#, options: .regularExpression),
              number.lowerBound > stem.startIndex else { return nil }
        let base = String(stem[..<number.lowerBound])
        let basePath = ((path as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent(base + ".md")
        guard let a = created[path], let b = created[basePath],
              abs(a.timeIntervalSince(b)) <= 2 else { return nil }
        return base
    }

    // MARK: - The vault slot
    //
    // Exactly one page can be a live view of a vault note. Browsing the queue
    // swaps that one slot; everything else in the page list is the user's own.
    // One slot means one (index, path) pair to keep honest. The previous
    // index-map design corrupted itself when indices drifted, mapping vault
    // paths onto unrelated pages.
    //
    // A write goes to the note only while the note still holds the body that
    // Textream last loaded or wrote. When it does not, the page is unlinked
    // and keeps its text: nothing is written.

    /// Saved as [path, page text, synced body]. Older builds saved [path, body].
    private static let slotKey = "vaultSlot"

    private(set) var slotIndex: Int?
    private(set) var slotPath: String?
    /// The note body as Textream last loaded or wrote it, in normalizedBody form.
    private var slotSyncedBody: String?
    /// Last observed text of the slot page, used to find the page again when
    /// the page list changes, so the slot can never point at another page.
    private var slotPageText: String?
    private var syncWork: DispatchWorkItem?

    var pageOrigins: [Int: String] {   // kept for the view layer's checks
        guard let i = slotIndex, let p = slotPath else { return [:] }
        return [i: p]
    }

    private var slotTitle: String { slotPath.map(Self.noteTitle) ?? "The note" }

    static func noteTitle(_ path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    private func persistSlot() {
        let pages = TextreamService.shared.pages
        if let i = slotIndex, let p = slotPath, let synced = slotSyncedBody, i < pages.count {
            UserDefaults.standard.set([p, pages[i], synced], forKey: Self.slotKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.slotKey)
        }
    }

    /// Reads a saved slot as (path, page text, synced body). An older
    /// [path, body] record has no synced body: its body is the page text,
    /// which can hold edits that were never written to the note.
    static func slotRecord(_ saved: [String]) -> (path: String, pageText: String, synced: String?)? {
        switch saved.count {
        case 3: return (saved[0], saved[1], normalizedBody(saved[2]))
        case 2: return (saved[0], saved[1], nil)   // older builds
        default: return nil
        }
    }

    /// How the saved page links to its note at launch, from the note's text
    /// now: the synced body, and the page's new text when the note changed
    /// and the page had no unsaved edits (as in load()). Nil when the note
    /// changed and the page can have edits that the note does not have, or
    /// when the note has no frontmatter: then it is not linked. When the
    /// note did not change, the page links and the next sync writes its
    /// unsaved edits. An older record has no synced body, so it cannot show
    /// which text is unsaved: its page links only while the note has the
    /// page's text.
    static func relink(pageText: String, synced: String?, note text: String) -> (synced: String, page: String?)? {
        let page = normalizedBody(pageText)
        guard let synced else { return noteMatches(text, synced: page) ? (page, nil) : nil }
        if noteMatches(text, synced: synced) { return (synced, nil) }
        guard page == synced, let body = splitFrontmatter(text)?.body else { return nil }
        return (body, body)
    }

    /// The launch message when relink refuses the saved page. An older
    /// record cannot show which side changed, so its message does not say
    /// that the note changed.
    static func relinkRefusedMessage(_ title: String, olderRecord: Bool) -> String {
        olderRecord
            ? "“\(title)” does not have the text of its page. Its page is no longer linked to it."
            : "“\(title)” changed while Textream was closed. Its page is no longer linked to it."
    }

    /// Reattaches the saved slot at launch, only to the one page that holds
    /// its text, and only as relink allows. A page that can have unsaved
    /// edits stays as ordinary text when the note changed: writing them
    /// would lose the change.
    func restoreOrigins() {
        guard slotIndex == nil,
              let saved = UserDefaults.standard.stringArray(forKey: Self.slotKey) else { return }
        UserDefaults.standard.removeObject(forKey: Self.slotKey)
        guard let record = Self.slotRecord(saved),
              !record.pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        let title = Self.noteTitle(record.path)
        let service = TextreamService.shared
        let matches = service.pages.indices.filter { service.pages[$0] == record.pageText }
        guard matches.count == 1 else {
            if matches.count > 1 { lastError = "“\(title)” is no longer linked to a page." }
            return
        }
        guard let vault = vaultURL, vault.startAccessingSecurityScopedResource() else { return }
        defer { vault.stopAccessingSecurityScopedResource() }
        guard FileManager.default.fileExists(atPath: record.path) else {
            lastError = "Can't find “\(title)”. It may have been renamed or moved. The text is still in the page."
            return
        }
        guard let text = try? String(contentsOf: URL(fileURLWithPath: record.path), encoding: .utf8) else {
            lastError = "Could not read “\(title)”. Its page is no longer linked to it."
            return
        }
        guard let link = Self.relink(pageText: record.pageText, synced: record.synced, note: text) else {
            lastError = Self.relinkRefusedMessage(title, olderRecord: record.synced == nil)
            return
        }
        let idx = matches[0]
        if let page = link.page { service.pages[idx] = page }   // no slot yet, so nothing follows or syncs this
        slotIndex = idx
        slotPath = record.path
        slotSyncedBody = link.synced
        slotPageText = service.pages[idx]
        persistSlot()
    }

    /// The page list is about to be replaced wholesale (file open, import,
    /// director): the slot's index will no longer mean anything. Flush, then
    /// drop it.
    func resetSlot() {
        syncEdits()
        dropSlot()
    }

    /// Unlinks the vault page without saving it. Its text stays in the page,
    /// and nothing is written to the note.
    func dropSlot() {
        slotIndex = nil; slotPath = nil; slotSyncedBody = nil; slotPageText = nil
        persistSlot()
    }

    /// Called on every change to the page list. Keeps the slot attached to
    /// the same page through edits, inserts, removals and reorders, and drops
    /// it when that page is gone or cannot be told apart from another page.
    /// Without this, any code path that replaced the pages without telling
    /// the queue left the slot pointing at another page, and the next sync
    /// wrote that page's text into the vault note.
    func pagesDidChange(from old: [String], to new: [String]) {
        guard let i = slotIndex, let tracked = slotPageText else { return }
        switch Self.followSlot(index: i, tracked: tracked, old: old, new: new) {
        case .unchanged: break
        case .edited(let text): slotPageText = text
        case .moved(let j): slotIndex = j
        case .lost:
            // Quiet when the page is gone (deleted on purpose) or blank. When
            // its text is still here, the page could not be told apart: say so.
            if !tracked.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, new.contains(tracked) {
                lastError = "“\(slotTitle)” is no longer linked to a page."
            }
            dropSlot()
        }
    }

    enum SlotChange: Equatable { case unchanged, edited(String), moved(Int), lost }

    static func followSlot(index i: Int, tracked: String, old: [String], new: [String]) -> SlotChange {
        if old.count == new.count, i < new.count {
            if new[i] == tracked { return .unchanged }
            // Only the slot page changed: an edit of any size (typing, paste,
            // dictation, undo). Every wholesale replacement of the pages
            // resets the slot first, and load() sets the slot itself.
            if new.indices.allSatisfy({ $0 == i || new[$0] == old[$0] }) { return .edited(new[i]) }
        }
        if i < old.count, old[i] == tracked {
            // One page added at the end (Add Page, Cmd-N): the slot page did not move.
            if new.count == old.count + 1, new.starts(with: old) { return .unchanged }
            // One page removed (Delete Page, a blank page left). Every page
            // whose removal gives `new` could be the one. When all of them
            // are on one side of the slot page, its place is certain, even
            // when another page has the same text.
            if new.count + 1 == old.count {
                let removed = old.indices.filter {
                    old[..<$0].elementsEqual(new[..<$0]) && old[($0 + 1)...].elementsEqual(new[$0...])
                }
                if !removed.isEmpty, removed.allSatisfy({ $0 > i }) { return .unchanged }
                if !removed.isEmpty, removed.allSatisfy({ $0 < i }) { return .moved(i - 1) }
            }
        }
        // Pages were replaced or reordered, or the removed page could be the
        // slot page. Text is the only way to find the page again, and only
        // text that is on exactly one page before and after: a blank page or
        // a copy could be another page.
        guard !tracked.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              old.filter({ $0 == tracked }).count == 1,
              let j = new.firstIndex(of: tracked), new.lastIndex(of: tracked) == j
        else { return .lost }
        return j == i ? .unchanged : .moved(j)
    }

    /// Index of the one page whose text, as a note body, is `body`. Nil when
    /// no page or more than one page has it.
    static func onlyPage(withBody body: String, in pages: [String]) -> Int? {
        let hits = pages.indices.filter { normalizedBody(pages[$0]) == body }
        return hits.count == 1 ? hits[0] : nil
    }

    func load(_ item: QueueItem) {
        guard let vault = vaultURL, vault.startAccessingSecurityScopedResource() else {
            lastError = "Could not open the vault. Choose the vault folder again."
            return
        }
        defer { vault.stopAccessingSecurityScopedResource() }
        guard let text = try? String(contentsOf: item.url, encoding: .utf8) else {
            lastError = "Could not read “\(item.title)”."
            rescan()                               // it may have been renamed or moved
            return
        }
        lastError = nil                            // before the flush, so its message stays
        let body = Self.stripFrontmatter(text)
        let service = TextreamService.shared

        if slotPath == item.id, let idx = slotIndex, idx < service.pages.count {
            // Already open. Show the note's new text only when it changed
            // outside Textream and this page has no unsaved edits.
            if body == slotSyncedBody || Self.normalizedBody(service.pages[idx]) != slotSyncedBody {
                service.currentPageIndex = idx
                return
            }
        } else if !syncEdits() {
            // The outgoing page has text the note does not have. Keep it as an
            // ordinary page; the new note goes to another page.
            dropSlot()
        }

        // The note is already on one page: link that page, never a copy. A
        // vault page of another note keeps its (saved) text.
        let onPage = body.isEmpty || slotPath == item.id
            ? nil : Self.onlyPage(withBody: body, in: service.pages)
        if let idx = onPage {
            slotIndex = idx
            service.currentPageIndex = idx
        } else if let idx = slotIndex, idx < service.pages.count {
            service.pages[idx] = body              // swap the existing slot
            service.currentPageIndex = idx
        } else {
            let cur = service.currentPageIndex
            if cur < service.pages.count,
               service.pages[cur].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                service.pages[cur] = body
                slotIndex = cur
            } else {
                service.pages.append(body)
                service.currentPageIndex = service.pages.count - 1
                slotIndex = service.pages.count - 1
            }
        }
        guard let idx = slotIndex else { return }
        slotPath = item.id
        slotSyncedBody = body
        slotPageText = service.pages[idx]
        persistSlot()
    }

    /// Called from saveDraft. Saves the slot with the same page text as the
    /// saved draft, so the next launch can find the page, then writes the
    /// edits back to the note after a short pause.
    func scheduleSync() {
        if slotIndex != nil { persistSlot() }   // never drops a record restoreOrigins has not read
        syncWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.syncEdits() }
        syncWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    /// Writes the slot page into its note body, keeping the frontmatter.
    /// Returns true when there is nothing to write or the write worked, and
    /// false when page text that the note does not have was not written.
    @discardableResult
    func syncEdits() -> Bool {
        syncWork?.cancel()
        guard let idx = slotIndex, let path = slotPath else { return true }
        let pages = TextreamService.shared.pages
        guard idx < pages.count else { dropSlot(); return true }
        let body = Self.normalizedBody(pages[idx])
        // Never write an empty body over a note, and skip unchanged text.
        guard !body.isEmpty, body != slotSyncedBody else { return true }
        let title = Self.noteTitle(path)
        guard let vault = vaultURL, vault.startAccessingSecurityScopedResource() else {
            lastError = "Could not open the vault. Your last edits are not in “\(title)”."
            return false
        }
        defer { vault.stopAccessingSecurityScopedResource() }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            dropSlot()
            lastError = "Can't find “\(title)”. It may have been renamed or moved. The text is still in the page."
            return false
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            lastError = "Could not read “\(title)”. Your last edits are not in it."
            return false
        }
        // No frontmatter (a half-saved note) or another body (an edit outside
        // Textream): writing now would lose that text.
        guard let synced = slotSyncedBody, Self.noteMatches(text, synced: synced),
              let head = Self.splitFrontmatter(text)?.head else {
            dropSlot()
            lastError = "“\(title)” changed outside Textream. This page is no longer linked to it."
            return false
        }
        do {
            try Self.writeNote(head + body + "\n", to: url)
        } catch {
            lastError = "Could not save “\(title)”: \(error.localizedDescription)"
            return false
        }
        slotSyncedBody = body
        persistSlot()
        lastError = nil
        return true
    }

    /// Replaces a note's text in one step and keeps its creation date, Finder
    /// tags and other extended attributes. Writes through a symlink to the
    /// real file. The note is never deleted, but a failed swap can leave the
    /// original in the replacement folder, which is then kept.
    static func writeNote(_ text: String, to url: URL) throws {
        let files = FileManager.default
        let target = url.resolvingSymlinksInPath()
        let dir = try files.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                appropriateFor: target, create: true)
        let temp = dir.appendingPathComponent(target.lastPathComponent)
        do {
            try Data(text.utf8).write(to: temp)
            _ = try files.replaceItemAt(target, withItemAt: temp)
        } catch {
            // After a failed swap the folder can hold the original note.
            if files.fileExists(atPath: target.path) { try? files.removeItem(at: dir) }
            throw error
        }
        try? files.removeItem(at: dir)
    }

    // MARK: - Done

    /// Adds the `done` tag. True only when the note now has it: after a
    /// checked write, or when it was already there. The slot note's edits
    /// are saved first, and its page is unlinked when the note is done.
    @discardableResult
    func markDone(_ path: String) -> Bool {
        let title = Self.noteTitle(path)
        let isSlot = path == slotPath
        if isSlot, !syncEdits() { return false }   // never close a note that lacks the page's edits
        guard let vault = vaultURL, vault.startAccessingSecurityScopedResource() else {
            lastError = "Could not open the vault. Choose the vault folder again."
            return false
        }
        defer { vault.stopAccessingSecurityScopedResource() }
        let url = URL(fileURLWithPath: path)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            lastError = "Could not read “\(title)”. It is not marked done."
            return false
        }
        guard let updated = Self.addingDoneTag(to: text) else {
            lastError = "Could not add the done tag to “\(title)”. Check its tags."
            return false
        }
        if updated != text {
            do {
                try Self.writeNote(updated, to: url)
            } catch {
                lastError = "Could not save “\(title)”: \(error.localizedDescription)"
                return false
            }
            guard let check = try? String(contentsOf: url, encoding: .utf8),
                  Self.tags(in: Self.frontmatter(of: check) ?? "").contains("done") else {
                lastError = "Could not confirm the done tag in “\(title)”."
                return false
            }
        }
        if isSlot { dropSlot() }
        items.removeAll { $0.id == path }
        if scanning { rescanPending = true }    // that scan read the note before the tag
        lastError = nil
        return true
    }

    // MARK: - Frontmatter helpers (kept dumb on purpose)
    //
    // Every helper finds the frontmatter with frontmatterBounds, so listing,
    // loading, write-back and Mark Done always agree on what it is.

    /// The note starts with `---`, and the frontmatter ends at the next line
    /// that starts with `---`. Returns the text between the two fences and
    /// the end of the closing `---`.
    static func frontmatterBounds(_ text: String) -> (inner: Range<String.Index>, close: String.Index)? {
        guard text.hasPrefix("---") else { return nil }
        let afterOpen = text.index(text.startIndex, offsetBy: 3)
        guard let end = text.range(of: "\n---", range: afterOpen..<text.endIndex) else { return nil }
        return (afterOpen..<end.lowerBound, end.upperBound)
    }

    static func frontmatter(of text: String) -> String? {
        frontmatterBounds(text).map { String(text[$0.inner]) }
    }

    /// Start of the first line at or after `start` that is not blank. Whole
    /// blank lines (only spaces or tabs, then a newline) are skipped, so the
    /// result is always at the start of a line.
    static func firstTextLine(in text: String, from start: String.Index) -> String.Index {
        var i = start
        while let newline = text[i...].firstIndex(of: "\n"),
              text[i..<newline].allSatisfy({ $0 == " " || $0 == "\t" }) {
            i = text.index(after: newline)
        }
        return i
    }

    /// Text as a note body: leading blank lines dropped (the note's own
    /// blank lines after its frontmatter belong to the head), indentation of
    /// the first line kept, trailing whitespace removed. Every comparison of
    /// page text with a note body uses this, so that
    /// splitFrontmatter(head + normalizedBody(s) + "\n").body == normalizedBody(s).
    static func normalizedBody(_ text: String) -> String {
        var body = text[firstTextLine(in: text, from: text.startIndex)...]
        while let last = body.last, last.isWhitespace { body.removeLast() }
        return String(body)
    }

    /// Splits a note into its head (the frontmatter through the closing `---`
    /// line, and any whole blank lines after it) and its body. The head
    /// always ends with a newline. Loading and write-back both use this, so
    /// they always agree on where the body starts.
    static func splitFrontmatter(_ text: String) -> (head: String, body: String)? {
        guard let bounds = frontmatterBounds(text) else { return nil }
        guard let newline = text[bounds.close...].firstIndex(of: "\n") else {
            return (text + "\n", "")      // the note ends at the closing `---`
        }
        let bodyStart = firstTextLine(in: text, from: text.index(after: newline))
        return (String(text[..<bodyStart]), normalizedBody(String(text[bodyStart...])))
    }

    static func stripFrontmatter(_ text: String) -> String {
        splitFrontmatter(text)?.body ?? normalizedBody(text)
    }

    /// True while the note has its frontmatter and its body is `synced`, as
    /// note bodies (trailing whitespace and leading blank lines do not
    /// count). Only then can a page be written over it.
    static func noteMatches(_ noteText: String, synced: String) -> Bool {
        splitFrontmatter(noteText)?.body == normalizedBody(synced)
    }

    static func tags(in fm: String) -> [String] {
        // tags: [a, b] form
        if let m = fm.range(of: #"(?m)^tags:\s*\[([^\]]*)\]"#, options: .regularExpression) {
            let inner = String(fm[m]).drop(while: { $0 != "[" }).dropFirst().dropLast()
            return inner.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
                  .trimmingCharacters(in: CharacterSet(charactersIn: "\"'")).lowercased()
            }
        }
        // tags:\n  - a  form
        guard let start = fm.range(of: #"(?m)^tags:\s*$"#, options: .regularExpression) else { return [] }
        var result: [String] = []
        for line in fm[start.upperBound...].components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("-") {
                result.append(t.dropFirst().trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'")).lowercased())
            } else if !t.isEmpty { break }
        }
        return result
    }

    static func completionPercent(in fm: String) -> Int? {
        guard let m = fm.range(of: #"(?mi)^completion %:[ \t]*(\d+)"#, options: .regularExpression) else { return nil }
        return Int(String(fm[m]).components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces) ?? "")
    }

    static func statusValue(in fm: String) -> String {
        guard let m = fm.range(of: #"(?m)^Status:[ \t]*(.+)$"#, options: .regularExpression) else { return "" }
        return String(fm[m]).replacingOccurrences(of: "Status:", with: "")
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    /// Adds `done` to the frontmatter tags, keeping the file's list style.
    /// Returns the text unchanged when `done` is already there, and nil when
    /// the tags cannot be found or the result fails its check.
    static func addingDoneTag(to text: String) -> String? {
        guard let bounds = frontmatterBounds(text) else { return nil }
        let fm = String(text[bounds.inner])
        if tags(in: fm).contains("done") { return text }
        var newFm: String?
        if let m = fm.range(of: #"(?m)^(tags:\s*\[[^\]]*)\]"#, options: .regularExpression) {
            // Inline list: tags: [a, b] -> tags: [a, b, done]
            newFm = fm.replacingCharacters(in: m, with: String(fm[m]).dropLast() + ", done]")
        } else if let start = fm.range(of: #"(?m)^tags:\s*$"#, options: .regularExpression) {
            // Block list: add "- done" after the last item. Blank lines are
            // skipped, as in tags(in:). `fm` stops before the closing `---`,
            // so that line can never count as an item.
            var lines = fm.components(separatedBy: "\n")
            let header = fm[..<start.lowerBound].components(separatedBy: "\n").count - 1
            var lastItem: Int?
            for i in (header + 1)..<lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t == "-" || t.hasPrefix("- ") || t.hasPrefix("-\t") { lastItem = i }
                else if !t.isEmpty { break }
            }
            if let last = lastItem {
                let indent = lines[last].prefix(while: { $0 == " " })
                lines.insert(indent + "- done", at: last + 1)
                newFm = lines.joined(separator: "\n")
            }
        }
        guard let newFm else { return nil }
        let result = text.replacingCharacters(in: bounds.inner, with: newFm)
        // Only the tags may change: the result must read as done, with the
        // same body.
        guard let check = frontmatter(of: result), tags(in: check).contains("done"),
              splitFrontmatter(result)?.body == splitFrontmatter(text)?.body
        else { return nil }
        return result
    }
}
