import CoreGraphics
import XCTest
@testable import Switch

final class WindowSearchIndexTests: XCTestCase {
    func testFullPinyinMatchesChineseApplicationName() {
        var index = WindowSearchIndex()
        let windows = [window(id: 1, appName: "飞书", title: "消息")]
        index.synchronize(with: windows)

        XCTAssertEqual(index.filtered(windows, query: "feishu").map(\.id), [1])
    }

    func testFullPinyinMatchesChineseWindowTitle() {
        var index = WindowSearchIndex()
        let windows = [window(id: 1, appName: "Lark", title: "飞书会议")]
        index.synchronize(with: windows)

        XCTAssertEqual(index.filtered(windows, query: "feishuhuiyi").map(\.id), [1])
    }

    func testChineseAndEnglishDirectMatchingStillWork() {
        var index = WindowSearchIndex()
        let windows = [
            window(id: 1, appName: "飞书", title: "聊天"),
            window(id: 2, appName: "Safari", title: "Switch")
        ]
        index.synchronize(with: windows)

        XCTAssertEqual(index.filtered(windows, query: "飞书").map(\.id), [1])
        XCTAssertEqual(index.filtered(windows, query: "saf").map(\.id), [2])
        XCTAssertTrue(index.filtered(windows, query: "nomatch").isEmpty)
    }

    func testDirectMatchRanksAheadOfPinyinOnlyMatch() {
        var index = WindowSearchIndex()
        let windows = [
            window(id: 1, appName: "飞书", title: ""),
            window(id: 2, appName: "Feishu Helper", title: "")
        ]
        index.synchronize(with: windows)

        XCTAssertEqual(index.filtered(windows, query: "feishu").map(\.id), [2, 1])
    }

    func testEqualScoresKeepInputMRUOrder() {
        var index = WindowSearchIndex()
        let windows = [
            window(id: 7, appName: "飞书", title: "一"),
            window(id: 3, appName: "飞书", title: "二")
        ]
        index.synchronize(with: windows)

        XCTAssertEqual(index.filtered(windows, query: "feishu").map(\.id), [7, 3])
    }

    func testChangedTitlesRebuildAndMissingWindowsPurgeCachedEntries() {
        var index = WindowSearchIndex()
        let initial = [
            window(id: 1, appName: "Lark", title: "飞书会议"),
            window(id: 2, appName: "Safari", title: "Docs")
        ]
        index.synchronize(with: initial)
        XCTAssertEqual(index.cachedEntryCount, 2)

        let updated = [window(id: 1, appName: "Lark", title: "微信会议")]
        index.synchronize(with: updated)

        XCTAssertEqual(index.cachedEntryCount, 1)
        XCTAssertTrue(index.filtered(updated, query: "feishu").isEmpty)
        XCTAssertEqual(index.filtered(updated, query: "weixin").map(\.id), [1])
    }

    private func window(id: CGWindowID, appName: String, title: String) -> WindowInfo {
        WindowInfo(id: id, pid: pid_t(id), appName: appName, bounds: .zero, title: title)
    }
}
