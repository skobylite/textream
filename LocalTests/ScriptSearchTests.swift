// extract: Textream/Textream/ScriptQueue.swift ScriptQueue titleMatches matches topMatch
// extract: Textream/Textream/ScriptQueue.swift Model QueueItem
// Tests for the Scripts list search: the match rule (titleMatches), the list
// rows (matches), the top result that opens by itself (topMatch), and a
// source check of that auto-open in ContentView.
import Foundation

// extract.py copies no imports, and it puts each copy in an enum. These make
// the types visible to the extracted code.
typealias URL = Foundation.URL
typealias QueueItem = Model.QueueItem

var fails = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  pass" : "  FAIL", name)
    if !ok { fails += 1 }
}
let m = ScriptQueue.titleMatches

check("empty search shows every note", m("A184 Morning hook", ""))
check("spaces only shows every note", m("A184 Morning hook", "   "))
check("case does not matter", m("A184 Morning hook", "morning"))
check("part of a word matches", m("A184 Morning hook", "morn"))
check("numbers match", m("A184 Morning hook", "184"))
check("all words must match, in any order", m("A184 Morning hook", "hook a184"))
check("a missing word hides the note", !m("A184 Morning hook", "hook evening"))
check("accents do not matter", m("Café opening", "cafe"))
check("no match hides the note", !m("A94 Sales call", "morning"))
check("capitals typed match a lower-case title", m("a184 morning hook", "MORNING"))
check("an accent typed matches a title without it", m("Cafe opening", "caf\u{E9}"))
check("an accent stored as a separate mark matches", m("Cafe\u{301} opening", "cafe"))
check("punctuation between words in the title does not matter", m("A184-Morning_hook", "morning hook"))
check("tabs, newlines and outer spaces only separate words", m("A184 Morning hook", "\thook\nmorning  "))
check("a typed apostrophe matches a curly one in the title", m("Why your offer doesn\u{2019}t sell", "doesn't"))
check("a curly apostrophe typed matches a straight one", m("Why your offer doesn't sell", "doesn\u{2019}t"))
check("an opening curly quote matches a straight one", m("The \u{2018}one thing\u{2019} hook", "'one"))

// The list rows and the top result.
func item(_ title: String) -> QueueItem {
    QueueItem(id: "/vault/\(title).md", url: URL(fileURLWithPath: "/vault/\(title).md"),
              title: title, status: "", completion: nil)
}
// The scan sorts by completion and status, so the list is not in title order.
let list = [item("A94 Sales call"), item("A184 Morning hook"), item("Morning"),
            item("Café opening"), item("Why your offer doesn\u{2019}t sell")]
func rows(_ query: String) -> [String] { ScriptQueue.matches(in: list, query: query).map(\.title) }
func top(_ query: String) -> String? { ScriptQueue.topMatch(in: list, query: query)?.title }

check("the list keeps its order and shows every match", rows("morning") == ["A184 Morning hook", "Morning"])
check("the top result is the first row, not the closest title", top("morning") == "A184 Morning hook")
check("an empty search shows every note in list order", rows("") == list.map(\.title))
check("spaces only show every note in list order", rows("   ") == list.map(\.title))
check("an empty search opens nothing", top("") == nil)
check("spaces only open nothing", top("   ") == nil)
check("tabs and newlines only open nothing", top("\t\n") == nil)
check("no match shows no rows", rows("evening").isEmpty)
check("no match opens nothing", top("evening") == nil)
check("an empty list opens nothing", ScriptQueue.topMatch(in: [], query: "morning") == nil)
check("the top result needs all words, in any order", top("hook a184") == "A184 Morning hook")
check("a word that no title has opens nothing", top("morning evening") == nil)
check("case and accents do not matter for the top result", top("CAFE") == "Café opening")
check("a typed apostrophe finds a curly one for the top result", top("doesn't") == "Why your offer doesn\u{2019}t sell")
check("outer spaces do not matter for the top result", top("  sales ") == "A94 Sales call")
// Fixed answers for searches with several rows: the top result is the first
// of them in list order.
check("'o' shows four rows in list order",
      rows("o") == ["A184 Morning hook", "Morning", "Café opening", "Why your offer doesn\u{2019}t sell"])
check("'o' opens the first of the four rows", top("o") == "A184 Morning hook")
check("'a' shows three rows in list order", rows("a") == ["A94 Sales call", "A184 Morning hook", "Café opening"])
check("'a' opens the first of the three rows", top("a") == "A94 Sales call")

// Source check of the auto-open in ContentView, and of ScriptQueue.load.
// The rules above are pure functions. A change to one of the lines below
// passes the type-check and every other suite, but opens a note at the
// wrong time: for example after Cmd-N, where the words typed for the new
// page then go into the vault note. So each line must match whole: a check
// that is negated or made to do nothing fails.
func code(of path: String) -> String {
    guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
        print("  FAIL cannot read \(path)"); exit(1)
    }
    // Code lines only: a comment that names a call does not count.
    return source.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        .joined(separator: "\n")
}
let view = code(of: "Textream/Textream/ContentView.swift")
let queueCode = code(of: "Textream/Textream/ScriptQueue.swift")
func count(_ s: String) -> Int { view.components(separatedBy: s).count - 1 }
/// The code lines from the first line that starts with `start` up to the
/// next line that starts with `end`, each without its comment and outer
/// spaces. Nil when one of them is not found.
func lines(from start: String, to end: String, in text: String = view) -> [String]? {
    let all = text.split(separator: "\n").map { line -> String in
        let kept = line.range(of: "//").map { line[..<$0.lowerBound] } ?? line[...]
        return kept.trimmingCharacters(in: .whitespaces)
    }.filter { !$0.isEmpty }
    guard let s = all.firstIndex(where: { $0.hasPrefix(start) }),
          let e = all[(s + 1)...].firstIndex(where: { $0.hasPrefix(end) }) else { return nil }
    return Array(all[s..<e])
}

// Only a change of the search text starts the pause. A .task(id:) would also
// run when the split view is built again (Director mode off) with old text.
check("a change of the search text starts the pause",
      lines(from: ".onChange(of: scriptQuery) { _, query in", to: ".onDisappear {")
        == [".onChange(of: scriptQuery) { _, query in", "openTopMatchAfterPause(for: query)", "}"])
check("nothing else starts the pause", count("openTopMatchAfterPause(") == 2)
check("no .task runs the pause", !view.contains(".task(id: scriptQuery)"))

// The auto-open, part by part. Each part must follow the one before it, so
// the note can open only at the end: after the pause and after every check.
if let fn = lines(from: "private func openTopMatchAfterPause(", to: "private var scriptSearchField") {
    let parts: [(String, [String])] = [
        ("each change of the text cancels the last pause, and a blank search (Esc, the clear button) starts none", [
            "private func openTopMatchAfterPause(for query: String) {",
            "topMatchTask?.cancel()",
            "guard query.contains(where: { !$0.isWhitespace }) else { return }",
            "let pages = service.pages",
            "let pageIndex = service.currentPageIndex",
            "topMatchTask = Task { @MainActor in",
        ]),
        ("the note opens only after a 0.25 s pause in the typing, and a cancel in the pause opens nothing", [
            "do {",
            "try await Task.sleep(nanoseconds: 250_000_000)",
            "} catch {",
            "return",
            "}",
        ]),
        ("nothing opens after a cancel, a cursor move, Cmd-Return, dictation, an open menu or a page change", [
            "guard !Task.isCancelled,",
            "isScriptSearchFocused,",
            "!isRunning,",
            "!isRecording,",
            "RunLoop.main.currentMode == .default,",
            "service.pages == pages, service.currentPageIndex == pageIndex",
            "else { return }",
        ]),
        ("the first row is found after the pause, and a shown note or a note not on this Mac is not loaded", [
            "let queue = ScriptQueue.shared",
            "guard let top = ScriptQueue.topMatch(in: queue.items, query: scriptQuery),",
            "queue.pageOrigins[service.currentPageIndex] != top.id,",
            "queue.isDownloaded(top)",
            "else { return }",
        ]),
        ("the note opens last, through loadScript as a click does, and the red message stays", [
            "loadScript(top, keepMessage: true)",
            "}",
            "}",
        ]),
    ]
    var at = 0
    for (name, part) in parts {
        check(name, Array(fn.dropFirst(at).prefix(part.count)) == part)
        at += part.count
    }
    check("the auto-open has no other step", fn.count == at)
} else {
    check("openTopMatchAfterPause found", false)
}

// Nothing else opens a note. A load at once on each keystroke, or a load
// when the list changes (a rescan, Mark Done), adds a call.
check("only a click and the auto-open call loadScript", count("loadScript(") == 3)
check("only loadScript calls ScriptQueue.load", count(".load(") == 1)
check("only the auto-open finds a top result", count("topMatch(") == 1)
check("a click on a row cancels the pause, and its load clears the red message",
      count("onLoad: { topMatchTask?.cancel(); loadScript($0) },") == 1)
if let click = lines(from: "private func loadScript(", to: "private func markScriptDone(") {
    check("loadScript clears the red message unless the auto-open asks to keep it",
          click.first == "private func loadScript(_ item: QueueItem, keepMessage: Bool = false) {"
          && click.contains("ScriptQueue.shared.load(item, keepMessage: keepMessage)"))
    // The 'already shown' test is in the auto-open only. A click on the
    // shown note still loads it, so a change made outside Textream shows.
    check("a click on the shown note still loads it", !click.contains { $0.contains("pageOrigins") })
} else {
    check("loadScript found", false)
}

// ScriptQueue.load clears the red message first, except for the auto-open.
// Each pause in one search can open a note, and a later open must not clear
// the warning of an earlier one ("This page is no longer linked to it")
// before the owner reads it.
if let load = lines(from: "func load(_ item: QueueItem", to: "func scheduleSync()", in: queueCode) {
    check("a load clears the red message unless it is asked to keep it",
          load.first == "func load(_ item: QueueItem, keepMessage: Bool = false) {"
          && load.filter { $0.contains("lastError = nil") } == ["if !keepMessage { lastError = nil }"])
    if let clear = load.firstIndex(of: "if !keepMessage { lastError = nil }"),
       let flush = load.firstIndex(of: "} else if !syncEdits() {") {
        check("the message is cleared before the flush, so the flush's message stays", clear < flush)
    } else {
        check("the clear and the flush found", false)
    }
} else {
    check("ScriptQueue.load found", false)
}

// A page move by the owner cancels the pause. On a blank page, Add Page and
// Cmd-N leave the same pages, so the page check does not see them. After
// Cmd-N puts the cursor in the editor, the focus state still shows the
// search field for one more update, and the note would go into the new page.
if let move = lines(from: "private func moveToPage(", to: "private static func leavingBlankPage(") {
    check("a page move by the owner cancels the pause", move.dropFirst().first == "topMatchTask?.cancel()")
} else {
    check("moveToPage found", false)
}
check("Add Page, the toolbar Page button and Cmd-N go through moveToPage",
      count("moveToPage(service.pages.count - 1)") == 3)
if let newPage = lines(from: ".onReceive(NotificationCenter.default.publisher(for: .newPage)) { _ in", to: ".onReceive("),
   let move = newPage.firstIndex(of: "moveToPage(service.pages.count - 1)"),
   let focus = newPage.firstIndex(of: "NotificationCenter.default.post(name: .focusEditor, object: nil)") {
    check("Cmd-N cancels the pause before it puts the cursor in the editor", move < focus)
} else {
    check("the Cmd-N page move and cursor move found", false)
}

if let gone = lines(from: ".onDisappear {", to: ".onAppear {") {
    check("the pause ends when the view goes", gone.contains("topMatchTask?.cancel()"))
} else {
    check("onDisappear found", false)
}
check("the list shows the rows that topMatch picks from",
      view.contains("let shown = ScriptQueue.matches(in: queue.items, query: query)"))

if fails > 0 { print("\(fails) failed"); exit(1) }
