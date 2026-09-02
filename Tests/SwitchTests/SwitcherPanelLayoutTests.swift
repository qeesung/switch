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

    func testGridFrameStaysFixedAcrossCandidateCounts() {
        let short = SwitcherPanelLayout.grid(
            targetWidth: 880,
            targetHeight: 560,
            itemCount: 2,
            configuredColumns: 4,
            widthLimit: nil,
            heightLimit: nil
        )
        let long = SwitcherPanelLayout.grid(
            targetWidth: 880,
            targetHeight: 560,
            itemCount: 12,
            configuredColumns: 4,
            widthLimit: nil,
            heightLimit: nil
        )

        XCTAssertEqual(short.size, CGSize(width: 880, height: 560))
        XCTAssertEqual(long.size, short.size)
        XCTAssertEqual(short.visibleRows, 1)
        XCTAssertEqual(long.visibleRows, 3)
    }

    func testGridHonorsScreenLimits() {
        let result = SwitcherPanelLayout.grid(
            targetWidth: 1_056,
            targetHeight: 672,
            itemCount: 12,
            configuredColumns: 4,
            widthLimit: 900,
            heightLimit: 600
        )

        XCTAssertEqual(result.size, CGSize(width: 900, height: 600))
    }

    func testEffectiveGridColumnsTreatsConfiguredColumnsAsMaximum() {
        XCTAssertEqual(SwitcherPanelLayout.effectiveGridColumns(itemCount: 0, configuredColumns: 4), 1)
        XCTAssertEqual(SwitcherPanelLayout.effectiveGridColumns(itemCount: 1, configuredColumns: 4), 1)
        XCTAssertEqual(SwitcherPanelLayout.effectiveGridColumns(itemCount: 2, configuredColumns: 4), 2)
        XCTAssertEqual(SwitcherPanelLayout.effectiveGridColumns(itemCount: 3, configuredColumns: 4), 3)
        XCTAssertEqual(SwitcherPanelLayout.effectiveGridColumns(itemCount: 4, configuredColumns: 4), 4)
        XCTAssertEqual(SwitcherPanelLayout.effectiveGridColumns(itemCount: 5, configuredColumns: 4), 4)
        XCTAssertEqual(SwitcherPanelLayout.effectiveGridColumns(itemCount: 5, configuredColumns: 6), 5)
    }

    func testAdaptiveGridEnlargesThumbnailsAsCandidatesDisappear() {
        let heights = (1...4).map { count in
            SwitcherPanelLayout.adaptiveGrid(
                panelWidth: 880,
                itemCount: count,
                configuredColumns: 4,
                baseThumbnailHeight: 130,
                compactThumbnailHeight: 72,
                showsThumbnails: true,
                visualScale: 1,
                verticalCapacity: 500
            ).thumbnailHeight
        }

        XCTAssertEqual(heights[0], 390, accuracy: 0.001)
        XCTAssertEqual(heights[1], 411 / 1.55, accuracy: 0.001)
        XCTAssertEqual(heights[2], (808 / 3) / 1.55, accuracy: 0.001)
        XCTAssertEqual(heights[3], 130, accuracy: 0.001)
        XCTAssertGreaterThan(heights[0], heights[1])
        XCTAssertGreaterThan(heights[1], heights[2])
        XCTAssertGreaterThan(heights[2], heights[3])
    }

    func testAdaptiveGridScalesGeometryForLargePreset() {
        let result = SwitcherPanelLayout.adaptiveGrid(
            panelWidth: 1_056,
            itemCount: 2,
            configuredColumns: 4,
            baseThumbnailHeight: 156,
            compactThumbnailHeight: 86.4,
            showsThumbnails: true,
            visualScale: 1.2,
            verticalCapacity: 560
        )

        XCTAssertEqual(result.columns, 2)
        XCTAssertEqual(result.thumbnailHeight, 493.2 / 1.55, accuracy: 0.001)
    }

    func testAdaptiveGridCapsThumbnailAtVerticalCapacity() {
        let result = SwitcherPanelLayout.adaptiveGrid(
            panelWidth: 880,
            itemCount: 1,
            configuredColumns: 4,
            baseThumbnailHeight: 130,
            compactThumbnailHeight: 72,
            showsThumbnails: true,
            visualScale: 1,
            verticalCapacity: 250
        )

        XCTAssertEqual(result.thumbnailHeight, 250)
    }

    func testAdaptiveGridShrinksConfiguredBaseOnAnExtremelyShortScreen() {
        let result = SwitcherPanelLayout.adaptiveGrid(
            panelWidth: 880,
            itemCount: 4,
            configuredColumns: 4,
            baseThumbnailHeight: 130,
            compactThumbnailHeight: 72,
            showsThumbnails: true,
            visualScale: 1,
            verticalCapacity: 100
        )

        XCTAssertEqual(result.thumbnailHeight, 100)
    }

    func testAdaptiveGridKeepsCompactHeightWithoutThumbnails() {
        let result = SwitcherPanelLayout.adaptiveGrid(
            panelWidth: 1_056,
            itemCount: 1,
            configuredColumns: 4,
            baseThumbnailHeight: 156,
            compactThumbnailHeight: 86.4,
            showsThumbnails: false,
            visualScale: 1.2,
            verticalCapacity: 560
        )

        XCTAssertEqual(result.columns, 1)
        XCTAssertEqual(result.thumbnailHeight, 86.4, accuracy: 0.001)
    }
}
