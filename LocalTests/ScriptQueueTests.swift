// extract: Textream/Textream/ScriptQueue.swift ScriptQueue frontmatterBounds frontmatter firstTextLine normalizedBody splitFrontmatter stripFrontmatter noteMatches tags statusValue completionPercent addingDoneTag SlotChange followSlot onlyPage slotRecord relink relinkRefusedMessage noteTitle possibleDuplicate writeNote
// Regression tests for the Obsidian vault queue (ScriptQueue.swift).
import Foundation

// extract.py copies no imports. These make the Foundation types visible to
// the extracted code.
typealias CharacterSet = Foundation.CharacterSet
typealias Data = Foundation.Data
typealias Date = Foundation.Date
typealias FileManager = Foundation.FileManager
typealias NSString = Foundation.NSString
typealias URL = Foundation.URL

var fails = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  pass" : "  FAIL", name)
    if !ok { fails += 1 }
}
typealias Q = ScriptQueue
/// What syncEdits writes: the note's head, then the page as a note body.
func writeBack(_ note: String, _ page: String) -> String {
    Q.splitFrontmatter(note)!.head + Q.normalizedBody(page) + "\n"
}

// Frontmatter write-back
for (name, note) in [
    ("LF", "---\ntags: [ad, script]\ncompletion %: 95\n---\n\nHook line\n\nBody\n"),
    ("closing line with trailing space", "---\ntags: [script]\n--- \nHook line\n"),
] {
    let edited = Q.splitFrontmatter(note)!.body + " EDITED"
    let out = writeBack(note, edited)
    check("write-back keeps frontmatter and round-trips (\(name))",
          out.contains("tags:") && Q.splitFrontmatter(out)?.body == edited)
}
check("CRLF note is skipped, never written",
      Q.splitFrontmatter("---\r\ntags: [script]\r\n---\r\nHook\r\n") == nil)
check("blank line after frontmatter preserved",
      writeBack("---\ntags: [ad, script]\ncompletion %: 95\n---\n\nHook\n", "X")
        .hasPrefix("---\ntags: [ad, script]\ncompletion %: 95\n---\n\nX"))

// The head always ends with a newline (finding 4)
let stub = "---\ntags: [script]\n---"
check("note that ends at the closing fence: head gets a newline",
      Q.splitFrontmatter(stub)?.head == stub + "\n" && Q.splitFrontmatter(stub)?.body == "")
let stubOnce = writeBack(stub, "Hello world")
check("write-back after a bare closing fence keeps the fence on its own line",
      stubOnce == "---\ntags: [script]\n---\nHello world\n")
check("second write-back of that note gives the same file",
      writeBack(stubOnce, "Hello world") == stubOnce)
check("closing fence with a trailing space and no newline",
      writeBack("---\ntags: [script]\n--- ", "Hi") == "---\ntags: [script]\n--- \nHi\n")

// The first body line keeps its indentation (finding 19)
let indented = "---\ntags: [script]\n---\n\n    indented first line\nsecond line\n"
check("first-line indentation stays in the body",
      Q.splitFrontmatter(indented)?.head == "---\ntags: [script]\n---\n\n"
        && Q.splitFrontmatter(indented)?.body == "    indented first line\nsecond line")
check("unchanged indented note round-trips byte for byte",
      writeBack(indented, Q.splitFrontmatter(indented)!.body) == indented)
check("a new first line gets no old indentation",
      writeBack(indented, "New opening\n    indented first line\nsecond line")
        == "---\ntags: [script]\n---\n\nNew opening\n    indented first line\nsecond line\n")
check("blank lines with spaces or tabs after the fence stay in the head",
      Q.splitFrontmatter("---\na: b\n---\n  \n\t\nBody\n")?.head == "---\na: b\n---\n  \n\t\n")

// Write-back is stable and round-trips exactly
let note1 = "---\ntags: [script]\n---\n\nHook\n"
let w1 = writeBack(note1, "\nHook edited")
check("page that starts with a blank line: two write-backs give the same file",
      w1 == "---\ntags: [script]\n---\n\nHook edited\n" && writeBack(w1, "\nHook edited") == w1)
for page in ["Hook\n", "  Hook", "Hook  \n\n", "\n\nHook", "   \nHook", "Line 1\n\n  Line 2  "] {
    let out = writeBack(note1, page)
    check("split(head + body + newline) gives the body back (\(page.debugDescription))",
          Q.splitFrontmatter(out)?.body == Q.normalizedBody(page)
            && Q.splitFrontmatter(out)?.head == Q.splitFrontmatter(note1)?.head)
}
check("normalizedBody is stable", Q.normalizedBody(Q.normalizedBody(" \n\n  a \n b\t\n")) == Q.normalizedBody(" \n\n  a \n b\t\n"))

// Compare before every write (findings 0, 91)
let disk = "---\ntags: [script]\n---\n\nHook line\n\nBody\n"
let synced = Q.splitFrontmatter(disk)!.body
check("unchanged note matches", Q.noteMatches(disk, synced: synced))
check("a trailing newline difference still matches",
      Q.noteMatches(disk + "\n\n", synced: synced) && Q.noteMatches(disk, synced: synced + "\n"))
check("trailing spaces and a leading blank line on the page side still match",
      Q.noteMatches(disk, synced: "\n" + synced + "  "))
check("a paragraph added outside Textream does not match",
      !Q.noteMatches(disk + "\nNew paragraph from Obsidian\n", synced: synced))
check("an empty read does not match", !Q.noteMatches("", synced: synced))
check("a half-saved read does not match", !Q.noteMatches("---\ntags:\n  - scr", synced: synced))
check("a note without frontmatter does not match", !Q.noteMatches("Hook line\n\nBody\n", synced: synced))
check("first-line indentation counts",
      Q.noteMatches(indented, synced: "    indented first line\nsecond line")
        && !Q.noteMatches(indented, synced: "indented first line\nsecond line"))

// Mark Done (findings 2, 94)
func doneTagged(_ name: String, _ note: String) {
    let out = Q.addingDoneTag(to: note)
    let tagged = out.flatMap { Q.frontmatter(of: $0) }.map { Q.tags(in: $0).contains("done") } ?? false
    check("Mark Done adds the tag and keeps the body (\(name))",
          tagged && out.flatMap { Q.splitFrontmatter($0)?.body } == Q.splitFrontmatter(note)?.body)
}
doneTagged("tags block is the last property", "---\nStatus: Next up\ntags:\n  - script\n---\nBody line one\n")
doneTagged("tags is the only property", "---\ntags:\n  - script\n---\nBody\n")
doneTagged("inline [a, b] list", "---\ntags: [ad, script]\ncompletion %: 95\n---\n\nHook\n")
doneTagged("blank line inside the tags block", "---\ntags:\n\n  - script\n---\nBody\n")
doneTagged("tags block followed by another key", "---\ntags:\n  - script\n  - video\nStatus: Ready\n---\n\nBody\n")
doneTagged("opener with a trailing space", "--- \ntags: [script]\n---\nBody\n")
doneTagged("note ends at the closing fence", "---\nStatus: Ready\ntags:\n  - script\n---")
check("tags block last: exact result, done goes inside the frontmatter",
      Q.addingDoneTag(to: "---\nStatus: Next up\ntags:\n  - script\n---\nBody line one\n")
        == "---\nStatus: Next up\ntags:\n  - script\n  - done\n---\nBody line one\n")
check("inline list: exact result",
      Q.addingDoneTag(to: "---\ntags: [ad, script]\n---\nB\n") == "---\ntags: [ad, script, done]\n---\nB\n")
let doneNote = "---\ntags:\n  - script\n  - done\n---\nBody\n"
check("already done: text unchanged", Q.addingDoneTag(to: doneNote) == doneNote)
check("no tags: nothing to write", Q.addingDoneTag(to: "---\nStatus: x\n---\nBody\n") == nil)
check("no frontmatter: nothing to write", Q.addingDoneTag(to: "Body only\n") == nil)
for note in ["---\ntags: [script]\n---\nB\n", "--- \ntags: [script]\n---\nB\n", "---yaml\ntags: [script]\n---\nB\n",
             "---\ntags:\n\n  - script\n---\nB\n", "---\ntags:\n- script\n---\nB", "---\nStatus: x\ntags:\n  - script\n---"] {
    let listed = Q.frontmatter(of: note).map { Q.tags(in: $0).contains("script") } ?? false
    check("a listed note can be loaded and marked done (\(note.debugDescription))",
          listed && Q.splitFrontmatter(note) != nil && Q.addingDoneTag(to: note) != nil)
}

// Status and completion (finding 79)
check("empty Status does not take the next line",
      Q.statusValue(in: "\nStatus:\ncompletion %: 40\ntags:\n  - script\n") == ""
        && Q.statusValue(in: "\nStatus:\ntags:\n  - script\n") == "")
check("Status with only spaces is empty", Q.statusValue(in: "\nStatus:   \nx: y\n") == "")
check("Status value is read", Q.statusValue(in: "\nStatus: Ready to record\n") == "Ready to record")
check("quoted Status value is read", Q.statusValue(in: "\nStatus: \"Next up\"\n") == "Next up")
check("completion is read", Q.completionPercent(in: "\ncompletion %: 40\n") == 40)
check("empty completion is nil", Q.completionPercent(in: "\ncompletion %:\n12: x\n") == nil)

// Slot following
let A = "vault script", B = "my script"
check("edit to slot page tracked",
      Q.followSlot(index: 1, tracked: A, old: [B, A], new: [B, A + "!"]) == .edited(A + "!"))
check("page removed before slot -> moves",
      Q.followSlot(index: 1, tracked: A, old: [B, A], new: [A]) == .moved(0))
check("file replace -> slot lost",
      Q.followSlot(index: 1, tracked: A, old: [B, A], new: ["slide 1", "slide 2"]) == .lost)
let script1 = "Good morning and thank you for being here today"
check("single keystroke on only page -> edit",
      Q.followSlot(index: 0, tracked: script1, old: [script1], new: [script1 + "!"]) == .edited(script1 + "!"))
let dictated = "Good morning and thank you so much for being here today"
check("dictation insert mid-text -> edit",
      Q.followSlot(index: 0, tracked: script1, old: [script1], new: [dictated]) == .edited(dictated))
check("reorder followed",
      Q.followSlot(index: 0, tracked: A, old: [A, B], new: [B, A]) == .moved(1))
check("append elsewhere unchanged",
      Q.followSlot(index: 0, tracked: A, old: [A], new: [A, ""]) == .unchanged)

// Edits of any size stay linked (finding 5). The old rule "the only page
// replaced by another text -> lost" is gone: every wholesale replacement
// resets the slot first, so an in-place change of the slot page is an edit.
let long = String(repeating: "word ", count: 200)
let trimmed = String(long.prefix(400))
check("cutting 60% of the slot page is an edit",
      Q.followSlot(index: 0, tracked: long, old: [long], new: [trimmed]) == .edited(trimmed))
check("select-all and paste on the slot page is an edit",
      Q.followSlot(index: 1, tracked: A, old: [B, A], new: [B, "a new version"]) == .edited("a new version"))
check("the only page changed in place is an edit",
      Q.followSlot(index: 0, tracked: A, old: [A], new: [B]) == .edited(B))

// A blank slot never moves onto another blank page (finding 9). A page added
// at the end leaves the slot on its own page (these three were .lost before
// position decided); when the removed page could be the slot page, it is lost.
check("blank slot: Cmd-N append keeps the slot on its own page",
      Q.followSlot(index: 1, tracked: "", old: ["Script A", ""], new: ["Script A", "", ""]) == .unchanged)
check("blank slot: then the cleanup removes it, or a blank copy: detaches",
      Q.followSlot(index: 1, tracked: "", old: ["Script A", "", ""], new: ["Script A", ""]) == .lost)
check("blank only page: Cmd-N keeps the slot on page 1",
      Q.followSlot(index: 0, tracked: "", old: [""], new: ["", ""]) == .unchanged)
check("whitespace-only slot: Cmd-N keeps the slot on its own page",
      Q.followSlot(index: 0, tracked: " \n", old: [" \n"], new: [" \n", ""]) == .unchanged)
check("whitespace-only slot counts as blank when its page could be the one removed",
      Q.followSlot(index: 0, tracked: " \n", old: [" \n", " \n"], new: [" \n"]) == .lost)
check("blank slot: a page before it removed -> moved",
      Q.followSlot(index: 2, tracked: "", old: ["Script A", "Script B", ""], new: ["Script B", ""]) == .moved(1))
check("typing into a blank slot is an edit",
      Q.followSlot(index: 1, tracked: "", old: ["Script A", ""], new: ["Script A", "H"]) == .edited("H"))

// Two identical pages (finding 17). Position decides when the removed page is
// certain (the two "moved" checks were .lost before); text cannot tell copies apart.
let S = "same script"
check("slot page deleted, a copy remains -> lost",
      Q.followSlot(index: 0, tracked: S, old: [S, S], new: [S]) == .lost)
check("page before the slot removed, a copy after it -> moved",
      Q.followSlot(index: 1, tracked: S, old: ["A", S, S], new: [S, S]) == .moved(0))
check("same, with the slot on the second copy -> moved",
      Q.followSlot(index: 2, tracked: S, old: ["A", S, S], new: [S, S]) == .moved(1))
check("slot page or its copy removed: cannot tell -> lost",
      Q.followSlot(index: 1, tracked: S, old: ["A", S, S], new: ["A", S]) == .lost)
check("unique slot text, page before removed -> moved",
      Q.followSlot(index: 1, tracked: S, old: ["A", S, "B"], new: [S, "B"]) == .moved(0))
check("pasting a copy into another page leaves the slot alone",
      Q.followSlot(index: 0, tracked: S, old: [S, ""], new: [S, S]) == .unchanged)
check("a copy elsewhere: Add Page keeps the slot",
      Q.followSlot(index: 1, tracked: S, old: [S, S], new: [S, S, ""]) == .unchanged)
check("a copy elsewhere: Add Page after a page between them",
      Q.followSlot(index: 2, tracked: S, old: [S, "x", S], new: [S, "x", S, ""]) == .unchanged)
check("a copy elsewhere: the blank page after the slot removed",
      Q.followSlot(index: 1, tracked: S, old: [S, S, ""], new: [S, S]) == .unchanged)
check("a copy elsewhere: a page before the copy and the slot removed",
      Q.followSlot(index: 3, tracked: S, old: ["x", S, "y", S], new: [S, "y", S]) == .moved(2))
check("a page that is not added at the end is not taken as an append",
      Q.followSlot(index: 1, tracked: S, old: [S, S], new: ["new", S, S]) == .lost)
check("slot text out of step with its page: only text can decide",
      Q.followSlot(index: 0, tracked: S, old: ["other"], new: ["other", ""]) == .lost)

// load() attaches to a page that already holds the note (finding 17)
check("note already on one page is found",
      Q.onlyPage(withBody: "Hook\n\nBody", in: ["x", "Hook\n\nBody\n", ""]) == 1)
check("note on two pages is not attached", Q.onlyPage(withBody: "S", in: ["S", "S\n"]) == nil)
check("note on no page", Q.onlyPage(withBody: "S", in: ["x", ""]) == nil)

// Saved slot (finding 62)
let rec = Q.slotRecord(["/v/a.md", "Hook edited\n", "Hook\n\n"])
check("slot record keeps page text and synced body apart",
      rec?.path == "/v/a.md" && rec?.pageText == "Hook edited\n" && rec?.synced == "Hook")
// An older build also saved page edits that were not written yet (on a slot
// move), so an older record's body is page text, not a known synced body.
let old = Q.slotRecord(["/v/a.md", "Hook\n"])
check("older [path, body] record: no synced body",
      old?.pageText == "Hook\n" && old?.synced == nil)
check("unknown record is ignored", Q.slotRecord(["/v/a.md"]) == nil)

// Launch relink (findings 0, 62)
let v1 = "---\ntags:\n  - script\n---\n\nHook A v1\n"
let v2 = "---\ntags:\n  - script\n---\n\nHook A v2 from Obsidian\n"
let pending = Q.relink(pageText: "Hook A v1 plus edits", synced: "Hook A v1", note: v1)
check("note unchanged: linked, the page's unsaved edits stay pending",
      pending?.synced == "Hook A v1" && pending != nil && pending?.page == nil)
let refreshed = Q.relink(pageText: "Hook A v1\n", synced: "Hook A v1", note: v2)
check("note changed, page with no unsaved edits: linked, the page gets the note's text",
      refreshed?.synced == "Hook A v2 from Obsidian" && refreshed?.page == "Hook A v2 from Obsidian")
check("note changed, page with unsaved edits: not linked",
      Q.relink(pageText: "Hook A v1 plus edits", synced: "Hook A v1", note: v2) == nil)
check("note without frontmatter, or an empty read: not linked",
      Q.relink(pageText: "Hook A v1", synced: "Hook A v1", note: "Hook A v1\n") == nil
        && Q.relink(pageText: "Hook A v1", synced: "Hook A v1", note: "") == nil)
let oldMatch = Q.relink(pageText: "Hook A v1\n", synced: nil, note: v1)
check("older record that the note still matches: linked",
      oldMatch?.synced == "Hook A v1" && oldMatch != nil && oldMatch?.page == nil)
check("older record with edits the note does not have: not linked, the page keeps them",
      Q.relink(pageText: "Hook A v1 plus edits", synced: nil, note: v1) == nil)
check("older record and a changed note: not linked (the page can have unsaved edits)",
      Q.relink(pageText: "Hook A v1", synced: nil, note: v2) == nil)
check("refused older record: the message does not say that the note changed",
      !Q.relinkRefusedMessage("A", olderRecord: true).contains("changed")
        && Q.relinkRefusedMessage("A", olderRecord: true).contains("no longer linked"))
check("refused current record: the message says that the note changed",
      Q.relinkRefusedMessage("A", olderRecord: false).contains("changed while Textream was closed"))

// Possible iCloud copies (finding 92)
let t0 = Date(timeIntervalSince1970: 1_700_000_000)
let created: [String: Date] = [
    "/v/X.md": t0, "/v/X 2.md": t0.addingTimeInterval(1),
    "/v/Untitled.md": t0, "/v/Untitled 2.md": t0.addingTimeInterval(86_400),
    "/v/Burned by mentors -2.md": t0, "/v/Burned by mentors -2 2.md": t0,
    "/v/sub/X 2.md": t0, "/v/Top 10.md": t0,
]
check("same creation time: possible duplicate", Q.possibleDuplicate(of: "/v/X 2.md", created: created) == "X")
check("numbered note made on another day is not marked",
      Q.possibleDuplicate(of: "/v/Untitled 2.md", created: created) == nil)
check("base name that ends in a number",
      Q.possibleDuplicate(of: "/v/Burned by mentors -2 2.md", created: created) == "Burned by mentors -2")
check("the base must be in the same folder", Q.possibleDuplicate(of: "/v/sub/X 2.md", created: created) == nil)
check("no base note: not marked", Q.possibleDuplicate(of: "/v/Top 10.md", created: created) == nil)
check("the base note itself is not marked", Q.possibleDuplicate(of: "/v/X.md", created: created) == nil)

// Write-back keeps the note's creation date, Finder tags and xattrs, and
// writes through a symlink (finding 13)
let files = FileManager.default
let dir = files.temporaryDirectory.appendingPathComponent("textream-writenote-\(getpid())")
try? files.removeItem(at: dir)
try! files.createDirectory(at: dir, withIntermediateDirectories: true)
let note = dir.appendingPathComponent("note.md"), link = dir.appendingPathComponent("link.md")
try! Data("---\ntags: [script]\n---\nOld body\n".utf8).write(to: note)
let born = Date(timeIntervalSince1970: 1_577_836_800)   // 1 Jan 2020
try! files.setAttributes([.creationDate: born, .modificationDate: born], ofItemAtPath: note.path)
let tagNames = ["com.apple.metadata:_kMDItemUserTags", "com.example.custom"]
for name in tagNames { _ = "x".withCString { setxattr(note.path, name, $0, 1, 0, 0) } }
try! files.createSymbolicLink(at: link, withDestinationURL: note)
let newText = "---\ntags: [script]\n---\nNew body\n"
do {
    try Q.writeNote(newText, to: link)
    let attrs = try files.attributesOfItem(atPath: note.path)
    check("write-back changes the text", try String(contentsOf: note, encoding: .utf8) == newText)
    check("write-back keeps the creation date", attrs[.creationDate] as? Date == born)
    check("write-back keeps Finder tags and other xattrs",
          tagNames.allSatisfy { getxattr(note.path, $0, nil, 0, 0, 0) >= 0 })
    check("write-back through a symlink keeps the symlink",
          (try? files.destinationOfSymbolicLink(atPath: link.path)) != nil)
} catch {
    check("write-back works (\(error))", false)
}
try? files.removeItem(at: dir)

if fails > 0 { print("\(fails) failed"); exit(1) }
