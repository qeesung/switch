/// Encodes the event-tap markers used to replay keys after picker dismissal.
enum PickerInputRoutingPolicy {
    private static let replayedEventMagic: UInt64 = 0x5250
    private static let replaySentinelMagic: UInt64 = 0x5251
    private static let replayedEventMagicShift: UInt64 = 48
    private static let replayedEventGenerationMask: UInt64 = 0x0000_ffff_ffff_ffff

    /// Tags a replay with the fence that originally buffered it. A replayed
    /// hotkey can create a newer fence; remaining events from the old batch must
    /// then be buffered by that new fence instead of bypassing it.
    static func replayedKeyEventUserData(generation: UInt64) -> Int64 {
        let encoded = (replayedEventMagic << replayedEventMagicShift)
            | (generation & replayedEventGenerationMask)
        return Int64(bitPattern: encoded)
    }

    static func replayedKeyEventGeneration(from userData: Int64) -> UInt64? {
        let encoded = UInt64(bitPattern: userData)
        guard encoded >> replayedEventMagicShift == replayedEventMagic else { return nil }
        return encoded & replayedEventGenerationMask
    }

    static func replaySentinelUserData(generation: UInt64) -> Int64 {
        let encoded = (replaySentinelMagic << replayedEventMagicShift)
            | (generation & replayedEventGenerationMask)
        return Int64(bitPattern: encoded)
    }

    static func replaySentinelGeneration(from userData: Int64) -> UInt64? {
        let encoded = UInt64(bitPattern: userData)
        guard encoded >> replayedEventMagicShift == replaySentinelMagic else { return nil }
        return encoded & replayedEventGenerationMask
    }
}
