import XCTest

final class PickerInputRoutingPolicyTests: XCTestCase {
    func testReplayEventCodecPreservesFenceGeneration() {
        let generation: UInt64 = 0x1234_5678_9abc
        let encoded = PickerInputRoutingPolicy.replayedKeyEventUserData(
            generation: generation
        )

        XCTAssertEqual(
            PickerInputRoutingPolicy.replayedKeyEventGeneration(from: encoded),
            generation
        )
        XCTAssertNil(PickerInputRoutingPolicy.replayedKeyEventGeneration(from: 0))
    }

    func testReplaySentinelIsDistinctFromReplayedKey() {
        let generation: UInt64 = 42
        let replayed = PickerInputRoutingPolicy.replayedKeyEventUserData(
            generation: generation
        )
        let sentinel = PickerInputRoutingPolicy.replaySentinelUserData(
            generation: generation
        )

        XCTAssertEqual(
            PickerInputRoutingPolicy.replaySentinelGeneration(from: sentinel),
            generation
        )
        XCTAssertNil(PickerInputRoutingPolicy.replayedKeyEventGeneration(from: sentinel))
        XCTAssertNil(PickerInputRoutingPolicy.replaySentinelGeneration(from: replayed))
    }
}
