// extract: Textream/Textream/SpeechRecognizer.swift SpeechRecognizer regressionWindowChars regressionLookAheadChars regressionMinWords regressionMinGapChars regressionGrowthsToConfirm regressionMaxGrowthChars regressionConfirmed regressionEnd regressionFloorReleased regressionKept regressionHoldsPageEnd regressionRun regressionSourceWords
// include: Textream/Textream/SpeechTextAlignment.swift
// Regression tests for re-read tracking (the static regression functions of
// SpeechRecognizer).
import Foundation

var fails = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  pass" : "  FAIL", name)
    if !ok { fails += 1 }
}
let eq: (String, String) -> Bool = { $0 == $1 }
func split(_ s: String) -> [String] { s.split(separator: " ").map(String.init) }
func clean(_ w: String) -> String { w.lowercased().filter { $0.isLetter || $0.isNumber } }
/// Char offset just after the nth occurrence of `phrase` in `text`.
func endOf(_ phrase: String, in text: String, _ nth: Int = 0) -> Int {
    var from = text.startIndex
    for _ in 0..<nth { from = text.range(of: phrase, range: from..<text.endIndex)!.upperBound }
    return text.distance(from: text.startIndex, to: text.range(of: phrase, range: from..<text.endIndex)!.upperBound)
}
func startOf(_ phrase: String, in text: String, _ nth: Int = 0) -> Int { endOf(phrase, in: text, nth) - phrase.count }
/// Feeds `then` one word per result, the way checkForRegression does, with the
/// highlight at `current` and the tap floor at `floor`. `before` are the words
/// already said. Returns the confirmed run end and how many of the `then`
/// words were said by then.
func session(_ source: String, current: Int, floor: Int = 0, before: [String], then: [String]) -> (end: Int, words: Int)? {
    var pending: (end: Int, growths: Int)? = nil
    var floor = floor
    var said = before.map(clean)
    for (n, w) in then.enumerated() {
        said.append(clean(w))
        guard said.count >= SpeechRecognizer.regressionMinWords else { continue }
        let tail = Array(said.suffix(SpeechRecognizer.regressionMinWords + 2))
        if floor > 0, SpeechRecognizer.regressionFloorReleased(source: source, current: current, floor: floor, tail: tail, matches: eq) {
            floor = 0
        }
        let end = SpeechRecognizer.regressionEnd(source: source, current: current, floor: floor, tail: tail, matches: eq)
        if SpeechRecognizer.regressionConfirmed(pending: &pending, end: end), let end { return (end, n + 1) }
    }
    return nil
}

let script = "the quick brown fox jumps over the lazy dog while the cat sleeps on the warm mat and dreams of fish all day long in the sun"
let words = split(script)
func offsetAfter(_ n: Int) -> Int { words.prefix(n).reduce(0) { $0 + $1.count + 1 } - 1 }
let cur20 = offsetAfter(20)

check("normal pause does not jump back",
      SpeechRecognizer.regressionEnd(source: script, current: cur20, tail: Array(words[14..<20]), matches: eq) == nil)
let end = SpeechRecognizer.regressionEnd(source: script, current: cur20, tail: Array(words[2..<8]), matches: eq)
check("genuine re-read is detected", end != nil)
check("lands after the re-read words", end == offsetAfter(8))

// The run must end on the newest spoken word.
check("run that the newest word does not continue is not a re-read",
      SpeechRecognizer.regressionEnd(source: script, current: cur20, tail: Array(words[2..<7]) + ["banana"], matches: eq) == nil)

// Floor: a re-read never lands before the last tapped word.
check("floor after the re-read words blocks it",
      SpeechRecognizer.regressionEnd(source: script, current: cur20, floor: offsetAfter(8) + 1, tail: Array(words[2..<8]), matches: eq) == nil)
check("floor before the re-read words keeps it",
      SpeechRecognizer.regressionEnd(source: script, current: cur20, floor: offsetAfter(1) + 1, tail: Array(words[2..<8]), matches: eq) == offsetAfter(8))
check("floor at the highlight blocks every re-read",
      SpeechRecognizer.regressionEnd(source: script, current: cur20, floor: cur20, tail: Array(words[2..<8]), matches: eq) == nil)

// Repeated phrases (finding 7): the copy just read beats its earlier copy.
let list = "Here are two simple habits that changed my life this year. The first thing you need to do is sleep eight hours every single night. The second thing you need to do is eat real food at every meal. Both of these are free and anyone can start today."
let phrase = split("thing you need to do is")
check("repeated phrase just read is not a re-read",
      SpeechRecognizer.regressionEnd(source: list, current: endOf("thing you need to do is", in: list, 1), tail: phrase, matches: eq) == nil)
// The highlight can be behind the reader, so the search also looks past it.
check("highlight one word behind on a repeated phrase: not a re-read",
      SpeechRecognizer.regressionEnd(source: list, current: endOf("thing you need to do", in: list, 1), tail: phrase, matches: eq) == nil)
let refrain = "Start small, stay consistent, and never give up on the people who need you. When I started I had two clients and no plan. I kept going every week. Start small, stay consistent, and never give up on the people who need you. That is the whole secret."
let refrainSaid = split("Start small, stay consistent, and never give up on the people who need you. When I started I had two clients and no plan. I kept going every week. Start small, stay")
check("highlight one word behind inside a repeated line: no jump while the reader goes on",
      session(refrain, current: endOf("Start small,", in: refrain, 1), before: refrainSaid, then: split("consistent, and never give up on the people")) == nil)
check("highlight 2 words before a repeated 6-word phrase: not a re-read",
      SpeechRecognizer.regressionEnd(source: list, current: endOf("eight hours every single night. The", in: list), tail: phrase, matches: eq) == nil)
let grow = "Do it for ninety days. If you want to grow your business, you need to do the same. Pick one offer that solves one painful problem. Pick one audience that has that problem and can pay to fix it. Pick one channel where that audience already spends time. If you want to grow your business, this is the part most people skip."
check("highlight far behind the second copy of a repeated phrase: not a re-read",
      SpeechRecognizer.regressionEnd(source: grow, current: endOf("Pick one audience that has", in: grow), tail: split("if you want to grow your"), matches: eq) == nil)
let firstCopy = SpeechRecognizer.regressionEnd(source: list, current: endOf("eat real food at every meal.", in: list), tail: split("first thing you need to do"), matches: eq)
check("re-read of the first copy, with words that only it has, is still found",
      firstCopy == endOf("first thing you need to do", in: list))

// Stage directions are skipped (finding 27).
let stage = "Today I want to share a story with you. I really love this [look at the camera] part of the story because it shows how much one small choice can change. After that day nothing was the same for me or for my family and I am still grateful."
let stageEnd = SpeechRecognizer.regressionEnd(source: stage, current: endOf("the same for me", in: stage), tail: split("really love this part of the"), matches: eq)
check("re-read across a multi-word stage direction is found", stageEnd == endOf("part of the", in: stage))
let smile = stage.replacingOccurrences(of: "[look at the camera]", with: "[smile]")
check("re-read across a one-word stage direction is found",
      SpeechRecognizer.regressionEnd(source: smile, current: endOf("the same for me", in: smile), tail: split("really love this part of the"), matches: eq) == endOf("part of the", in: smile))
// The forward match skips a stage direction, so the highlight can be past it
// while the words just read end 30 chars or more before it.
let endPage = "This is a short page that ends with a stage direction so we can test it. Thank you all for watching today. [smile and wave at the camera]"
check("words just read before a long stage direction at the page end are not a re-read",
      SpeechRecognizer.regressionEnd(source: endPage, current: endPage.count, tail: split("thank you all for watching today"), matches: eq) == nil)
check("a re-read on that page is still found",
      SpeechRecognizer.regressionEnd(source: endPage, current: endPage.count, tail: split("this is a short page that"), matches: eq) == endOf("This is a short page that", in: endPage))
let midPage = "We start the show now and I am happy you are here. Here is the first big idea for today. [pause and look at the camera for a moment] The idea is simple and it works for most people."
check("words just read before a long stage direction mid-page are not a re-read",
      SpeechRecognizer.regressionEnd(source: midPage, current: startOf("The idea is", in: midPage), tail: split("the first big idea for today"), matches: eq) == nil)

// Confirmation: the run must grow twice with newly spoken words (finding 3).
func confirms(_ ends: [Int?]) -> [Bool] {
    var pending: (end: Int, growths: Int)? = nil
    return ends.map { SpeechRecognizer.regressionConfirmed(pending: &pending, end: $0) }
}
check("4-word run that does not grow does not jump", confirms([100, nil, 100]) == [false, false, false])
check("5-word overlap (one growth) does not jump", confirms([100, 106, nil, 100]) == [false, false, false, false])
check("result with no run starts again", confirms([100, 106, nil, 112]) == [false, false, false, false])
check("4-word run plus two growths jumps", confirms([100, 106, 110]) == [false, false, true])
check("same end keeps waiting", confirms([100, 100, 106, 106, 112]) == [false, false, false, false, true])
check("smaller end starts again", confirms([100, 106, 90, 96, 102]) == [false, false, false, false, true])
check("step of more than 40 chars starts again", confirms([100, 106, 160, 166, 170]) == [false, false, false, false, true])
check("pending is cleared after a jump", confirms([100, 106, 110, 116]) == [false, false, true, false])

// Word-by-word sessions with the real functions.
let business = "So today I want to talk about the three things that changed my business this year. The first thing is that I stopped trying to do everything myself and I hired a coach. The second thing is that I started posting every day on Instagram. That one scared me the most. But once I did it my income doubled within two months. The third thing is that I learned to say no to clients who were not a good fit for me."
let readSoFar = split("So today I want to talk about the three things that changed my business this year. The first thing is that I stopped trying to do everything myself and I hired a coach. The second thing is that I started posting every day on Instagram. That one scared me the")
let atReader = endOf("That one scared me the", in: business) + 1
check("aside 'honestly the thing is that I think' does not jump",
      session(business, current: atReader, before: readSoFar, then: split("honestly the thing is that I think that")) == nil)
let reread = session(business, current: atReader, before: readSoFar, then: split("The first thing is that I stopped trying"))
check("genuine re-read jumps after 6 words", reread?.words == 6)
check("genuine re-read lands after the 6th word", reread?.end == endOf("The first thing is that I", in: business))
let story = "Hi everyone. The thing is that I never planned to start a business. I was working a normal job and I was happy enough with it. Then one day my manager called me into his office and told me that the whole team was being let go at the end of the month."
check("aside 'so the thing is that I want you to' does not jump",
      session(story, current: endOf("let go at the end", in: story) + 1, before: split("Hi everyone. The thing is that I never planned to start a business. I was working a normal job and I was happy enough with it. Then one day my manager called me into his office and told me that the whole team was being let go at the end"), then: split("so the thing is that I want you to")) == nil)

// Undo (finding 3): after a jump, the next words must continue the text there.
func kept(_ source: String, _ target: Int, _ said: String) -> Bool? {
    SpeechRecognizer.regressionKept(source: source, target: target, spoken: split(said).map(clean), matches: eq)
}
let habits = "Welcome back to the channel. Today we talk about habits. The secret is to make the first step so small that you cannot say no. Start with two minutes a day and then you can make it bigger."
let afterMake = endOf("The secret is to make the", in: habits) + 1
check("jump kept when the next words continue the text", kept(habits, afterMake, "first step") == true)
check("jump kept with one misheard word", kept(habits, afterMake, "furst step so") == true)
check("jump kept when a source word was not heard", kept(habits, afterMake, "first so") == true)
check("undecided after one word", kept(habits, afterMake, "first") == nil && kept(habits, afterMake, "blah") == nil)
check("undecided after one hit and one miss", kept(habits, afterMake, "blah step") == nil)
check("jump undone when 2 words do not fit", kept(habits, afterMake, "two minutes") == false)
// Words from before the jump can come back: the reader says the last re-read
// words again, or a revision of the transcript puts them back. They do not
// count until a word continues the text.
check("revision that puts back the end of the re-read words keeps the jump",
      kept(habits, endOf("Today we talk about habits. The", in: habits) + 1, "s The secret is") == true)
check("re-read words said again keep the jump", kept(habits, afterMake, "make the first step") == true)
check("re-read words alone leave the check undecided", kept(habits, afterMake, "to make the") == nil)
// A stem correction ("habit" -> "habits.") leaves the end of a re-read word
// ("s") in the words since the jump. It is not a miss.
check("end of a corrected re-read word plus one misheard word keeps the jump",
      kept(habits, endOf("Today we talk about habits. The", in: habits) + 1, "s the blah is to") == true)
let steps = "Step two, I go for a short walk. Step three, I write down the one thing I need to get done today. Step four, I do that one thing first."
check("a put-back re-read word that is also a later word does not count",
      kept(steps, endOf("Step three, I write down the", in: steps) + 1, "three I write down the one thing") == true)
check("the 6th word before the target is a re-read word",
      kept(steps, endOf("Step three, I write down the", in: steps) + 1, "step blah one thing") == true)
let picks = "Pick one offer that solves one painful problem. Pick one audience that has that problem and can pay to fix it."
check("after a word that continues the text, re-read words that continue it count",
      kept(picks, endOf("Pick one offer that solves one", in: picks) + 1, "painful so Pick one") == true)
let aloud = "Read it out loud and then read it out loud again, slowly this time."
check("re-read words that are also the next words move the check on",
      kept(aloud, endOf("Read it out loud and then", in: aloud) + 1, "read it out loud again, slowly") == true)
check("re-read words that are also the next words do not keep the jump alone",
      kept(aloud, endOf("Read it out loud and then", in: aloud) + 1, "read it out loud") == nil)
let job = "I was working a normal job and I was happy enough with it. Then one day my manager called me."
check("next word not heard, then words that are also re-read words: the jump is kept",
      kept(job, endOf("I was working a normal job", in: job) + 1, "I was happy enough") == true)
// An aside plus the next script word can match 6 earlier words in a row: the
// jump happens, and the script words after it undo it.
let aside = session(business, current: endOf("within two months.", in: business),
                    before: split("So today I want to talk about the three things that changed my business this year. The first thing is that I stopped trying to do everything myself and I hired a coach. The second thing is that I started posting every day on Instagram. That one scared me the most. But once I did it my income doubled within two months."),
                    then: split("okay so I want to talk about The"))
check("aside 'okay so I want to talk about' + 'The' jumps", aside?.end == endOf("So today I want to talk about the", in: business))
check("the next script words undo that jump",
      kept(business, (aside?.end ?? 0) + 1, "third thing is") == false)
check("that jump is still undone when a revision puts the aside words back",
      kept(business, (aside?.end ?? 0) + 1, "want to talk about the third thing is") == false)
// After a word that continues the text, a re-read word said again means the
// reader went back: the count starts again from the jump.
check("reader says one next word, then starts the re-read again: the jump is kept",
      kept(habits, afterMake, "first make the first step") == true)
// The recognizer can drop one word of the restated text ("first" or "step").
// A skip after a restart needs 3 matching words.
check("restart with the first next word not heard: the jump is kept",
      kept(habits, afterMake, "first make the step so small") == true)
check("restart with the second next word not heard: the jump is kept",
      kept(habits, afterMake, "first make the first so small") == true)
// The recognizer can also mishear a restated word. (2 dropped or misheard
// words in a row after a restart still undo the jump: accepted.)
check("restart with the first next word misheard: the jump is kept",
      kept(habits, afterMake, "first make the blah step so small") == true)
check("restart with the second next word misheard: the jump is kept",
      kept(habits, afterMake, "first make the first blah so small") == true)
// After such a restart, a restated aside must not keep a wrong jump through a
// loose match ("then" for "the", 2 words on).
let growPart = "If you want to grow your business, this is the part that matters most."
let loose: (String, String) -> Bool = { $0.hasPrefix($1) || $1.hasPrefix($0) }
check("after a restart, a loose match does not keep the jump",
      SpeechRecognizer.regressionKept(source: growPart, target: endOf("If you want to grow your", in: growPart) + 1,
                                      spoken: split("business your business then they"), matches: loose) == false)
check("after a restart and a miss, a word 2 on does not keep the jump",
      kept(growPart, endOf("If you want to grow your", in: growPart) + 1, "business your business rule is") == nil
      && kept(growPart, endOf("If you want to grow your", in: growPart) + 1, "business your business rule is simple") == false)
check("after a restart, one word 2 on does not keep the jump",
      kept(growPart, endOf("If you want to grow your", in: growPart) + 1, "business your business is simple do") == false)

// Page end (finding 28): the first words of a re-read must not end the page.
let lastLines = "It was one offer, one audience and one channel. Thank you for reading, and I will see you in the next one."
func holdsEnd(_ said: String) -> Bool {
    SpeechRecognizer.regressionHoldsPageEnd(source: lastLines, floor: 0, spoken: split(said).map(clean), matches: eq)
}
check("re-read that starts near the page end holds the move to the end",
      holdsEnd("and I will see you in the next It was one"))
check("reading the last words moves to the end", !holdsEnd("and I will see you in the next one."))
check("re-read near the page end with a misheard first word holds the end",
      holdsEnd("and I will see you in the next blah was one"))
// An extra word before the last word can make a word pair that is also
// earlier on the page. Holding the end then would keep the page open.
check("an extra word that makes an earlier word pair does not hold the end",
      !holdsEnd("and I will see you in the next offer one."))
check("one misheard word before the last word does not hold the end", !holdsEnd("will see you in the blah one."))
check("a closing line that repeats an earlier line does not hold the end",
      !SpeechRecognizer.regressionHoldsPageEnd(source: list + " The first thing you need to do", floor: 0, spoken: split("start today. The first thing you need to do").map(clean), matches: eq))
check("a long stage direction at the page end does not hold the end",
      !SpeechRecognizer.regressionHoldsPageEnd(source: endPage + " [and then wait for the music to start before you stop]", floor: 0, spoken: split("Thank you all for watching today.").map(clean), matches: eq))

// Tap floor (finding 8): it goes only when the newest words fit the text after
// the tap better than any text before it.
let tapList = startOf("The second thing", in: list)
func released(_ source: String, _ current: Int, _ floor: Int, _ said: String) -> Bool {
    SpeechRecognizer.regressionFloorReleased(source: source, current: current, floor: floor, tail: Array(split(said).map(clean).suffix(6)), matches: eq)
}
check("floor stays when the old words also fit just after the tap",
      !released(list, endOf("thing you need to do is", in: list, 1), tapList, "need to do is"))
check("floor goes when the reader reads the tapped sentence",
      released(list, endOf("The second thing you need to", in: list), tapList, "The second thing you need to"))
check("floor stays while no words fit",
      !released(list, tapList + 40, tapList, "um so like you know"))
check("old sentence after a tap ahead, with the same words just after the tap: no jump",
      session(list, current: endOf("thing you need to do is", in: list, 1), floor: tapList, before: [], then: split("need to do is sleep eight hours every single night.")) == nil)
let tapStory = startOf("Then one day my manager", in: story)
check("old sentence with 'um' after a tap ahead: no jump",
      session(story, current: tapStory + 30, floor: tapStory, before: [], then: split("is that I never planned um to start a business. I was working")) == nil)
check("re-read before an earlier tap jumps once the floor is gone",
      session(story, current: endOf("called me into his office", in: story), floor: tapStory, before: [],
              then: split("Then one day my manager called me into his office I was working a normal job and I was")) != nil)

if fails > 0 { print("\(fails) failed"); exit(1) }
