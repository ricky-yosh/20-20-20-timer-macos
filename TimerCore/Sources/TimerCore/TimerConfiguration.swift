public struct TimerConfiguration: Sendable, Equatable {
    public var workInterval: Duration
    public var breakDuration: Duration
    public var snoozeInterval: Duration
    public var headsUpLead: Duration
    public var headsUpDuration: Duration
    public var finalWarningDuration: Duration
    public var checkInDuration: Duration
    public var blinkCheckInOffsets: [Duration]
    public var postureCheckInOffsets: [Duration]

    public init(
        workInterval: Duration = .seconds(20 * 60),
        breakDuration: Duration = .seconds(20),
        snoozeInterval: Duration = .seconds(5 * 60),
        headsUpLead: Duration = .seconds(60),
        headsUpDuration: Duration = .seconds(8),
        finalWarningDuration: Duration = .seconds(5),
        checkInDuration: Duration = .seconds(4),
        blinkCheckInOffsets: [Duration] = [.seconds(5 * 60), .seconds(15 * 60)],
        postureCheckInOffsets: [Duration] = [.seconds(10 * 60)]
    ) {
        self.workInterval = workInterval
        self.breakDuration = breakDuration
        self.snoozeInterval = snoozeInterval
        self.headsUpLead = headsUpLead
        self.headsUpDuration = headsUpDuration
        self.finalWarningDuration = finalWarningDuration
        self.checkInDuration = checkInDuration
        self.blinkCheckInOffsets = blinkCheckInOffsets
        self.postureCheckInOffsets = postureCheckInOffsets
    }

    public static let productDefault = TimerConfiguration()
}
