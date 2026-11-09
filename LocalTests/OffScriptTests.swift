// extract: Textream/Textream/SpeechRecognizer.swift SpeechRecognizer offScriptCheckWords offScriptMaxMisses offScriptBackWords offScriptAheadWords resumeRunWords resumeBackWords resumeNearWords resumeSlipHits resumeFarRunWords resumeFarChars resumeExactBelowLetters supportTailWords supportMinMatches supportBackChars supportAheadChars supportGap supportFarChars offScriptMisses offScriptWindow inOrderHits spokenFormMaxWords contractionEnds isSpokenForm joinSpokenForms inOrderLast dropLastWords offScriptResume supportEnd regressionSourceWords numberUnits numberValues numberTens hasDigit numberValue numberStart isNumberWord numberMatch rangeDigits soundAlikeMinLetters soundAlikeLetterSlack soundAlikeOwnLetters nearScriptWords alignSpoken spokenExpansions scaleLetters hasRun spokenNumberForms rangeScaled
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

// A name or brand heard as 2 or 3 other words, a short form read in full, and
// a number in digits for a number in words (r3: each extra word counted as a
// miss, so the highlight held for 3 to 8 words).
let brands = "We built the whole thing on Shopify and Kajabi and my partner Siobhan ran the launch from her kitchen table in Dublin."
check("'shop if i' heard for 'Shopify' is not off script",
      !offScript(brands, held: startOf("Shopify", in: brands), "we built the whole thing on shop if i"))
check("'car jabby' heard for 'Kajabi' is not off script",
      !offScript(brands, held: startOf("Kajabi", in: brands), "on shopify and car jabby and my"))
check("'she von' heard for 'Siobhan' is not off script",
      !offScript(brands, held: startOf("Siobhan", in: brands), "and my partner she von ran the"))
check("an ad-lib before a brand is still off script",
      offScript(brands, held: startOf("Shopify", in: brands), "the whole thing on honestly we tried"))
check("support: 'and car jabby and my' moves on to 'my'",
      SR.supportEnd(source: brands, spoken: said("and car jabby and my"), current: startOf("Kajabi", in: brands),
                    candidate: startOf("Kajabi", in: brands), matches: eq)?.matches == 3)
check("alignSpoken puts the script word in for a group with a hit after it",
      SR.alignSpoken(said("on shop if i and"), said("on shopify and kajabi"), countFrom: 0, matches: eq).words
      == said("on shopify and"))
check("alignSpoken: a group of words that are script words is not a name",
      SR.alignSpoken(said("on and kajabi and"), said("on shopify and kajabi"), countFrom: 0, matches: eq).words
      == said("on and kajabi and"))
let shortForms = "Pick one channel, i.e. the one your clients use most, and post there daily: reels, stories, carousels, etc. Then compare reach vs. sales."
check("'that is' read for 'i.e.' is not off script",
      !offScript(shortForms, held: startOf("i.e.", in: shortForms), "pick one channel that is the one"))
check("'et cetera' read for 'etc.' is not off script",
      !offScript(shortForms, held: startOf("etc.", in: shortForms), "stories carousels et cetera then compare"))
let example = "Pick one thing, e.g. a weekly live, and do it for ninety days."
check("'for example' read for 'e.g.' is not off script",
      !offScript(example, held: startOf("e.g.", in: example), "pick one thing for example a weekly"))
check("isSpokenForm: 'versus' for 'vs'", SR.isSpokenForm("vs", ["versus"][...]))
check("isSpokenForm: 'q and a' for 'qa'", SR.isSpokenForm("qa", ["q", "and", "a"][...]))
let rates = "Our close rate went from ten percent to forty percent in six weeks once we started replying within one hour."
check("'10% to 40%' heard for 'ten percent to forty percent' is not off script",
      !offScript(rates, held: startOf("forty", in: rates), "rate went from 10% to 40%"))
check("'40% in 6' heard for 'forty percent in six' is not off script",
      !offScript(rates, held: startOf("six", in: rates), "from 10% to 40% in 6"))
check("an ad-lib with another number is still off script",
      offScript(rates, held: startOf("ten", in: rates), "went from 12 clients signed"))
check("support: 'to 40% in 6' moves on to 'six'",
      SR.supportEnd(source: rates, spoken: said("to 40% in 6"), current: startOf("forty", in: rates),
                    candidate: startOf("forty", in: rates), matches: eq)?.end == endOf("six", in: rates))
let digits = "We had 3 calls booked at 10 and 40% of them closed in 6 weeks, which made $2,500 in our first month."
check("number words read for digits are not off script",
      !offScript(digits, held: startOf("40%", in: digits), "booked at ten and forty percent of them")
      && !offScript(digits, held: startOf("$2,500", in: digits), "which made two thousand five hundred dollars in our"))
check("joinSpokenForms joins a number said in words into the script number",
      SR.joinSpokenForms(said("made two thousand five hundred dollars in"), script: said("made $2,500 in")) == said("made 2500 in"))
check("numberMatch: digits that start with the word's value",
      SR.numberMatch("forty", "40") && SR.numberMatch("3", "three") && SR.numberMatch("twenty", "2024")
      && SR.numberMatch("twentyfour", "24") && SR.numberMatch("third", "3rd"))
check("numberMatch: other numbers and words do not match",
      !SR.numberMatch("ten", "12") && !SR.numberMatch("ten", "twelve") && !SR.numberMatch("ten", "then"))
// Compound numbers without a hyphen, "and" inside a number, times and ranges
// (r3 repair: "25" did not fit "twenty", the number run stopped at "and", and
// "3 to 5" was 3 words for the script word "3-5", so the highlight held).
let compound = "Our close rate went from twenty five to seventy five percent in forty five days, and our churn fell."
check("'25 to 75% in 45' heard for 'twenty five to seventy five percent in forty five' is not off script",
      !offScript(compound, held: startOf("seventy", in: compound), "went from 25 to 75%")
      && !offScript(compound, held: startOf("forty", in: compound), "25 to 75% in 45"))
check("numberMatch: a tens word fits a 2-digit number with its tens digit",
      SR.numberMatch("twenty", "25") && SR.numberMatch("45", "forty") && !SR.numberMatch("twenty", "35")
      && !SR.numberMatch("twenty", "2"))
let session = "Book your call at 9am or 2:30pm on the 21st, and the session runs 45 minutes with a short break."
check("'nine am or two thirty pm on the twenty first' read for '9am or 2:30pm on the 21st' is not off script",
      !offScript(session, held: startOf("2:30pm", in: session), "at nine am or two thirty pm")
      && !offScript(session, held: startOf("21st", in: session), "pm on the twenty first and"))
check("joinSpokenForms joins 'twenty first' into '21st', not into the earlier '2:30pm'",
      SR.joinSpokenForms(said("at two thirty pm on the twenty first and"), script: said("at 2:30pm on the 21st and"))
      == said("at 230pm on the 21st and"))
check("'forty five' read for '45' is not off script",
      !offScript(session, held: startOf("45", in: session), "the session runs forty five minutes"))
let price = "It costs $497 a month, which is less than an agency."
check("joinSpokenForms joins a number with 'and' in it ('four hundred and ninety seven dollars')",
      SR.joinSpokenForms(said("costs four hundred and ninety seven dollars a"), script: said("costs $497 a"))
      == said("costs 497 a"))
check("'four hundred and ninety seven dollars' read for '$497' is not off script",
      !offScript(price, held: startOf("$497", in: price), "costs four hundred and ninety seven dollars a"))
let ranges = "Post 3-5 times a week for 6-8 days and you should see 2-3 new leads a day."
check("'3 to 5' and 'six to eight' heard for '3-5' and '6-8' are not off script",
      !offScript(ranges, held: startOf("3-5", in: ranges), "post 3 to 5 times a")
      && !offScript(ranges, held: startOf("6-8", in: ranges), "a week for six to eight days"))
check("the start of a range ('for 6 to') is not off script",
      !offScript(ranges, held: startOf("6-8", in: ranges), "a week for 6 to"))
check("an ad-lib with another range is still off script",
      offScript(ranges, held: startOf("3-5", in: ranges), "we did 7 to 9 posts daily"))
check("support: 'week for 6 to 8' moves on to '6-8'",
      SR.supportEnd(source: ranges, spoken: said("week for 6 to 8"), current: startOf("for 6-8", in: ranges),
                    candidate: startOf("for 6-8", in: ranges), matches: eq)?.end == endOf("6-8", in: ranges))
// Words read as written are not joined into a compound (r3: "every day" was
// joined into "everyday", so support ended on the wrong word).
check("joinSpokenForms keeps 'every day' when the script has it as 2 words",
      SR.joinSpokenForms(said("we post every day because"), script: said("post every day because everyday content"))
      == said("we post every day because"))
let everyOne = "Thank you, every one of you, for being here."
check("support: 'everyone' for 'every one' moves on to 'one'",
      SR.supportEnd(source: everyOne, spoken: said("thank you everyone"), current: startOf("every", in: everyOne),
                    candidate: startOf("every", in: everyOne), matches: eq)?.end == endOf("every one", in: everyOne))

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

// Scale words after digits ("$2M" heard as "$2 million").
check("isSpokenForm: '2 million' for '2m'", SR.isSpokenForm("2m", said("$2 million")[...]))
check("isSpokenForm: '1.5 million' for '1.5M'", SR.isSpokenForm("15m", said("$1.5 million")[...]))
check("isSpokenForm: '10 thousand' for '10k', '3 billion' for '3b'",
      SR.isSpokenForm("10k", said("10 thousand")[...]) && SR.isSpokenForm("3b", said("3 billion")[...]))
check("isSpokenForm: '2 million' is not '3m' or '2k'",
      !SR.isSpokenForm("3m", said("2 million")[...]) && !SR.isSpokenForm("2k", said("2 million")[...]))
let sales = "We hit $10K a month in March, $2M in total sales by year two, and 100K followers on Instagram."
check("'$2 million' heard for '$2M' is not off script",
      !offScript(sales, held: startOf("$2M", in: sales), "march 2 million in total"))
check("support: '$2 million in total' moves on to 'total'",
      SR.supportEnd(source: sales, spoken: said("$2 million in total"), current: startOf("$2M", in: sales),
                    candidate: startOf("$2M", in: sales), matches: eq)?.end == endOf("in total", in: sales))
check("an ad-lib about 2 million views is still off script",
      offScript(sales, held: startOf("$2M", in: sales), "we got 2 million views on youtube"))

// Short forms read in full ("DFY" as "done for you").
check("isSpokenForm: 'done for you' for 'dfy', 'virtual assistant' for 'va'",
      SR.isSpokenForm("dfy", said("done for you")[...]) && SR.isSpokenForm("va", said("virtual assistant")[...]))
check("isSpokenForm: 'key performance indicators' for 'KPIs'", SR.isSpokenForm("kpis", said("key performance indicators")[...]))
check("isSpokenForm: 'done for me' is not 'dfy'", !SR.isSpokenForm("dfy", said("done for me")[...]))
let offer = "Our DFY package has a clear ROI, a strong CTA on every page, and an SOP for each VA on the team."
check("'done for you' read for 'DFY' is not off script",
      !offScript(offer, held: startOf("DFY", in: offer), "our done for you package"))
check("'call to action' read for 'CTA' is not off script",
      !offScript(offer, held: startOf("CTA", in: offer), "a strong call to action on"))
check("support: 'virtual assistant on the' moves on to 'the'",
      SR.supportEnd(source: offer, spoken: said("each virtual assistant on the"), current: startOf("VA", in: offer),
                    candidate: startOf("VA", in: offer), matches: eq)?.end == endOf("on the", in: offer))
check("an ad-lib with 'done for you' words is still off script",
      offScript(offer, held: startOf("DFY", in: offer), "i have done this for years now"))

check("isSpokenForm: 'done with you', 'calls to action', 'return on investment', 'standard operating procedure'",
      SR.isSpokenForm("dwy", said("done with you")[...]) && SR.isSpokenForm("ctas", said("calls to action")[...])
      && SR.isSpokenForm("roi", said("return on investment")[...]) && SR.isSpokenForm("sop", said("standard operating procedure")[...]))

// Number short forms with a letter read in another form (r4: "10 times" for
// "10x", "10 grand" for "$10k", "3 to 5K" for "$3-5k", "a million" for "$1M").
check("isSpokenForm: '3 times' for '3x', '10 grand' for '10k'",
      SR.isSpokenForm("3x", said("3 times")[...]) && SR.isSpokenForm("10k", said("10 grand")[...]))
check("isSpokenForm: '3 times' is not '4x', '10 grand' is not '10m'",
      !SR.isSpokenForm("4x", said("3 times")[...]) && !SR.isSpokenForm("10m", said("10 grand")[...]))
check("rangeDigits: the end carries the unit ('3 to 5k', '4 to 6 pm', '2 to 3 times', 'three to five k')",
      SR.rangeDigits(said("3 to 5K")[...]) == "35k" && SR.rangeDigits(said("4 to 6 PM")[...]) == "46pm"
      && SR.rangeDigits(said("2 to 3 times")[...]) == "23x" && SR.rangeDigits(said("three to five K")[...]) == "35k")
let coach = "Most of my clients hit $10k months, charge $3-5k per client, get a 10x return, cross $1M by year two, and join our calls from 4-6pm every week. Some hit $2.5M later on, and the course is $100 a month."
check("'10 times' read for '10x' is not off script", !offScript(coach, held: startOf("10x", in: coach), "get a 10 times return"))
check("'10 grand' read for '$10k' is not off script", !offScript(coach, held: startOf("$10k", in: coach), "clients hit 10 grand months"))
check("'3 to 5K' read for '$3-5k' is not off script", !offScript(coach, held: startOf("$3-5k", in: coach), "charge 3 to 5K per client"))
check("'three to five K' read for '$3-5k' is not off script",
      !offScript(coach, held: startOf("$3-5k", in: coach), "charge three to five K per"))
check("'4 to 6 PM' read for '4-6pm' is not off script", !offScript(coach, held: startOf("4-6pm", in: coach), "calls from 4 to 6 PM every"))
check("'4 to 6' as the newest words (the reader says '4 to 6 PM') is not off script",
      !offScript(coach, held: startOf("4-6pm", in: coach), "our calls from 4 to 6"))
check("'3 to' as the newest words joins the start of '35k' (the reader says '3 to 5K')",
      SR.joinSpokenForms(said("charge 3 to"), script: ["charge", "35k", "per"], partialEnd: true) == ["charge", "35k"])
check("'a million dollars' read for '$1M' is not off script",
      !offScript(coach, held: startOf("$1M", in: coach), "cross a million dollars by"))
check("'a hundred bucks' read for '$100' is not off script",
      !offScript(coach, held: startOf("$100", in: coach), "course is a hundred bucks"))
check("'two and a half million' read for '$2.5M' is not off script",
      !offScript(coach, held: startOf("$2.5M", in: coach), "some hit two and a half million later"))
check("a number said in words joins the script number with its scale letter ('one million' is '1m', not '10k')",
      SR.joinSpokenForms(said("one million"), script: ["10k", "10x", "1m"]) == ["1m"])
check("'a hundred' joins '100', not '1m', and not '1m' alone",
      SR.joinSpokenForms(said("a hundred"), script: ["1m", "100"]) == ["100"]
      && SR.joinSpokenForms(said("a hundred"), script: ["1m"]) == ["a", "hundred"])
check("support: 'a 10 times return' moves on to 'return'",
      SR.supportEnd(source: coach, spoken: said("a 10 times return"), current: startOf("10x", in: coach),
                    candidate: startOf("10x", in: coach), matches: eq)?.end == endOf("10x return,", in: coach))
check("an ad-lib with '10 grand' in it is still off script",
      offScript(coach, held: startOf("$10k", in: coach), "we did 10 grand last month which was insane"))
check("an ad-lib with 'a hundred' in it is still off script",
      offScript(coach, held: startOf("$1M", in: coach), "a hundred people came to the last one"))
check("an ad-lib with another range is still off script",
      offScript(coach, held: startOf("$3-5k", in: coach), "we did 3 to 5 calls a day back then"))
// A range with a unit read without the unit (r4 round 2: "four to six" for
// "4-6pm" fitted only as the newest words, then counted as 3 misses).
check("a range read without its unit joins the script range ('3 to 5' for '35k', 'two to three' for '23x')",
      SR.joinSpokenForms(said("charge 3 to 5 per"), script: ["charge", "35k", "per"]) == ["charge", "35k", "per"]
      && SR.joinSpokenForms(said("two to three what"), script: ["charge", "23x", "what"]) == ["23x", "what"])
let tuesdays = "Join our group calls from 4-6pm on Tuesdays and bring one question each week."
check("'from four to six on Tuesdays' read for 'from 4-6pm on Tuesdays' is not off script",
      !offScript(tuesdays, held: startOf("4-6pm", in: tuesdays), "from four to six on tuesdays"))
check("'three to five per client' read for '$3-5k per client' is not off script",
      !offScript(coach, held: startOf("$3-5k", in: coach), "charge three to five per client"))
check("a range without its unit joins only as 3 words ('3 to' alone does not join '3x')",
      SR.joinSpokenForms(said("go 3 to 4 times"), script: ["get", "a", "3x", "return"]) == said("go 3 to 4 times"))
check("a range without its unit joins only a unit of letters ('3 to 5' does not join '350')",
      SR.joinSpokenForms(said("charge 3 to 5 per"), script: ["charge", "350", "per"]) == said("charge 3 to 5 per"))

// A money range with the scale written as a full number or on both ends (r5:
// "five to ten thousand" for "$5-10k" written "5 to 10,000" by the recogniser
// gave "510000", not "510k", so the highlight held for 3 words).
let fees = "Most clients charge $5-10k per project and $3-5k per month, and a few reach $1-2M a year."
check("'5 to 10,000' read for '$5-10k' joins '510k'",
      SR.joinSpokenForms(said("charge 5 to 10,000 per"), script: said(fees)) == ["charge", "510k", "per"])
check("'5 or 10,000' read for '$5-10k' joins '510k'",
      SR.joinSpokenForms(said("charge 5 or 10,000 per"), script: said(fees)) == ["charge", "510k", "per"])
check("'$5000 to $10,000' read for '$5-10k' joins '510k'",
      SR.joinSpokenForms(said("charge $5000 to $10,000 per"), script: said(fees)) == ["charge", "510k", "per"])
check("'5K to 10K' read for '$5-10k' joins '510k'",
      SR.joinSpokenForms(said("charge 5K to 10K per"), script: said(fees)) == ["charge", "510k", "per"])
check("'3 to 5000' read for '$3-5k' joins '35k'",
      SR.joinSpokenForms(said("and 3 to 5000 per"), script: said(fees)) == ["and", "35k", "per"])
check("'$3000 to $5000' read for '$3-5k' joins '35k'",
      SR.joinSpokenForms(said("and $3000 to $5000 per"), script: said(fees)) == ["and", "35k", "per"])
check("'3K to 5K' read for '$3-5k' joins '35k'",
      SR.joinSpokenForms(said("and 3K to 5K per"), script: said(fees)) == ["and", "35k", "per"])
check("'$1,000,000 to $2,000,000' read for '$1-2M' joins '12m'",
      SR.joinSpokenForms(said("reach $1,000,000 to $2,000,000 a"), script: said(fees)) == ["reach", "12m", "a"])
check("'5 to 10,000 per project' read for '$5-10k per project' is not off script",
      !offScript(fees, held: startOf("$5-10k", in: fees), "charge 5 to 10,000 per"))
check("'3K to 5K per month' read for '$3-5k per month' is not off script",
      !offScript(fees, held: startOf("$3-5k", in: fees), "and 3K to 5K per"))
check("a range with another letter on each end does not join ('3K to 5M' is not '35k' or '35m')",
      SR.joinSpokenForms(said("and 3K to 5M per"), script: ["and", "35k", "35m", "per"]) == said("and 3k to 5m per"))
check("a range with a full number on its end and no script range for it stays as said",
      SR.joinSpokenForms(said("charge 5 to 10,000 per"), script: ["charge", "510", "per"]) == said("charge 5 to 10000 per"))
check("an ad-lib with a range written in full is still off script",
      offScript(fees, held: startOf("$3-5k", in: fees), "we did 3 to 5000 posts last year honestly"))

// "or" for the range dash ("one or two calls" for "1-2 calls").
let calls = "Book 1-2 calls a week and do 2-3x more outreach on the other days."
check("'one or two' read for '1-2' joins '12'",
      SR.joinSpokenForms(said("book one or two calls"), script: said(calls)) == ["book", "12", "calls"])
check("'one or two calls' read for '1-2 calls' is not off script",
      !offScript(calls, held: startOf("1-2", in: calls), "book one or two calls"))
check("'two or three times' read for '2-3x' is not off script",
      !offScript(calls, held: startOf("2-3x", in: calls), "do two or three times more"))
check("'one or two' read as written in the script stays as it is",
      SR.joinSpokenForms(said("book one or two calls"), script: said("Book one or two calls, or 1-2 demos")) == said("book one or two calls"))

// A number said in words joins the script number with its value (r4 round 1:
// "two thousand five hundred" took the "k" of "thousand" and joined "$20k").
let plan = "Go from $2,500 to $20k a month with the 3 step plan, and do it in less than 6 months."
check("spokenNumberForms: value first, then the short form ('twenty k', 'four grand', 'two and a half million')",
      SR.spokenNumberForms(said("two thousand five hundred dollars")[...]) == ["2500"]
      && SR.spokenNumberForms(said("twenty K")[...]) == ["20000", "20k", "20"]
      && SR.spokenNumberForms(said("four grand")[...]) == ["4000", "4k", "4"]
      && SR.spokenNumberForms(said("two and a half million")[...]) == ["2500000", "25m", "25"])
check("'two thousand five hundred to twenty K' joins '2500' then '20k'",
      SR.joinSpokenForms(said("go from two thousand five hundred to twenty K"), script: said(plan))
        == said("go from 2500 to 20k"))
check("'four grand' for '$4,000' joins '4000', not '$40k'",
      SR.joinSpokenForms(said("charge four grand"), script: said("Charge $4,000 for the first program, and $40k is"))
        == ["charge", "4000"])
check("'two thousand five hundred to' with one misheard word is not off script",
      !offScript(plan, held: startOf("$2,500", in: plan), "so from two thousand five hundred to"))
// Script text with "a hundred" / "a million" read as written (r4 round 1: it
// joined a nearby "12" or "100" and the highlight waited).
check("numbers read as written in the script stay as they are ('a hundred', 'two thousand')",
      SR.joinSpokenForms(said("we had a hundred leads"), script: said("We had a hundred leads and 12 calls"))
        == said("we had a hundred leads")
      && SR.joinSpokenForms(said("we sold two thousand copies"), script: said("We sold two thousand copies in 2 weeks"))
        == said("we sold two thousand copies"))
let reach = "We reached a million views and 100 new leads in 12 days with one simple reel."
check("'a million' read as written with one misheard word is not off script",
      !offScript(reach, held: startOf("views", in: reach), "we reached a million use and 100"))
check("'two and a half years' does not join '2x' (another value; the window has lost 'two')",
      SR.joinSpokenForms(said("two and a half years"), script: said("and a half years to reach 2x")) == said("two and a half years"))
check("'a hundred' in an ad-lib does not join '12' (another value)",
      SR.joinSpokenForms(said("a hundred people applied"), script: said("to land 12 new clients")) == said("a hundred people applied"))

// Helpers.
check("inOrderHits counts the longest in-order match", SR.inOrderHits(said("a x b c"), said("a b c d"), matches: eq) == 3)
check("inOrderLast gives the last matched script word", SR.inOrderLast(said("in the it one"), said("in the next one"), matches: eq)?.last == 3)
check("dropLastWords drops whole words", SR.dropLastWords("so we tried paid", 2) == "so we ")
check("dropLastWords keeps the text when n is 0", SR.dropLastWords("so we", 0) == "so we")

if fails > 0 { print("\(fails) failed"); exit(1) }
