import CoreGraphics
import XCTest

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
        XCTAssertEqual(index.cachedEntryCount, 4)

        let updated = [window(id: 1, appName: "Lark", title: "微信会议")]
        index.synchronize(with: updated)

        XCTAssertEqual(index.cachedEntryCount, 2)
        XCTAssertTrue(index.filtered(updated, query: "feishu").isEmpty)
        XCTAssertEqual(index.filtered(updated, query: "weixin").map(\.id), [1])
    }

    func testCompositeIdentityPreventsSyntheticIDCollisionFromSharingText() {
        var index = WindowSearchIndex()
        let real = window(id: 42, pid: 7, appName: "飞书", title: "消息")
        let synthetic = window(
            id: 42,
            pid: 7,
            appName: "微信",
            title: "",
            isWindowless: true
        )
        let windows = [real, synthetic]
        index.synchronize(with: windows)

        XCTAssertEqual(index.cachedEntryCount, 4)
        XCTAssertEqual(index.filtered(windows, query: "feishu").map(\.appName), ["飞书"])
        XCTAssertEqual(index.filtered(windows, query: "weixin").map(\.appName), ["微信"])
    }

    func testPunctuationAndWhitespaceQueriesKeepOriginalLiteralSemantics() {
        var index = WindowSearchIndex()
        let windows = [window(id: 1, appName: "FooBar", title: "")]
        index.synchronize(with: windows)

        XCTAssertTrue(index.filtered(windows, query: "foo.bar").isEmpty)
        XCTAssertTrue(index.filtered(windows, query: "foo-bar").isEmpty)
        XCTAssertTrue(index.filtered(windows, query: "foo bar").isEmpty)
    }

    func testPinyinFallbackDoesNotBroadenLatinDiacriticMatching() {
        var index = WindowSearchIndex()
        let windows = [window(id: 1, appName: "Résumé", title: "")]
        index.synchronize(with: windows)

        XCTAssertTrue(index.filtered(windows, query: "resume").isEmpty)
        XCTAssertEqual(index.filtered(windows, query: "résumé").map(\.id), [1])
    }

    private func window(
        id: CGWindowID,
        pid: pid_t? = nil,
        appName: String,
        title: String,
        isWindowless: Bool = false
    ) -> WindowInfo {
        WindowInfo(
            id: id,
            pid: pid ?? pid_t(id),
            appName: appName,
            bounds: .zero,
            title: title,
            isWindowless: isWindowless
        )
    }
}
