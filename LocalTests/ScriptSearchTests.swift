// extract: Textream/Textream/ScriptQueue.swift ScriptQueue titleMatches
// Tests for the Scripts list search (ScriptQueue.titleMatches).
import Foundation

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

if fails > 0 { print("\(fails) failed"); exit(1) }
