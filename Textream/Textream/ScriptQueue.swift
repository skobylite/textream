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

struct QueueItem: Identifiable {
    let id: String        // file path
    let url: URL
    let title: String
    let status: String
    let tags: [String]
    let completion: Int?   // frontmatter "completion %"
}

@Observable
class ScriptQueue {
    static let shared = ScriptQueue()

    var items: [QueueItem] = []
    var vaultURL: URL?
    var lastError: String?
    /// Path of the note currently loaded in the editor, if any.
    var activePath: String?

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
            guard response == .OK, let url = panel.url else { return }
            do {
                let data = try url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil, relativeTo: nil)
                UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
                self?.vaultURL = url
                self?.rescan()
            } catch {
                self?.lastError = "Could not save vault access: \(error.localizedDescription)"
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

    func rescan() {
        guard let vault = vaultURL, !scanning else { return }
        scanning = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Self.scan(vault: vault)
            DispatchQueue.main.async {
                self?.scanning = false
                switch result {
                case .success(let items): self?.items = items; self?.lastError = nil
                case .failure(let e): self?.lastError = e.message
                }
            }
        }
    }

    private static func scan(vault: URL) -> Result<[QueueItem], ScanError> {
        guard vault.startAccessingSecurityScopedResource() else {
            return .failure(ScanError("Vault access denied — pick the folder again."))
        }
        defer { vault.stopAccessingSecurityScopedResource() }

        var found: [QueueItem] = []
        let keys: [URLResourceKey] = [.isRegularFileKey]
        let walker = FileManager.default.enumerator(
            at: vault, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles])
        while let file = walker?.nextObject() as? URL {
            guard file.pathExtension == "md" else { continue }
            guard let head = try? String(
                contentsOf: file, encoding: .utf8) else { continue }
            guard let fm = Self.frontmatter(of: head) else { continue }
            let tags = Self.tags(in: fm)
            guard tags.contains("script"), !tags.contains("done") else { continue }
            found.append(QueueItem(
                id: file.path, url: file,
                title: file.deletingPathExtension().lastPathComponent,
                status: Self.status(in: fm), tags: tags,
                completion: Self.completion(in: fm)))
        }
        // "Ready to record" first, then other statuses, then untagged.
        func rank(_ s: String) -> Int {
            if s.localizedCaseInsensitiveContains("ready") { return 0 }
            if s == "Next up" { return 1 }
            if s == "Scheduled" { return 3 }
            return 2
        }
        // Highest completion first; within a band, ready-to-record first.
        return .success(found.sorted {
            (-($0.completion ?? -1), rank($0.status), $0.title)
                < (-($1.completion ?? -1), rank($1.status), $1.title)
        })
    }

    // MARK: - Load into editor


    // MARK: - The vault slot
    //
    // Exactly one page can be a live view of a vault note. Browsing the queue
    // swaps that one slot; everything else in the page list is the user's own.
    // One slot means one (index, path) pair to keep honest — the previous
    // index-map design corrupted itself when indices drifted, mapping vault
    // paths onto unrelated pages.

    private static let slotKey = "vaultSlot"   // persisted as [path, body]

    private(set) var slotIndex: Int?
    private(set) var slotPath: String?
    private var slotSyncedBody: String?
    private var syncWork: DispatchWorkItem?

    var pageOrigins: [Int: String] {   // kept for the view layer's checks
        guard let i = slotIndex, let p = slotPath else { return [:] }
        return [i: p]
    }

    private func persistSlot() {
        let pages = TextreamService.shared.pages
        if let i = slotIndex, let p = slotPath, i < pages.count {
            UserDefaults.standard.set([p, pages[i]], forKey: Self.slotKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.slotKey)
        }
    }

    func restoreOrigins() {
        guard let saved = UserDefaults.standard.stringArray(forKey: Self.slotKey),
              saved.count == 2 else { return }
        let (path, body) = (saved[0], saved[1])
        // Reattach only on an exact content match; anything else is stale and
        // the page simply stays as ordinary user content.
        if let idx = TextreamService.shared.pages.firstIndex(of: body),
           FileManager.default.fileExists(atPath: path) {
            slotIndex = idx
            slotPath = path
            slotSyncedBody = body
            activePath = path
        } else {
            UserDefaults.standard.removeObject(forKey: Self.slotKey)
        }
    }

    /// The page list was replaced wholesale (file open, import, director):
    /// the slot's index no longer means anything. Flush, then drop it.
    func resetSlot() {
        syncEdits()
        slotIndex = nil; slotPath = nil; slotSyncedBody = nil; activePath = nil
        persistSlot()
    }

    func clearOrigin(at index: Int) {
        if slotIndex == index { slotIndex = nil; slotPath = nil; slotSyncedBody = nil; activePath = nil }
        persistSlot()
    }

    func load(_ item: QueueItem) {
        guard let vault = vaultURL, vault.startAccessingSecurityScopedResource() else { return }
        defer { vault.stopAccessingSecurityScopedResource() }
        guard let text = try? String(contentsOf: item.url, encoding: .utf8) else {
            lastError = "Could not read \(item.title)"
            return
        }
        let body = Self.stripFrontmatter(text)
        let service = TextreamService.shared

        if slotPath == item.id, let idx = slotIndex, idx < service.pages.count {
            service.currentPageIndex = idx        // already open
            return
        }
        syncEdits()                                // flush the outgoing script

        if let idx = slotIndex, idx < service.pages.count {
            service.pages[idx] = body              // swap the existing slot
            service.currentPageIndex = idx
            slotIndex = idx
        } else {
            let cur = service.currentPageIndex
            let curText = cur < service.pages.count ? service.pages[cur] : ""
            if curText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                service.pages[cur] = body
                slotIndex = cur
            } else {
                service.pages.append(body)
                service.currentPageIndex = service.pages.count - 1
                slotIndex = service.pages.count - 1
            }
        }
        slotPath = item.id
        slotSyncedBody = body
        activePath = item.id
        persistSlot()
    }

    /// Keep the slot index valid when a page is removed.
    func pageRemoved(at index: Int) {
        guard let i = slotIndex else { return }
        if i == index {
            slotIndex = nil; slotPath = nil; slotSyncedBody = nil; activePath = nil
        } else if i > index {
            slotIndex = i - 1
        }
        persistSlot()
    }

    /// Debounced write-back of slot edits into the note body.
    func scheduleSync() {
        syncWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.syncEdits() }
        syncWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    func syncEdits() {
        syncWork?.cancel()
        guard let vault = vaultURL, let idx = slotIndex, let path = slotPath else { return }
        let pages = TextreamService.shared.pages
        guard idx < pages.count else { return }
        let body = pages[idx]
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              body != slotSyncedBody else { return }
        guard vault.startAccessingSecurityScopedResource() else { return }
        defer { vault.stopAccessingSecurityScopedResource() }
        let url = URL(fileURLWithPath: path)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let out: String
        if let fmRange = text.range(of: #"(?s)\A---\n.*?\n---\n?"#, options: .regularExpression) {
            out = String(text[fmRange]) + body + "\n"
        } else {
            out = body + "\n"
        }
        do {
            try out.write(to: url, atomically: true, encoding: .utf8)
            slotSyncedBody = body
            persistSlot()
        } catch {
            lastError = "Could not write \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    // MARK: - Done

    func markDone(_ path: String) {
        guard let vault = vaultURL, vault.startAccessingSecurityScopedResource() else { return }
        defer { vault.stopAccessingSecurityScopedResource() }
        let url = URL(fileURLWithPath: path)
        guard var text = try? String(contentsOf: url, encoding: .utf8) else {
            lastError = "Could not read note to mark done"
            return
        }
        guard let updated = Self.addingDoneTag(to: text) else {
            lastError = "Could not update tags — is the frontmatter unusual?"
            return
        }
        text = updated
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            if activePath == path { activePath = nil }
            items.removeAll { $0.id == path }
        } catch {
            lastError = "Could not write note: \(error.localizedDescription)"
        }
    }

    // MARK: - Frontmatter helpers (kept dumb on purpose)

    static func frontmatter(of text: String) -> String? {
        guard text.hasPrefix("---") else { return nil }
        guard let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) else { return nil }
        return String(text[text.index(text.startIndex, offsetBy: 3)..<end.lowerBound])
    }

    static func stripFrontmatter(_ text: String) -> String {
        guard text.hasPrefix("---"),
              let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) else { return text }
        var rest = String(text[end.upperBound...])
        if let nl = rest.firstIndex(of: "\n") { rest = String(rest[rest.index(after: nl)...]) }
        return rest.trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Show only scripts with completion % >= 90.
    var highCompletionOnly: Bool = UserDefaults.standard.bool(forKey: "queueHighCompletionOnly") {
        didSet { UserDefaults.standard.set(highCompletionOnly, forKey: "queueHighCompletionOnly") }
    }

    var visibleItems: [QueueItem] {
        highCompletionOnly ? items.filter { ($0.completion ?? 0) >= 90 } : items
    }

    static func completion(in fm: String) -> Int? {
        guard let m = fm.range(of: #"(?mi)^completion %:\s*(\d+)"#, options: .regularExpression) else { return nil }
        return Int(String(fm[m]).components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces) ?? "")
    }

    static func status(in fm: String) -> String {
        guard let m = fm.range(of: #"(?m)^Status:\s*(.+)$"#, options: .regularExpression) else { return "" }
        return String(fm[m]).replacingOccurrences(of: "Status:", with: "")
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    /// Adds `done` to the frontmatter tags, preserving the file's existing
    /// list style. Returns nil when the tags cannot be located.
    static func addingDoneTag(to text: String) -> String? {
        guard let fmRange = text.range(of: #"(?s)\A---\n.*?\n---"#, options: .regularExpression) else { return nil }
        let fm = String(text[fmRange])
        if tags(in: fm).contains("done") { return text }
        // Inline list: tags: [a, b] -> tags: [a, b, done]
        if let m = fm.range(of: #"(?m)^(tags:\s*\[[^\]]*)\]"#, options: .regularExpression) {
            let replaced = fm.replacingCharacters(
                in: m, with: String(fm[m]).dropLast() + ", done]")
            return text.replacingCharacters(in: fmRange, with: replaced)
        }
        // Block list: append "  - done" after the last dash item.
        if let start = fm.range(of: #"(?m)^tags:\s*$"#, options: .regularExpression) {
            var lines = fm.components(separatedBy: "\n")
            let headerLineIdx = fm[..<start.lowerBound].components(separatedBy: "\n").count - 1
            var lastDash = headerLineIdx
            var i = headerLineIdx + 1
            while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("-") {
                lastDash = i; i += 1
            }
            guard lastDash > headerLineIdx else { return nil }
            let indent = lines[lastDash].prefix(while: { $0 == " " })
            lines.insert(indent + "- done", at: lastDash + 1)
            return text.replacingCharacters(in: fmRange, with: lines.joined(separator: "\n"))
        }
        return nil
    }
}
