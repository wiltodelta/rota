import RotaCore
import XCTest

final class SleepStateTests: XCTestCase {
    private let start = SleepState.Reading(awake: 1000, total: 5000)

    private func announced() -> SleepState {
        var state = SleepState()
        state.willSleep(at: start)
        return state
    }

    func testAwakeUntilASleepIsAnnounced() {
        XCTAssertFalse(SleepState().isAsleep(at: start))
    }

    func testAsleepFromTheAnnouncement() {
        XCTAssertTrue(announced().isAsleep(at: start))
    }

    func testStaysAsleepThroughADarkWake() {
        let darkWake = SleepState.Reading(awake: 1600, total: 9000)
        XCTAssertTrue(announced().isAsleep(at: darkWake))
    }

    func testTheAnnouncedWakeEndsIt() {
        var state = announced()
        state.didWake()
        XCTAssertFalse(state.isAsleep(at: SleepState.Reading(awake: 1001, total: 9000)))
    }

    func testASleepThatNeverHappenedLapses() {
        let state = announced()
        XCTAssertTrue(state.isAsleep(at: SleepState.Reading(awake: 1119, total: 5119)))
        XCTAssertFalse(state.isAsleep(at: SleepState.Reading(awake: 1120, total: 5120)))
    }

    func testTheRealClocksCountSleepOnlyInTotal() {
        let reading = SleepState.Reading.now
        XCTAssertGreaterThan(reading.awake, 0)
        XCTAssertGreaterThanOrEqual(reading.total, reading.awake)
    }
}
