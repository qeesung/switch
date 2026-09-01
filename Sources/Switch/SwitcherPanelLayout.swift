import CoreGraphics

/// Heights reported by the laid-out SwiftUI picker. Zero means that a component is
/// temporarily absent (for example, rows while a filter has no matches), not zero tall.
struct PanelMetrics: Equatable {
    var rowHeight: CGFloat = 0
    var tileHeight: CGFloat = 0
    var hintHeight: CGFloat = 0
    var headerHeight: CGFloat = 0

    mutating func merge(_ other: PanelMetrics) {
        rowHeight = max(rowHeight, other.rowHeight)
        tileHeight = max(tileHeight, other.tileHeight)
        hintHeight = max(hintHeight, other.hintHeight)
        headerHeight = max(headerHeight, other.headerHeight)
    }

    mutating func mergeKnown(_ other: PanelMetrics) {
        if other.rowHeight > 0 { rowHeight = other.rowHeight }
        if other.tileHeight > 0 { tileHeight = other.tileHeight }
        if other.hintHeight > 0 { hintHeight = other.hintHeight }
        if other.headerHeight > 0 { headerHeight = other.headerHeight }
    }
}

/// Holds the item count from the unfiltered picker. A transient match count must not
/// make the panel jump on every keystroke or leave it small after the filter is cleared.
struct PanelSizingSession: Equatable {
    private(set) var unfilteredItemCount = 0

    mutating func itemCount(currentCount: Int, isFiltering: Bool) -> Int {
        if !isFiltering {
            unfilteredItemCount = max(currentCount, 0)
        }
        return unfilteredItemCount
    }
}

struct SwitcherPanelLayoutResult: Equatable {
    let size: CGSize
    let visibleRows: Int
}

/// Pure panel-size arithmetic. AppKit supplies measured/fallback component heights;
/// this type is responsible only for row fitting and exact panel geometry.
enum SwitcherPanelLayout {
    static let screenFraction: CGFloat = 0.92
    static let listRowSpacing: CGFloat = 4
    static let listTopPaddingWithHeader: CGFloat = 10
    static let listTopPaddingWithoutHeader: CGFloat = 14
    static let listBottomPadding: CGFloat = 10
    static let minimumPanelHeight: CGFloat = 260

    static func list(
        width: CGFloat,
        itemCount: Int,
        maxRows: Int,
        rowHeight: CGFloat,
        headerHeight: CGFloat,
        hintHeight: CGFloat,
        showsHeader: Bool,
        heightLimit: CGFloat?
    ) -> SwitcherPanelLayoutResult {
        precondition(width > 0)
        precondition(rowHeight > 0)

        let effectiveCount = max(itemCount, 1)
        let rowLimit = max(maxRows, 1)
        let topPadding = showsHeader ? listTopPaddingWithHeader : listTopPaddingWithoutHeader
        let chrome = max(headerHeight, 0) + topPadding + listBottomPadding + max(hintHeight, 0)

        let rowsFitting: Int
        if let heightLimit, heightLimit.isFinite {
            let raw = floor((heightLimit - chrome + listRowSpacing) / (rowHeight + listRowSpacing))
            rowsFitting = max(Int(raw), 1)
        } else {
            rowsFitting = rowLimit
        }

        let visibleRows = max(1, min(effectiveCount, rowLimit, rowsFitting))
        let gaps = CGFloat(max(visibleRows - 1, 0)) * listRowSpacing
        let exactHeight = chrome + CGFloat(visibleRows) * rowHeight + gaps

        // A minimum looks better for an empty or short list. Do not apply it when more
        // rows are scrollable: surplus viewport height would reveal a clipped next row.
        let hasOverflow = effectiveCount > visibleRows
        var height = hasOverflow ? exactHeight : max(minimumPanelHeight, exactHeight)
        if let heightLimit, heightLimit.isFinite, !hasOverflow {
            // Never shrink below the exact one-row geometry, even on an unusually short
            // display; clipping a row is worse than exceeding the preferred 92% bound.
            height = max(exactHeight, min(height, heightLimit))
        }

        return SwitcherPanelLayoutResult(
            size: CGSize(width: width, height: height),
            visibleRows: visibleRows
        )
    }

    static func grid(
        baseWidth: CGFloat,
        minimumWidth: CGFloat,
        itemCount: Int,
        configuredColumns: Int,
        tileHeight: CGFloat,
        headerHeight: CGFloat,
        hintHeight: CGFloat,
        heightLimit: CGFloat?
    ) -> SwitcherPanelLayoutResult {
        precondition(baseWidth > 0)
        precondition(tileHeight > 0)

        let count = max(itemCount, 1)
        let configured = max(configuredColumns, 1)
        let columns = min(configured, max(count, 3))
        let horizontalPadding: CGFloat = 44
        let columnSpacing: CGFloat = 14
        let usable = baseWidth - horizontalPadding - CGFloat(max(configured - 1, 0)) * columnSpacing
        let columnWidth = usable / CGFloat(configured)
        let width = horizontalPadding
            + CGFloat(columns) * columnWidth
            + CGFloat(max(columns - 1, 0)) * columnSpacing

        let rows = Int(ceil(Double(count) / Double(columns)))
        let rowSpacing: CGFloat = 14
        let rowsHeight = CGFloat(rows) * tileHeight + CGFloat(max(rows - 1, 0)) * rowSpacing
        let contentHeight = max(headerHeight, 0) + 16 + rowsHeight + max(hintHeight, 0)
        var height = max(320, contentHeight)
        if let heightLimit, heightLimit.isFinite {
            height = min(height, heightLimit)
        }

        return SwitcherPanelLayoutResult(
            size: CGSize(width: max(minimumWidth, width), height: height),
            visibleRows: rows
        )
    }
}
