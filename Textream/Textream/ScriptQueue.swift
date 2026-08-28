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
                status: Self.status(in: fm), tags: tags))
        }
        // "Ready to record" first, then other statuses, then untagged.
        func rank(_ s: String) -> Int {
            if s.localizedCaseInsensitiveContains("ready") { return 0 }
            if s == "Next up" { return 1 }
            if s == "Scheduled" { return 3 }
            return 2
        }
        return .success(found.sorted {
            (rank($0.status), $0.title) < (rank($1.status), $1.title)
        })
    }

    // MARK: - Load into editor

    func load(_ item: QueueItem) {
        guard let vault = vaultURL, vault.startAccessingSecurityScopedResource() else { return }
        defer { vault.stopAccessingSecurityScopedResource() }
        guard let text = try? String(contentsOf: item.url, encoding: .utf8) else {
            lastError = "Could not read \(item.title)"
            return
        }
        let body = Self.stripFrontmatter(text)
        // Pages split on horizontal rules; fall back to the whole body.
        let pages = body
            .components(separatedBy: "\n---\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        // The current editor is stashed in the draft library, so no dialog.
        TextreamService.shared.replaceEditor(
            pages: pages.isEmpty ? [body] : pages, fileURL: nil)
        activePath = item.id
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
