// extract: Textream/Textream/ExternalDisplayController.swift ExternalLayout sidePadding
// Regression tests for the External tab's Column Width (ExternalDisplayView.sidePadding).
import Foundation

// extract.py copies no imports. This makes CGFloat visible to the extracted code.
typealias CGFloat = Foundation.CGFloat

var fails = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  pass" : "  FAIL", name)
    if !ok { fails += 1 }
}
func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.001 }

// The slider's values: 40% to 100% in 5% steps.
let sliderValues = (8...20).map { Double($0) * 0.05 }

for width: CGFloat in [400, 1024, 1920] {
    let w = Int(width)
    let automaticMargin = max(40, width * 0.08)
    let automaticColumn = width - 2 * automaticMargin
    func column(_ c: Double) -> CGFloat { width - 2 * ExternalLayout.sidePadding(screenWidth: width, column: c) }

    check("100% keeps the automatic margin (\(w) pt)",
          near(ExternalLayout.sidePadding(screenWidth: width, column: 1), automaticMargin))
    check("50% is half the automatic width (\(w) pt)", near(column(0.5), automaticColumn / 2))
    check("every slider value is that share of the automatic width (\(w) pt)",
          sliderValues.allSatisfy { near(column($0), automaticColumn * CGFloat($0)) })
    check("a wider setting always gives a wider column (\(w) pt)",
          zip(sliderValues, sliderValues.dropFirst()).allSatisfy { column($0) < column($1) })
    check("the margin never gets smaller than the automatic margin (\(w) pt)",
          sliderValues.allSatisfy { ExternalLayout.sidePadding(screenWidth: width, column: $0) >= automaticMargin - 0.001 })
}

// The old formula added the narrowing margin to the automatic one, so 40% of
// a 1920 pt screen gave a 24% column (461 pt). It must be 40% of the 1613 pt
// automatic width (645 pt).
check("40% on 1920 pt is 40% of the automatic width, not 24% of the screen",
      near(1920 - 2 * ExternalLayout.sidePadding(screenWidth: 1920, column: 0.4), 0.4 * (1920 - 2 * 153.6)))

if fails > 0 { print("\(fails) failed"); exit(1) }
