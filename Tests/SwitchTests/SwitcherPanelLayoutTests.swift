import CoreGraphics
import XCTest

final class SwitcherPanelLayoutTests: XCTestCase {
    func testMetricsReduceByMaximum() {
        var metrics = PanelMetrics(rowHeight: 48, tileHeight: 100, hintHeight: 0, headerHeight: 36)
        metrics.merge(PanelMetrics(rowHeight: 62, tileHeight: 80, hintHeight: 34, headerHeight: 0))

        XCTAssertEqual(metrics, PanelMetrics(rowHeight: 62, tileHeight: 100, hintHeight: 34, headerHeight: 36))
    }

    func testMetricsKeepKnownValuesWhenComponentTemporarilyDisappears() {
        var metrics = PanelMetrics(rowHeight: 62, tileHeight: 182, hintHeight: 34, headerHeight: 36)
        metrics.mergeKnown(PanelMetrics())
        XCTAssertEqual(metrics, PanelMetrics(rowHeight: 62, tileHeight: 182, hintHeight: 34, headerHeight: 36))

        metrics.mergeKnown(PanelMetrics(rowHeight: 48, tileHeight: 0, hintHeight: 30, headerHeight: 0))
        XCTAssertEqual(metrics, PanelMetrics(rowHeight: 48, tileHeight: 182, hintHeight: 30, headerHeight: 36))
    }

    func testSizingSessionKeepsUnfilteredCountWhileTypingAndMatchingNothing() {
        var session = PanelSizingSession()
        XCTAssertEqual(session.itemCount(unfilteredCount: 12, isFiltering: false), 12)
        XCTAssertEqual(session.itemCount(unfilteredCount: 12, isFiltering: true), 12)
        XCTAssertEqual(session.itemCount(unfilteredCount: 12, isFiltering: true), 12)
        XCTAssertEqual(session.unfilteredItemCount, 12)
    }

    func testSizingSessionRefreshesFullCountAfterFilterIsCleared() {
        var session = PanelSizingSession()
        _ = session.itemCount(unfilteredCount: 12, isFiltering: false)
        _ = session.itemCount(unfilteredCount: 12, isFiltering: true)

        XCTAssertEqual(session.itemCount(unfilteredCount: 12, isFiltering: false), 12)
        XCTAssertEqual(session.itemCount(unfilteredCount: 9, isFiltering: false), 9)
    }

    func testSizingSessionLearnsAsyncWindowCountAfterFilteringStarts() {
        var session = PanelSizingSession()
        XCTAssertEqual(session.itemCount(unfilteredCount: 0, isFiltering: false), 0)
        XCTAssertEqual(session.itemCount(unfilteredCount: 0, isFiltering: true), 0)
        XCTAssertEqual(session.itemCount(unfilteredCount: 20, isFiltering: true), 20)
        XCTAssertEqual(session.itemCount(unfilteredCount: 24, isFiltering: true), 20)
    }

    func testListUsesConfiguredWidthAndMaximumRows() {
        let result = SwitcherPanelLayout.list(
            width: 700,
            itemCount: 12,
            maxRows: 8,
            rowHeight: 62,
            headerHeight: 36,
            hintHeight: 34,
            showsHeader: true,
            heightLimit: nil
        )

        XCTAssertEqual(result.visibleRows, 8)
        XCTAssertEqual(result.size.width, 700)
        XCTAssertEqual(result.size.height, 614)
    }

    func testListFloorsScreenLimitToWholeRows() {
        let result = SwitcherPanelLayout.list(
            width: 520,
            itemCount: 20,
            maxRows: 20,
            rowHeight: 62,
            headerHeight: 36,
            hintHeight: 34,
            showsHeader: true,
            heightLimit: 450
        )

        XCTAssertEqual(result.visibleRows, 5)
        XCTAssertEqual(result.size.height, 416)
        let chrome: CGFloat = 36 + 10 + 10 + 34
        let reconstructedRows = (result.size.height - chrome + 4) / (62 + 4)
        XCTAssertEqual(reconstructedRows, 5)
    }

    func testOverflowingCompactListDoesNotAddMinimumHeightSliver() {
        let result = SwitcherPanelLayout.list(
            width: 420,
            itemCount: 10,
            maxRows: 4,
            rowHeight: 48,
            headerHeight: 0,
            hintHeight: 0,
            showsHeader: false,
            heightLimit: nil
        )

        XCTAssertEqual(result.visibleRows, 4)
        XCTAssertEqual(result.size.height, 228)
    }

    func testShortListMayUseMinimumHeightBecauseNothingCanBeClipped() {
        let result = SwitcherPanelLayout.list(
            width: 520,
            itemCount: 2,
            maxRows: 8,
            rowHeight: 48,
            headerHeight: 0,
            hintHeight: 0,
            showsHeader: false,
            heightLimit: nil
        )

        XCTAssertEqual(result.visibleRows, 2)
        XCTAssertEqual(result.size.height, 260)
    }

    func testHeaderGeometryMatchesRenderedTopPadding() {
        let withHeader = SwitcherPanelLayout.list(
            width: 520,
            itemCount: 8,
            maxRows: 8,
            rowHeight: 62,
            headerHeight: 36,
            hintHeight: 34,
            showsHeader: true,
            heightLimit: nil
        )
        let withoutHeader = SwitcherPanelLayout.list(
            width: 520,
            itemCount: 8,
            maxRows: 8,
            rowHeight: 62,
            headerHeight: 0,
            hintHeight: 34,
            showsHeader: false,
            heightLimit: nil
        )

        XCTAssertEqual(withHeader.size.height - withoutHeader.size.height, 32)
    }

    func testEmptyListStillGetsOneRowOfLayoutAndMinimumPanel() {
        let result = SwitcherPanelLayout.list(
            width: 520,
            itemCount: 0,
            maxRows: 8,
            rowHeight: 62,
            headerHeight: 36,
            hintHeight: 34,
            showsHeader: true,
            heightLimit: nil
        )

        XCTAssertEqual(result.visibleRows, 1)
        XCTAssertEqual(result.size.height, 260)
    }

    func testGridUsesMeasuredTileGeometry() {
        let result = SwitcherPanelLayout.grid(
            baseWidth: 880,
            minimumWidth: 560,
            itemCount: 2,
            configuredColumns: 4,
            tileHeight: 182,
            headerHeight: 36,
            hintHeight: 34,
            heightLimit: nil
        )

        XCTAssertEqual(result.visibleRows, 1)
        XCTAssertEqual(result.size.width, 667.5)
        XCTAssertEqual(result.size.height, 320)
    }

    func testGridHonorsHeightLimit() {
        let result = SwitcherPanelLayout.grid(
            baseWidth: 880,
            minimumWidth: 560,
            itemCount: 12,
            configuredColumns: 4,
            tileHeight: 182,
            headerHeight: 36,
            hintHeight: 34,
            heightLimit: 560
        )

        XCTAssertEqual(result.visibleRows, 3)
        XCTAssertEqual(result.size.width, 880)
        XCTAssertEqual(result.size.height, 560)
    }
}
