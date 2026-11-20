@testable import Rota
import XCTest

final class SessionHeaderFitTests: XCTestCase {
    /// Summary 200, Show Routine 120, labeled actions 300, 12 pt spacing: one row needs 668.
    private func fit(_ available: CGFloat) -> SessionHeaderFit.Arrangement {
        SessionHeaderFit(available: available, summary: 200, routine: 120, labeledActions: 300)
            .arrangement(spacing: 12)
    }

    /// As the nested `ViewThatFits` it replaces: icons alone never keep the actions on one row.
    func testOneLabeledRowThenASecondRowLabeledWhileItFits() {
        XCTAssertEqual(fit(668), .init(oneRow: true, iconOnly: false))
        XCTAssertEqual(fit(667), .init(oneRow: false, iconOnly: false))
        XCTAssertEqual(fit(312), .init(oneRow: false, iconOnly: false))
        XCTAssertEqual(fit(311), .init(oneRow: false, iconOnly: true))
    }

    func testUnmeasuredHeaderStartsWithTheWidestArrangement() {
        XCTAssertEqual(SessionHeaderFit().arrangement(spacing: 12), .init(oneRow: true, iconOnly: false))
    }

    /// The question card's button rows: full, then compact, then stacked.
    func testFirstFitPicksTheFirstCandidateThatFitsElseTheFallback() {
        var fit = FirstFit()
        XCTAssertEqual(fit.choice, 0, "unmeasured")
        fit.set(1, 300)
        fit.set(0, 420)
        fit.available = 420
        XCTAssertEqual(fit.choice, 0)
        fit.available = 419
        XCTAssertEqual(fit.choice, 1)
        fit.available = 299
        XCTAssertEqual(fit.choice, 2)
    }
}
