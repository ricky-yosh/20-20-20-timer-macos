import XCTest
@testable import TimerCore

final class TimerCoreTests: XCTestCase {
    private let origin = ContinuousClock.now

    private var short: TimerConfiguration {
        TimerConfiguration(
            workInterval: .seconds(30),
            breakDuration: .seconds(6),
            snoozeInterval: .seconds(15),
            headsUpLead: .seconds(10),
            headsUpDuration: .seconds(2),
            finalWarningDuration: .seconds(3)
        )
    }

    private var checkInShort: TimerConfiguration {
        TimerConfiguration(
            workInterval: .seconds(30),
            breakDuration: .seconds(6),
            snoozeInterval: .seconds(15),
            headsUpLead: .seconds(10),
            headsUpDuration: .seconds(2),
            finalWarningDuration: .seconds(3),
            checkInDuration: .seconds(2),
            blinkCheckInOffsets: [.seconds(5), .seconds(15)],
            postureCheckInOffsets: [.seconds(10)]
        )
    }

    func testProductDefaults() {
        let config = TimerConfiguration()
        XCTAssertEqual(config.workInterval, .seconds(20 * 60))
        XCTAssertEqual(config.breakDuration, .seconds(20))
        XCTAssertEqual(config.snoozeInterval, .seconds(5 * 60))
        XCTAssertEqual(config.headsUpLead, .seconds(60))
        XCTAssertEqual(config.headsUpDuration, .seconds(8))
        XCTAssertEqual(config.finalWarningDuration, .seconds(5))
        XCTAssertEqual(config.checkInDuration, .seconds(4))
        XCTAssertEqual(config.blinkCheckInOffsets, [.seconds(5 * 60), .seconds(15 * 60)])
        XCTAssertEqual(config.postureCheckInOffsets, [.seconds(10 * 60)])
    }

    func testInitialStatePointsAtHeadsUpBoundary() {
        let state = TimerState(configuration: short, now: origin)
        XCTAssertEqual(state.phase, .work(deadline: origin + .seconds(30), warning: .none))
        XCTAssertEqual(state.nextDeadline, origin + .seconds(20))
    }

    func testWarningBoundariesAdvanceThroughEveryPhase() {
        var state = TimerState(configuration: short, now: origin)
        let deadline = origin + .seconds(30)

        state.handle(.deadlineReached, now: deadline - .seconds(10))
        XCTAssertEqual(state.phase, .work(deadline: deadline, warning: .headsUp))
        XCTAssertEqual(state.nextDeadline, deadline - .seconds(8))

        state.handle(.deadlineReached, now: deadline - .seconds(8))
        XCTAssertEqual(state.phase, .work(deadline: deadline, warning: .none))
        XCTAssertEqual(state.nextDeadline, deadline - .seconds(3))

        state.handle(.deadlineReached, now: deadline - .seconds(3))
        XCTAssertEqual(state.phase, .work(deadline: deadline, warning: .finalCountdown))
        XCTAssertEqual(state.nextDeadline, deadline)
    }

    func testEarlyDeadlineReachedIsIgnored() {
        var state = TimerState(configuration: short, now: origin)
        let deadline = origin + .seconds(30)

        state.handle(.deadlineReached, now: origin + .seconds(5))
        XCTAssertEqual(state.phase, .work(deadline: deadline, warning: .none))
        XCTAssertEqual(state.nextDeadline, deadline - .seconds(10))
    }

    func testScheduledBreakStartsAtDeadlineAndCompletesToFreshWork() {
        var state = TimerState(configuration: short, now: origin)
        let deadline = origin + .seconds(30)

        state.handle(.deadlineReached, now: deadline)
        XCTAssertEqual(state.phase, .onBreak(deadline: deadline + .seconds(6), origin: .scheduled))
        XCTAssertEqual(state.nextDeadline, deadline + .seconds(6))

        state.handle(.deadlineReached, now: deadline + .seconds(6))
        XCTAssertEqual(
            state.phase,
            .work(deadline: deadline + .seconds(6) + .seconds(30), warning: .none)
        )
    }

    func testSnoozeDuringHeadsUpSchedulesSnoozedWork() {
        var state = TimerState(configuration: short, now: origin)
        let deadline = origin + .seconds(30)
        let click = deadline - .seconds(10)

        state.handle(.deadlineReached, now: click)
        state.handle(.snoozeScheduledBreak, now: click)
        XCTAssertEqual(state.phase, .work(deadline: click + .seconds(15), warning: .none))
    }

    func testSnoozeDuringFinalCountdownSchedulesSnoozedWork() {
        var state = TimerState(configuration: short, now: origin)
        let deadline = origin + .seconds(30)
        let click = deadline - .seconds(3)

        state.handle(.deadlineReached, now: click)
        state.handle(.snoozeScheduledBreak, now: click)
        XCTAssertEqual(state.phase, .work(deadline: click + .seconds(15), warning: .none))
    }

    func testSnoozeWithoutWarningIsIgnored() {
        var state = TimerState(configuration: short, now: origin)
        let deadline = origin + .seconds(30)

        state.handle(.snoozeScheduledBreak, now: deadline - .seconds(20))
        XCTAssertEqual(state.phase, .work(deadline: deadline, warning: .none))
    }

    func testObsoleteSnoozeAfterNewActionIsIgnored() {
        var state = TimerState(configuration: short, now: origin)
        let deadline = origin + .seconds(30)
        let click = deadline - .seconds(10)

        state.handle(.deadlineReached, now: click)
        state.handle(.snoozeScheduledBreak, now: click)
        let snoozedDeadline = click + .seconds(15)

        state.handle(.snoozeScheduledBreak, now: click + .seconds(1))
        XCTAssertEqual(state.phase, .work(deadline: snoozedDeadline, warning: .none))
    }

    func testSnoozeOnScheduledOverlayButNotOnDemandBreak() {
        var state = TimerState(configuration: short, now: origin)
        let deadline = origin + .seconds(30)

        state.handle(.deadlineReached, now: deadline)
        state.handle(.snoozeScheduledBreak, now: deadline)
        XCTAssertEqual(state.phase, .work(deadline: deadline + .seconds(15), warning: .none))

        let takeBreakAt = deadline + .seconds(1)
        state.handle(.takeBreakNow, now: takeBreakAt)
        state.handle(.snoozeScheduledBreak, now: takeBreakAt)
        XCTAssertEqual(
            state.phase,
            .onBreak(deadline: takeBreakAt + .seconds(6), origin: .onDemand)
        )
    }

    func testPauseAndResumePreserveRemainingWork() {
        var state = TimerState(configuration: short, now: origin)
        let pauseAt = origin + .seconds(10)

        state.handle(.pause, now: pauseAt)
        XCTAssertEqual(state.phase, .paused(remaining: .seconds(20)))
        XCTAssertNil(state.nextDeadline)

        let resumeAt = pauseAt + .seconds(4)
        state.handle(.resume, now: resumeAt)
        XCTAssertEqual(state.phase, .work(deadline: resumeAt + .seconds(20), warning: .none))
    }

    func testEarlyDismissOfOnDemandBreakRestoresPreviousRemaining() {
        var state = TimerState(configuration: short, now: origin)
        let start = origin + .seconds(10)

        state.handle(.takeBreakNow, now: start)
        XCTAssertEqual(state.phase, .onBreak(deadline: start + .seconds(6), origin: .onDemand))

        let dismiss = start + .seconds(2)
        state.handle(.dismissBreak, now: dismiss)
        XCTAssertEqual(state.phase, .work(deadline: dismiss + .seconds(20), warning: .none))
    }

    func testNaturalCompletionOfOnDemandBreakFromWorkStartsFreshInterval() {
        var state = TimerState(configuration: short, now: origin)
        let start = origin + .seconds(10)

        state.handle(.takeBreakNow, now: start)
        let end = start + .seconds(6)
        state.handle(.deadlineReached, now: end)
        XCTAssertEqual(state.phase, .work(deadline: end + .seconds(30), warning: .none))
    }

    func testOnDemandBreakStartedPausedCompletesToPausedFullInterval() {
        var state = TimerState(configuration: short, now: origin)
        let pauseAt = origin + .seconds(10)

        state.handle(.pause, now: pauseAt)
        state.handle(.takeBreakNow, now: pauseAt)

        let end = pauseAt + .seconds(6)
        state.handle(.deadlineReached, now: end)
        XCTAssertEqual(state.phase, .paused(remaining: .seconds(30)))
        XCTAssertNil(state.nextDeadline)
    }

    func testOnDemandBreakStartedPausedDismissesToPriorRemaining() {
        var state = TimerState(configuration: short, now: origin)
        let pauseAt = origin + .seconds(10)

        state.handle(.pause, now: pauseAt)
        state.handle(.takeBreakNow, now: pauseAt)

        state.handle(.dismissBreak, now: pauseAt + .seconds(2))
        XCTAssertEqual(state.phase, .paused(remaining: .seconds(20)))
    }

    func testOnDemandBreakStartedPausedInterruptedBySleepPreservesPause() {
        var state = TimerState(configuration: short, now: origin)
        let pauseAt = origin + .seconds(10)

        state.handle(.pause, now: pauseAt)
        state.handle(.takeBreakNow, now: pauseAt)

        let unavailable = pauseAt + .seconds(1)
        state.handle(.screenUnavailable, now: unavailable)
        let available = unavailable + .seconds(20)
        state.handle(.screenAvailable, now: available)
        XCTAssertEqual(state.phase, .paused(remaining: .seconds(30)))
    }

    func testScheduledBreakDismissStartsFreshInterval() {
        var state = TimerState(configuration: short, now: origin)
        let deadline = origin + .seconds(30)

        state.handle(.deadlineReached, now: deadline)
        let dismiss = deadline + .seconds(2)
        state.handle(.dismissBreak, now: dismiss)
        XCTAssertEqual(state.phase, .work(deadline: dismiss + .seconds(30), warning: .none))
    }

    func testSuspendedFinalWarningReplaysFullWarning() {
        var state = TimerState(configuration: short, now: origin)
        let deadline = origin + .seconds(30)
        let unavailable = deadline - .seconds(1)

        state.handle(.screenUnavailable, now: unavailable)
        XCTAssertEqual(state.phase, .suspended)
        XCTAssertNil(state.nextDeadline)

        let available = unavailable + .seconds(30)
        state.handle(.screenAvailable, now: available)
        XCTAssertEqual(
            state.phase,
            .work(deadline: available + .seconds(3), warning: .finalCountdown)
        )
        XCTAssertEqual(state.nextDeadline, available + .seconds(3))
    }

    func testScreenUnavailableAtFinalWarningDueInstantReplaysFullWarning() {
        var state = TimerState(configuration: short, now: origin)
        let deadline = origin + .seconds(30)
        let unavailable = deadline - .seconds(3)

        state.handle(.screenUnavailable, now: unavailable)
        let available = unavailable + .seconds(60)
        state.handle(.screenAvailable, now: available)
        XCTAssertEqual(
            state.phase,
            .work(deadline: available + .seconds(3), warning: .finalCountdown)
        )
    }

    func testScreenUnavailableAtWorkDeadlineSuspendsBeforeSyntheticBreak() {
        let deadline = origin + .seconds(30)

        var state = TimerState(configuration: short, now: origin)
        state.handle(.screenUnavailable, now: deadline)
        XCTAssertEqual(state.phase, .suspended)

        state = TimerState(configuration: short, now: origin)
        state.handle(.screenUnavailable, now: deadline + .seconds(2))
        XCTAssertEqual(state.phase, .suspended)

        let available = deadline + .seconds(60)
        state.handle(.screenAvailable, now: available)
        XCTAssertEqual(
            state.phase,
            .work(deadline: available + .seconds(3), warning: .finalCountdown)
        )
    }

    func testSuspendedHeadsUpPreservesRemainingWork() {
        var state = TimerState(configuration: short, now: origin)
        let deadline = origin + .seconds(30)
        let unavailable = deadline - .seconds(15)

        state.handle(.screenUnavailable, now: unavailable)
        let available = unavailable + .seconds(5)
        state.handle(.screenAvailable, now: available)
        XCTAssertEqual(state.phase, .work(deadline: available + .seconds(15), warning: .none))
    }

    func testScreenUnavailableDuringBreakStartsFreshWorkOnReturn() {
        var state = TimerState(configuration: short, now: origin)
        let deadline = origin + .seconds(30)
        state.handle(.deadlineReached, now: deadline)

        let unavailable = deadline + .seconds(2)
        state.handle(.screenUnavailable, now: unavailable)
        XCTAssertEqual(state.phase, .suspended)

        let available = unavailable + .seconds(10)
        state.handle(.screenAvailable, now: available)
        XCTAssertEqual(state.phase, .work(deadline: available + .seconds(30), warning: .none))
    }

    func testRepeatedScreenUnavailableIsIgnored() {
        var state = TimerState(configuration: short, now: origin)
        state.handle(.screenUnavailable, now: origin + .seconds(1))
        state.handle(.screenUnavailable, now: origin + .seconds(2))
        XCTAssertEqual(state.phase, .suspended)
    }

    func testBlinkCheckInActivatesAtOffsetAndExpires() {
        var state = TimerState(configuration: checkInShort, now: origin)
        XCTAssertEqual(state.nextDeadline, origin + .seconds(5))

        state.handle(.deadlineReached, now: origin + .seconds(5))
        XCTAssertEqual(
            state.activeCheckIn,
            ActiveCheckIn(origin: .blink, expiresAt: origin + .seconds(7))
        )
        XCTAssertEqual(state.nextDeadline, origin + .seconds(7))

        state.handle(.deadlineReached, now: origin + .seconds(7))
        XCTAssertNil(state.activeCheckIn)
        XCTAssertEqual(state.phase, .work(deadline: origin + .seconds(30), warning: .none))
        XCTAssertEqual(state.nextDeadline, origin + .seconds(10))
    }

    func testPostureCheckInUsesItsOwnCadence() {
        var state = TimerState(configuration: checkInShort, now: origin)

        state.handle(.deadlineReached, now: origin + .seconds(5))
        state.handle(.deadlineReached, now: origin + .seconds(7))
        state.handle(.deadlineReached, now: origin + .seconds(10))

        XCTAssertEqual(
            state.activeCheckIn,
            ActiveCheckIn(origin: .posture, expiresAt: origin + .seconds(12))
        )
        XCTAssertEqual(state.nextDeadline, origin + .seconds(12))
    }

    func testDismissCheckInClearsPromptImmediately() {
        var state = TimerState(configuration: checkInShort, now: origin)
        state.handle(.deadlineReached, now: origin + .seconds(5))
        XCTAssertNotNil(state.activeCheckIn)

        state.handle(.dismissCheckIn, now: origin + .seconds(5))
        XCTAssertNil(state.activeCheckIn)
        XCTAssertEqual(state.nextDeadline, origin + .seconds(10))
    }

    func testCheckInSuppressedWhilePausedAndCadenceRestartsOnResume() {
        var state = TimerState(configuration: checkInShort, now: origin)
        state.handle(.pause, now: origin + .seconds(4))
        XCTAssertNil(state.activeCheckIn)
        XCTAssertNil(state.nextDeadline)

        state.handle(.deadlineReached, now: origin + .seconds(5))
        XCTAssertNil(state.activeCheckIn)
        XCTAssertEqual(state.phase, .paused(remaining: .seconds(26)))

        state.handle(.resume, now: origin + .seconds(100))
        XCTAssertNil(state.activeCheckIn)
        XCTAssertEqual(state.nextDeadline, origin + .seconds(105))
    }

    func testCheckInSuppressedDuringOnDemandBreak() {
        var state = TimerState(configuration: checkInShort, now: origin)
        state.handle(.takeBreakNow, now: origin + .seconds(4))
        XCTAssertNil(state.activeCheckIn)

        state.handle(.deadlineReached, now: origin + .seconds(5))
        XCTAssertNil(state.activeCheckIn)
        XCTAssertEqual(
            state.phase,
            .onBreak(deadline: origin + .seconds(10), origin: .onDemand)
        )
    }

    func testBreakWarningSuppressesCheckInAtSameInstant() {
        let configuration = TimerConfiguration(
            workInterval: .seconds(30),
            breakDuration: .seconds(6),
            snoozeInterval: .seconds(15),
            headsUpLead: .seconds(10),
            headsUpDuration: .seconds(2),
            finalWarningDuration: .seconds(3),
            checkInDuration: .seconds(2),
            blinkCheckInOffsets: [.seconds(20)],
            postureCheckInOffsets: []
        )
        var state = TimerState(configuration: configuration, now: origin)
        XCTAssertEqual(state.nextDeadline, origin + .seconds(20))

        state.handle(.deadlineReached, now: origin + .seconds(20))
        XCTAssertNil(state.activeCheckIn)
        XCTAssertEqual(
            state.phase,
            .work(deadline: origin + .seconds(30), warning: .headsUp)
        )
    }

    func testHeadsUpClearsActiveCheckIn() {
        let configuration = TimerConfiguration(
            workInterval: .seconds(30),
            breakDuration: .seconds(6),
            snoozeInterval: .seconds(15),
            headsUpLead: .seconds(10),
            headsUpDuration: .seconds(2),
            finalWarningDuration: .seconds(3),
            checkInDuration: .seconds(3),
            blinkCheckInOffsets: [.seconds(18)],
            postureCheckInOffsets: []
        )
        var state = TimerState(configuration: configuration, now: origin)
        state.handle(.deadlineReached, now: origin + .seconds(18))
        XCTAssertEqual(
            state.activeCheckIn,
            ActiveCheckIn(origin: .blink, expiresAt: origin + .seconds(21))
        )

        state.handle(.deadlineReached, now: origin + .seconds(20))
        XCTAssertNil(state.activeCheckIn)
        XCTAssertEqual(
            state.phase,
            .work(deadline: origin + .seconds(30), warning: .headsUp)
        )
    }

    func testDisabledReminderDoesNotPromptWhileOtherStillRuns() {
        let settings = CheckInSettings(blinkEnabled: false, postureEnabled: true)
        var state = TimerState(
            configuration: checkInShort,
            checkInSettings: settings,
            now: origin
        )
        XCTAssertEqual(state.nextDeadline, origin + .seconds(10))

        state.handle(.deadlineReached, now: origin + .seconds(10))
        XCTAssertEqual(state.activeCheckIn?.origin, .posture)

        state.handle(.deadlineReached, now: origin + .seconds(12))
        XCTAssertNil(state.activeCheckIn)
        state.handle(.deadlineReached, now: origin + .seconds(15))
        XCTAssertNil(state.activeCheckIn)
    }

    func testDisablingActiveReminderClearsPrompt() {
        var state = TimerState(configuration: checkInShort, now: origin)
        state.handle(.deadlineReached, now: origin + .seconds(5))
        XCTAssertEqual(state.activeCheckIn?.origin, .blink)

        state.handle(
            .updateCheckInSettings(CheckInSettings(blinkEnabled: false, postureEnabled: true)),
            now: origin + .seconds(5)
        )
        XCTAssertNil(state.activeCheckIn)
        XCTAssertEqual(state.nextDeadline, origin + .seconds(10))
    }

    func testEnablingReminderSchedulesOnlyFutureOffsets() {
        var state = TimerState(
            configuration: checkInShort,
            checkInSettings: CheckInSettings(blinkEnabled: false, postureEnabled: false),
            now: origin
        )
        state.handle(.deadlineReached, now: origin + .seconds(6))
        XCTAssertEqual(state.nextDeadline, origin + .seconds(20))

        state.handle(
            .updateCheckInSettings(.productDefault),
            now: origin + .seconds(6)
        )
        XCTAssertNil(state.activeCheckIn)
        XCTAssertEqual(state.nextDeadline, origin + .seconds(10))
    }

    func testScreenUnavailableSuppressesCheckInAndRestartsCadence() {
        var state = TimerState(configuration: checkInShort, now: origin)
        state.handle(.screenUnavailable, now: origin + .seconds(4))
        XCTAssertNil(state.activeCheckIn)
        XCTAssertNil(state.nextDeadline)

        state.handle(.deadlineReached, now: origin + .seconds(6))
        XCTAssertNil(state.activeCheckIn)
        XCTAssertEqual(state.phase, .suspended)

        state.handle(.screenAvailable, now: origin + .seconds(100))
        XCTAssertNil(state.activeCheckIn)
        XCTAssertEqual(
            state.phase,
            .work(deadline: origin + .seconds(126), warning: .none)
        )
        XCTAssertEqual(state.nextDeadline, origin + .seconds(105))
    }
}
