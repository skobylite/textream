// extract: Textream/Textream/ContentView.swift ContentView leavingBlankPage
// extract: Textream/Textream/TextreamService.swift TextreamService draftState userPages
// extract: Textream/Textream/HighlightingTextEditor.swift HighlightingTextEditor replaceText
// Regression tests for the main window around the vault queue: the blank-page
// cleanup, the draft restore at launch, Save during a Director session and the
// editor's undo.
import AppKit

// extract.py copies no imports. This makes NSTextView visible to the extracted code.
typealias NSTextView = AppKit.NSTextView

var fails = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  pass" : "  FAIL", name)
    if !ok { fails += 1 }
}

// A blank page is removed only when the user moves off it (findings 23, 82).
// run(), file open, import, Director and removePage set the index directly,
// so they can never remove a page.
func move(_ pages: [String], from old: Int, to target: Int) -> ([String], Int) {
    var pages = pages
    let step = ContentView.leavingBlankPage(pages, from: old, to: target)
    if let blank = step.remove { pages.remove(at: blank) }
    return (pages, step.target)
}
check("a blank page that is left is removed (target after it)",
      move(["A", "", "B"], from: 1, to: 2) == (["A", "B"], 1))
check("a blank page that is left is removed (target before it)",
      move(["A", "", "B"], from: 1, to: 0) == (["A", "B"], 0))
check("a page with only spaces and newlines counts as blank",
      move([" \n", "A"], from: 0, to: 1) == (["A"], 0))
check("a page with text stays", move(["A", "B"], from: 0, to: 1) == (["A", "B"], 1))
check("the only page stays", move([""], from: 0, to: 0) == ([""], 0))
check("of two blank pages one stays", move(["", ""], from: 0, to: 1) == ([""], 0))
check("Add Page on a blank page: the blank page moves to the end",
      move(["A", "", "B", ""], from: 1, to: 3) == (["A", "B", ""], 2))
check("Add Page on a page with text adds a page",
      move(["A", ""], from: 0, to: 1) == (["A", ""], 1))
check("an index that is not in the list removes nothing",
      move(["X", "Y"], from: 5, to: 0) == (["X", "Y"], 0))

// The draft comes back without its blank pages (findings 18, 64, 80)
func draft(_ stored: [String]?, _ index: Int, file: Bool = false) -> (pages: [String], index: Int)? {
    TextreamService.draftState(stored: stored, index: index, keepBlankPages: file)
}
check("first launch: no draft, so the sample script shows", draft(nil, 0) == nil)
let emptied = draft([""], 0)
check("an emptied workspace comes back as one blank page, not the sample",
      emptied?.pages == [""] && emptied?.index == 0)
let none = draft([], 3)
check("an empty list comes back as one blank page", none?.pages == [""] && none?.index == 0)
let allBlank = draft(["", " \n"], 1)
check("only blank pages: one blank page stays", allBlank?.pages == [""] && allBlank?.index == 0)
let saved = ["Questions?", "Intro", "Questions?", "", "Outro"]
let restored = draft(saved, 4)
check("copies are kept, the blank page is dropped", restored?.pages == ["Questions?", "Intro", "Questions?", "Outro"])
check("the same page stays selected after a blank page before it is dropped", restored?.index == 3)
let fileDraft = draft(saved, 4, file: true)
check("a draft of a file keeps its blank pages, as the file has them",
      fileDraft?.pages == saved && fileDraft?.index == 4)
check("selected page after a dropped blank page (finding 64)",
      draft(["", "A", "B", "C"], 2).map { $0.pages[$0.index] } == "B")
check("selected blank page: the nearest page before it",
      draft(["A", "", "B"], 1).map { $0.pages[$0.index] } == "A")
check("selected blank first page: the first page that stays",
      draft(["", "A", "B"], 0).map { $0.pages[$0.index] } == "A")
check("an index past the end selects the last page", draft(["A", "B"], 7)?.index == 1)
check("a negative index selects the first page", draft(["A", "B"], -2)?.index == 0)

// During a Director session its text fills the pages and the user's pages are
// held. Save writes the held pages and the unsaved-changes check compares them
// (round-3 review). Before, Cmd-S wrote the Director text into the open file.
let fileA = ["A page 1", "A page 2"]
let directorText = ["Director script"]
func toSave(_ pages: [String], held: [String]?) -> [String] { TextreamService.userPages(pages, held: held) }
check("no session: Save writes the editor's pages", toSave(fileA, held: nil) == fileA)
check("session: Save writes the held pages, not the Director text",
      toSave(directorText, held: fileA) == fileA)
// hasUnsavedChanges is `userPages != savedPages`.
func unsaved(_ pages: [String], held: [String]?, saved: [String]) -> Bool { toSave(pages, held: held) != saved }
check("session on a file with no changes: nothing is unsaved (Cmd-O does not ask)",
      !unsaved(directorText, held: fileA, saved: fileA))
check("session after an edit to the file: the edit still shows as unsaved",
      unsaved(directorText, held: ["A page 1 edited", "A page 2"], saved: fileA))
// Cmd-S during the session, then the session ends: the held pages come back
// and match the saved pages, so "Don't Save" on close keeps the user's text.
let savedAfterCmdS = toSave(directorText, held: fileA)
check("after the session ends the pages match what Cmd-S saved",
      toSave(fileA, held: nil) == savedAfterCmdS)
// The orange unsaved dot in the toolbar uses the same check. Before, it
// compared the Director text with the file and showed during every session.
let contentSource = (try? String(contentsOfFile: "Textream/Textream/ContentView.swift", encoding: .utf8)) ?? ""
check("the toolbar's unsaved dot uses hasUnsavedChanges",
      contentSource.contains("service.currentFileURL != nil && service.hasUnsavedChanges")
      && !contentSource.contains("service.pages != service.savedPages"))

// Text set by the app removes the undo steps of the old text (finding 6).
// Without this, Cmd-Z replays old typing at old positions in a vault note.
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                      styleMask: [.titled], backing: .buffered, defer: false)
let textView = NSTextView(frame: window.contentView!.bounds)
textView.allowsUndo = true
textView.isRichText = false
window.contentView!.addSubview(textView)
window.makeFirstResponder(textView)
func type(_ text: String) {
    for ch in text { textView.insertText(String(ch), replacementRange: textView.selectedRange()) }
}
func spin() { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }

textView.string = "Scratch page."
textView.setSelectedRange(NSRange(location: 13, length: 0))
type(" Typed words")
check("typing can be undone (test setup)", textView.undoManager?.canUndo == true)
let note = "Vault note body: the quick brown fox jumps over the lazy dog."
HighlightingTextEditor.replaceText(of: textView, with: note)
check("the new text shows", textView.string == note)
check("the undo steps of the old text are gone", textView.undoManager?.canUndo == false)
textView.undoManager?.undo()
spin()
check("Cmd-Z does not change the new text", textView.string == note)
textView.setSelectedRange(NSRange(location: (note as NSString).length, length: 0))
type(" New words")
spin()
textView.undoManager?.undo()
spin()
check("typing after it can still be undone", textView.string == note)

if fails > 0 { print("\(fails) failed"); exit(1) }
