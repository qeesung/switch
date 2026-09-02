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

    mutating func itemCount(unfilteredCount: Int, isFiltering: Bool) -> Int {
        let count = max(unfilteredCount, 0)
        if !isFiltering || unfilteredItemCount == 0 {
            // If enumeration completes after the user starts typing, establish
            // the missing baseline once; later match-count changes stay stable.
            unfilteredItemCount = count
        }
        return unfilteredItemCount
    }
}

struct SwitcherPanelLayoutResult: Equatable {
    let size: CGSize
    let visibleRows: Int
}

struct SwitcherAdaptiveGridGeometry: Equatable {
    let columns: Int
    let thumbnailHeight: CGFloat
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
    static let gridHorizontalPadding: CGFloat = 44
    static let gridColumnSpacing: CGFloat = 14
    static let gridThumbnailAspectRatio: CGFloat = 1.55
    static let maximumAdaptiveThumbnailScale: CGFloat = 3

    static func effectiveGridColumns(itemCount: Int, configuredColumns: Int) -> Int {
        min(max(configuredColumns, 1), max(itemCount, 1))
    }

    /// Keeps the panel still while a filter changes the result count, then spends
    /// the freed columns on a larger preview. All dimensions passed here are the
    /// already-scaled values used by the current picker-size preset.
    static func adaptiveGrid(
        panelWidth: CGFloat,
        itemCount: Int,
        configuredColumns: Int,
        baseThumbnailHeight: CGFloat,
        compactThumbnailHeight: CGFloat,
        showsThumbnails: Bool,
        visualScale: CGFloat,
        verticalCapacity: CGFloat
    ) -> SwitcherAdaptiveGridGeometry {
        precondition(panelWidth > 0)
        precondition(baseThumbnailHeight > 0)
        precondition(compactThumbnailHeight > 0)
        precondition(visualScale > 0)

        let columns = effectiveGridColumns(
            itemCount: itemCount,
            configuredColumns: configuredColumns
        )
        let capacity = max(verticalCapacity, 1)
        guard showsThumbnails else {
            return SwitcherAdaptiveGridGeometry(
                columns: columns,
                thumbnailHeight: min(compactThumbnailHeight, capacity)
            )
        }

        let fittedBaseHeight = min(baseThumbnailHeight, capacity)
        let configured = max(configuredColumns, 1)
        guard itemCount > 0, columns < configured else {
            return SwitcherAdaptiveGridGeometry(
                columns: columns,
                thumbnailHeight: fittedBaseHeight
            )
        }

        let padding = gridHorizontalPadding * visualScale
        let spacing = gridColumnSpacing * visualScale
        let availableWidth = max(
            panelWidth - padding - CGFloat(max(columns - 1, 0)) * spacing,
            1
        )
        let columnWidth = availableWidth / CGFloat(columns)
        let idealHeight = columnWidth / gridThumbnailAspectRatio
        let maximumHeight = min(
            baseThumbnailHeight * maximumAdaptiveThumbnailScale,
            capacity
        )
        let thumbnailHeight = max(
            fittedBaseHeight,
            min(idealHeight, maximumHeight)
        )

        return SwitcherAdaptiveGridGeometry(
            columns: columns,
            thumbnailHeight: thumbnailHeight
        )
    }

    static func list(
        width: CGFloat,
        itemCount: Int,
        maxRows: Int,
        rowHeight: CGFloat,
        headerHeight: CGFloat,
        hintHeight: CGFloat,
        showsHeader: Bool,
        heightLimit: CGFloat?,
        visualScale: CGFloat = 1
    ) -> SwitcherPanelLayoutResult {
        precondition(width > 0)
        precondition(rowHeight > 0)
        precondition(visualScale > 0)

        let effectiveCount = max(itemCount, 1)
        let rowLimit = max(maxRows, 1)
        let spacing = listRowSpacing * visualScale
        let topPadding = (showsHeader ? listTopPaddingWithHeader : listTopPaddingWithoutHeader) * visualScale
        let chrome = max(headerHeight, 0) + topPadding
            + listBottomPadding * visualScale + max(hintHeight, 0)

        let rowsFitting: Int
        if let heightLimit, heightLimit.isFinite {
            let raw = floor((heightLimit - chrome + spacing) / (rowHeight + spacing))
            rowsFitting = max(Int(raw), 1)
        } else {
            rowsFitting = rowLimit
        }

        let visibleRows = max(1, min(effectiveCount, rowLimit, rowsFitting))
        let gaps = CGFloat(max(visibleRows - 1, 0)) * spacing
        let exactHeight = chrome + CGFloat(visibleRows) * rowHeight + gaps

        // A minimum looks better for an empty or short list. Do not apply it when more
        // rows are scrollable: surplus viewport height would reveal a clipped next row.
        let hasOverflow = effectiveCount > visibleRows
        var height = hasOverflow ? exactHeight : max(minimumPanelHeight * visualScale, exactHeight)
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
        targetWidth: CGFloat,
        targetHeight: CGFloat,
        itemCount: Int,
        configuredColumns: Int,
        widthLimit: CGFloat?,
        heightLimit: CGFloat?
    ) -> SwitcherPanelLayoutResult {
        precondition(targetWidth > 0)
        precondition(targetHeight > 0)

        let columns = effectiveGridColumns(
            itemCount: itemCount,
            configuredColumns: configuredColumns
        )
        let rows = Int(ceil(Double(max(itemCount, 1)) / Double(columns)))
        let width = widthLimit.map { $0.isFinite ? min(targetWidth, $0) : targetWidth }
            ?? targetWidth
        let height = heightLimit.map { $0.isFinite ? min(targetHeight, $0) : targetHeight }
            ?? targetHeight

        return SwitcherPanelLayoutResult(
            size: CGSize(width: max(width, 1), height: max(height, 1)),
            visibleRows: rows
        )
    }
}
