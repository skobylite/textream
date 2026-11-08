// extract: Textream/Textream/SpeechRecognizer.swift SpeechRecognizer offScriptCheckWords offScriptMaxMisses offScriptBackWords offScriptAheadWords resumeRunWords resumeBackWords resumeNearWords resumeSlipHits resumeFarRunWords resumeFarChars resumeExactBelowLetters supportTailWords supportMinMatches supportBackChars supportAheadChars supportGap supportFarChars offScriptMisses offScriptWindow inOrderHits spokenFormMaxWords contractionEnds isSpokenForm joinSpokenForms inOrderLast dropLastWords offScriptResume supportEnd regressionSourceWords
// include: Textream/Textream/SpeechTextAlignment.swift
// Tests for the off-script (ad-lib) hold: the static check, pick-up and
// support functions of SpeechRecognizer. The end-to-end check is the speech
// simulator suite.
import Foundation

var fails = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  pass" : "  FAIL", name)
    if !ok { fails += 1 }
}
let eq: (String, String) -> Bool = { $0 == $1 }
/// A small stand-in for isFuzzyMatch: a prefix match for words of 3 or more
/// letters, or one changed letter in words of 4 or more letters.
let fuzzy: (String, String) -> Bool = { a, b in
    if a == b { return true }
    if min(a.count, b.count) >= 3 && (a.hasPrefix(b) || b.hasPrefix(a)) { return true }
    guard a.count == b.count, a.count >= 4 else { return false }
    return zip(a, b).filter { $0 != $1 }.count == 1
}
func clean(_ w: String) -> String { w.lowercased().filter { $0.isLetter || $0.isNumber } }
func said(_ s: String) -> [String] { s.split(separator: " ").map { clean(String($0)) }.filter { !$0.isEmpty } }
func endOf(_ phrase: String, in text: String, _ nth: Int = 0) -> Int {
    var from = text.startIndex
    for _ in 0..<nth { from = text.range(of: phrase, range: from..<text.endIndex)!.upperBound }
    return text.distance(from: text.startIndex, to: text.range(of: phrase, range: from..<text.endIndex)!.upperBound)
}
func startOf(_ phrase: String, in text: String, _ nth: Int = 0) -> Int { endOf(phrase, in: text, nth) - phrase.count }
typealias SR = SpeechRecognizer
func misses(_ source: String, held: Int, candidate: Int? = nil, _ words: String) -> Int {
    SR.offScriptMisses(spoken: said(words), window: SR.offScriptWindow(source: source, from: held, to: candidate ?? held), matches: fuzzy)
}
func offScript(_ source: String, held: Int, candidate: Int? = nil, _ words: String) -> Bool {
    misses(source, held: held, candidate: candidate, words) > SR.offScriptMaxMisses
}
func resume(_ source: String, held: Int, _ words: String) -> (start: Int, end: Int, words: Int)? {
    SR.offScriptResume(source: source, held: held, spoken: said(words), matches: fuzzy)
}

let launch = "Hi, I am Sarah from Propane and today I want to share how we grew our coaching business on Instagram. When we started, we had twelve followers and no clients at all. [smile] We tried paid ads first and we lost a lot of money. Then my business partner James had a simple idea. He said we should answer every single comment and every message within one hour."
let held = endOf("no clients at all.", in: launch) + 1   // the reader stopped after "all."

// The check: the newest 4 words against the script around the highlight.
check("script words fit", !offScript(launch, held: held, "had twelve followers and no clients at all"))
check("one misheard word still fits", !offScript(launch, held: held, "and no clients it all"))
check("an ad-lib does not fit", offScript(launch, held: held, "all sorry hang on the dog"))
check("fillers do not fit", offScript(launch, held: held, "um so you know okay"))
check("2 words since the anchor: both unknown is off script", offScript(launch, held: held, "sorry hang"))
check("1 script word since the anchor fits", !offScript(launch, held: held, "we"))
check("words read just past the highlight fit (candidate ahead)",
      !offScript(launch, held: held, candidate: endOf("We tried paid", in: launch) + 1, "all we tried paid"))
check("the check skips [smile]", SR.offScriptWindow(source: launch, from: held, to: held).contains("smile") == false)

// One script word said as several words (REPAIR r2: each extra word counted
// as a miss, so the highlight held for 3 words).
let intro = "Hi, I'm Sarah and today I'm going to show you what we've learned. We don't run ads and we're still booked. We use CRM tools and a step-by-step guide every day."
let atHi = startOf("Hi,", in: intro)
check("'I am' read for 'I'm' is not off script", !offScript(intro, held: atHi, "hi i am sarah"))
check("'do not' read for 'don't' is not off script",
      !offScript(intro, held: startOf("We don't", in: intro), "booked we do not"))
check("'we are' read for 'we're' is not off script",
      !offScript(intro, held: startOf("and we're", in: intro), "do not run ads and we are still"))
check("'c r m' read for 'CRM' is not off script",
      !offScript(intro, held: startOf("CRM", in: intro), "we use c r m tools"))
check("'c r m' cut by the newest-4 edge is not off script",
      !offScript(intro, held: startOf("tools and", in: intro), "c r m tools and"))
check("'c r' while the reader says 'CRM' is not off script",
      !offScript(intro, held: startOf("CRM", in: intro), "and we use c r"))
check("'step by step' read for 'step-by-step' is not off script",
      !offScript(intro, held: startOf("step-by-step", in: intro), "a step by step guide"))
check("an ad-lib after a contraction is still off script",
      offScript(intro, held: startOf("I'm Sarah", in: intro), "i am sorry hang on"))
check("isSpokenForm: 'do not' for 'dont'", SR.isSpokenForm("dont", ["do", "not"][...]))
check("isSpokenForm: 'we have' for 'weve'", SR.isSpokenForm("weve", ["we", "have"][...]))
check("isSpokenForm: 'we had' is not 'weve'", !SR.isSpokenForm("weve", ["we", "had"][...]))
check("isSpokenForm: one word is not a spoken form of a longer word", !SR.isSpokenForm("im", ["i"][...]))
check("joinSpokenForms joins 'i am' and 'c r m'",
      SR.joinSpokenForms(said("hi i am sarah we use c r m"), script: said("hi im sarah we use crm")) == said("hi im sarah we use crm"))
check("joinSpokenForms keeps words that say no script word",
      SR.joinSpokenForms(said("i am sorry"), script: said("hi sarah")) == said("i am sorry"))
check("joinSpokenForms joins a partial word only at the end with partialEnd",
      SR.joinSpokenForms(said("use c r"), script: said("use crm"), partialEnd: true) == said("use crm")
      && SR.joinSpokenForms(said("use c r"), script: said("use crm")) == said("use c r"))
let atSarah = startOf("Sarah and", in: intro)
check("support: 'hi i am sarah' moves on to 'Sarah'",
      SR.supportEnd(source: intro, spoken: said("hi i am sarah"), current: startOf("I'm Sarah", in: intro),
                    candidate: atSarah, matches: eq)?.end == endOf("Sarah", in: intro))

// Pick-up near the held place.
let same = resume(launch, held: held, "sorry where was I we tried paid")
check("same word: picks up after 'paid'", same?.end == endOf("We tried paid", in: launch) + 1)
check("same word: matching starts at 'We'", same?.start == startOf("We tried paid", in: launch))
check("same word: the run used 3 words", same?.words == 3)
check("2 script words are not enough", resume(launch, held: held, "okay where was I we tried") == nil)
check("skip of a few words picks up there",
      resume(launch, held: held, "okay so first and we lost")?.end == endOf("first and we lost", in: launch) + 1)
check("one misheard word in the return still picks up",
      resume(launch, held: held, "okay we tried pald ads")?.end == endOf("We tried paid ads", in: launch) + 1)
check("short words must match exactly: 'lost a lots' does not pick up at 'lost a lot'",
      resume(launch, held: held, "lost a lots") == nil)
check("ad-lib words do not pick up", resume(launch, held: held, "sorry hang on the dog is barking") == nil)
// The highlight ran past the reader before the hold started: the reader's
// run starts 3 words before the held place.
let overshot = endOf("We tried paid", in: launch) + 1
check("reader's run 3 words before the held place still picks up near",
      resume(launch, held: overshot, "okay we tried paid")?.end == endOf("We tried paid", in: launch) + 1)

// Pick-up further on (more than 12 words after the held place): 4 words in
// a row, found only once in the searched text.
let heldEarly = endOf("twelve followers", in: launch) + 1
check("next paragraph: 4 words pick up there",
      resume(launch, held: heldEarly, "anyway then my business partner")?.end == endOf("Then my business partner", in: launch) + 1)
check("next paragraph: 3 words are not enough", resume(launch, held: heldEarly, "anyway then my business") == nil)
let twice = "Welcome to the show, today is a good day and we have a lot to talk about together. First we talk about sleep and why it matters so much for you. Then we talk about food and why it matters so much for you. Then we wrap up."
let atStart = startOf("Welcome", in: twice)
check("a far run that is in the script twice does not pick up", resume(twice, held: atStart, "yes why it matters so") == nil)
check("a far run that is in the script once picks up",
      resume(twice, held: atStart, "talk about food and")?.end == endOf("talk about food and", in: twice) + 1)

// One misheard word at the page end.
let last = "It was one offer, one audience, one channel and ninety days of showing up. Thank you for reading, and I will see you in the next one."
check("slip at the page end: 'in the it one' picks up after 'one.'",
      resume(last, held: endOf("I will see you", in: last) + 1, "you in the it one")?.end == last.count + 1)

// Fewer than 3 words left on the page after the held place (REPAIR r1: the
// hold never released there, so the page never ended).
let thanks = "So this week, pick one platform and reply to every person. And that is all. Thank you."
let atThank = startOf("Thank you.", in: thanks)
check("2 words left: both said after an ad-lib pick up to the page end",
      resume(thanks, held: atThank, "and by the way I love this crowd thank you")?.end == thanks.count + 1)
check("2 words left: an ad-lib that ends in the last word does not pick up",
      resume(thanks, held: atThank, "I really want to tell you") == nil)
check("2 words left: 'thank' alone moves on to 'you', not to the page end",
      resume(thanks, held: atThank, "okay so thank")?.end == endOf("Thank", in: thanks) + 1)
let tell2 = "Try it this week. Then tell me what happened."
let atWhat = startOf("what happened.", in: tell2)
check("2 words left, first misheard ('wuat happened') picks up to the page end",
      resume(tell2, held: atWhat, "well I mean like wuat happened")?.end == tell2.count + 1)
check("2 words left: one short word alone does not pick up",
      resume(thanks, held: atThank, "okay so you") == nil)
let one = "So this week, pick one platform and reply to every person. Thanks."
check("1 word left: said after an ad-lib picks up to the page end",
      resume(one, held: startOf("Thanks.", in: one), "and by the way I love this crowd thanks")?.end == one.count + 1)
check("1 word left: ad-lib words do not pick up",
      resume(one, held: startOf("Thanks.", in: one), "and by the way I love this crowd") == nil)
let tell = "Try it this week. Then come back and tell me what happened."
let atMe = startOf("me what happened.", in: tell)
check("3 words left, short word misheard ('to' for 'me') picks up to the page end",
      resume(tell, held: atMe, "close the window to what happened")?.end == tell.count + 1)
check("3 words left, all heard picks up", resume(tell, held: atMe, "close the window me what happened")?.end == tell.count + 1)
check("3 words left: the first 2 heard pick up to after them, not to the page end",
      resume(tell, held: atMe, "close the window me what")?.end == endOf("me what", in: tell) + 1)
check("3 words left: only the last word heard does not pick up", resume(tell, held: atMe, "close the window happened") == nil)
check("a 2-word page after 2 ad-lib words picks up", resume("Thank you!", held: 0, "okay so thank you")?.end == 11)
check("not at the page end: 2 script words are still not enough",
      resume(launch, held: held, "okay where was I we tried") == nil)

// Support for forward moves.
let story = "Hi everyone. The thing is that I never planned to start a business. I was working a normal job and I was happy enough with it. Then one day my manager called me into his office and told me that the whole team was being let go at the end of the month."
let afterIt = endOf("happy enough with it.", in: story) + 1
let support = SR.supportEnd(source: story, spoken: said("enough with it then one"), current: afterIt, candidate: afterIt, matches: fuzzy)
check("script words just ahead are supported", support?.end == endOf("Then one", in: story))
check("all 3 newest words matched", support?.matches == 3)
check("ad-lib words have no support",
      SR.supportEnd(source: story, spoken: said("the dog is barking"), current: afterIt, candidate: afterIt, matches: fuzzy) == nil)
check("a far chance pair needs all 3 words ('getting cold that' is not 'told me that')",
      SR.supportEnd(source: story, spoken: said("getting cold that"), current: afterIt,
                    candidate: endOf("told me that", in: story), matches: fuzzy) == nil)
check("a misheard newest word lets the move go one word further",
      SR.supportEnd(source: story, spoken: said("with it thun"), current: afterIt, candidate: afterIt, matches: eq)?.end
      == endOf("it. Then", in: story))
check("support skips stage directions",
      SR.supportEnd(source: launch, spoken: said("at all we"), current: held, candidate: held, matches: eq)?.end
      == endOf("[smile] We", in: launch))

// Helpers.
check("inOrderHits counts the longest in-order match", SR.inOrderHits(said("a x b c"), said("a b c d"), matches: eq) == 3)
check("inOrderLast gives the last matched script word", SR.inOrderLast(said("in the it one"), said("in the next one"), matches: eq)?.last == 3)
check("dropLastWords drops whole words", SR.dropLastWords("so we tried paid", 2) == "so we ")
check("dropLastWords keeps the text when n is 0", SR.dropLastWords("so we", 0) == "so we")

if fails > 0 { print("\(fails) failed"); exit(1) }
