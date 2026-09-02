import SwiftUI

struct SwitchView: View {
    @EnvironmentObject var model: SwitchModel
    @ObservedObject private var prefs = SwitchPreferences.shared
    @Namespace private var selectionNS
    @State private var hoveredID: CGWindowID?
    @State private var openMouseLocation: CGPoint = .zero
    @State private var hasMouseMovedSinceOpen = false
    @State private var lastSelectionFromMouse = false

    private var visualScale: CGFloat { prefs.pickerSize.scale }
    private func scaled(_ value: CGFloat) -> CGFloat { value * visualScale }
    private var scaledAppIconSize: CGFloat { CGFloat(prefs.appIconSize) * visualScale }

    private func handleHover(_ isHovering: Bool, windowID: CGWindowID, index: Int) {
        guard !prefs.disableMouse else { return }
        if isHovering {
            model.pointerWindowID = windowID
        } else if model.pointerWindowID == windowID {
            model.pointerWindowID = nil
        }
        if isHovering {
            // Ignore hover until cursor has actually moved 10pt+ since panel opened.
            // Otherwise a static cursor parked over a tile hijacks the default selection.
            if !hasMouseMovedSinceOpen {
                let loc = NSEvent.mouseLocation
                let dx = loc.x - openMouseLocation.x
                let dy = loc.y - openMouseLocation.y
                if hypot(dx, dy) < 10 { return }
                hasMouseMovedSinceOpen = true
            }
            hoveredID = windowID
            if model.selected != index {
                lastSelectionFromMouse = true
                model.selected = index
            }
        } else if hoveredID == windowID {
            hoveredID = nil
        }
    }

    private func handleTap(index: Int) {
        guard !prefs.disableMouse else { return }
        lastSelectionFromMouse = true
        model.selected = index
        model.commitAndDismiss?()
    }

    private func isPinned(_ window: WindowInfo) -> Bool {
        window.bundleID.map { prefs.pinnedBundleIDs.contains($0) } ?? false
    }

    @ViewBuilder
    private func windowBadge(for window: WindowInfo) -> some View {
        if window.isMinimized || window.isHidden || window.isCrossSpace || window.isWindowless {
            capsuleBadge(windowBadgeText(for: window))
        }
    }

    private func capsuleBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: scaled(9), weight: .semibold))
            .tracking(scaled(0.5))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, scaled(6))
            .padding(.vertical, scaled(3))
            .background(Color.black.opacity(0.55))
            .clipShape(Capsule())
    }

    @ViewBuilder
    private func numberHint(index: Int) -> some View {
        if prefs.showNumberKeyHints && !isSpaceMode && index < 9 {
            Text(verbatim: String(index + 1))
                .font(.system(size: scaled(10), weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: scaled(16), height: scaled(16))
                .background(Color.black.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: scaled(4), style: .continuous))
        }
    }

    private func highlightedSearchText(
        _ value: String,
        match: WindowSearchIndex.TextMatch?,
        size: CGFloat,
        weight: Font.Weight,
        baseColor: Color
    ) -> Text {
        guard let match, !match.characterOffsets.isEmpty else {
            return Text(verbatim: value)
                .font(.system(size: size, weight: weight))
                .foregroundColor(baseColor)
        }

        var output = AttributedString(value)
        output.foregroundColor = baseColor
        let characterIndices = Array(output.characters.indices)
        for matchedRange in match.characterOffsets.rangeView {
            guard matchedRange.lowerBound < characterIndices.count else { continue }
            let lowerBound = characterIndices[matchedRange.lowerBound]
            let upperBound = matchedRange.upperBound < characterIndices.count
                ? characterIndices[matchedRange.upperBound]
                : output.endIndex
            output[lowerBound..<upperBound].foregroundColor = prefs.accent.color
            output[lowerBound..<upperBound].backgroundColor = prefs.accent.color.opacity(0.20)
            output[lowerBound..<upperBound].font = .system(size: size, weight: .bold)
        }
        return Text(output).font(.system(size: size, weight: weight))
    }

    private func windowBadgeText(for window: WindowInfo) -> String {
        if window.isMinimized { return String(localized: "MINIMIZED", comment: "Picker badge") }
        if window.isHidden { return String(localized: "HIDDEN", comment: "Picker badge") }
        if window.isWindowless { return String(localized: "NO WINDOWS", comment: "Picker badge") }
        return window.spaceLabel ?? String(localized: "OTHER SPACE", comment: "Picker badge")
    }

    private var showHeader: Bool {
        isSpaceMode || !prefs.verticalList || prefs.verticalShowHeader || model.filterHeaderVisible
    }

    private var isSpaceMode: Bool { model.mode == .spaces }
    private var animationsEnabled: Bool { !prefs.disableAnimations }

    private var panelAnimation: Animation? {
        guard animationsEnabled else { return nil }
        return prefs.verticalList
            ? .spring(response: 0.22, dampingFraction: 0.9)
            : .spring(response: 0.18, dampingFraction: 0.86)
    }

    private func switcherAnimation(_ animation: Animation) -> Animation? {
        animationsEnabled ? animation : nil
    }

    private var panelScale: CGFloat {
        animationsEnabled ? (model.visible ? 1.0 : 0.97) : 1.0
    }

    private var panelYOffset: CGFloat {
        animationsEnabled && prefs.verticalList && !model.visible ? -5 : 0
    }

    var body: some View {
        VStack(spacing: 0) {
            if showHeader { header }
            grid
            if prefs.showHintStrip { hintStrip }
        }
        .frame(width: model.panelSize.width, height: model.panelSize.height)
        .background {
            // SwiftUI materials don't sample behind the panel pre-Tahoe (#81).
            if #available(macOS 26.0, *) {
                Rectangle().fill(prefs.backgroundBlur.material)
            } else {
                VisualEffectBackdrop(material: prefs.backgroundBlur.nsMaterial, blendingMode: .behindWindow)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .scaleEffect(panelScale)
        .offset(y: panelYOffset)
        .opacity(model.visible ? 1 : 0)
        .animation(panelAnimation, value: model.visible)
        .onPreferenceChange(PanelMetricsKey.self) { measured in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { model.updateMetrics(measured) }
            }
        }
        .onChange(of: model.visible) { _, isVisible in
            if isVisible {
                openMouseLocation = NSEvent.mouseLocation
                hasMouseMovedSinceOpen = false
                lastSelectionFromMouse = false
                hoveredID = nil
            }
        }
    }

    private var header: some View {
        HStack(spacing: scaled(10)) {
            if !model.filterText.isEmpty {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: scaled(13), weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(model.filterText)
                    .font(.system(size: scaled(14), weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)
            }
            Spacer()
            if !model.filteredWindows.isEmpty {
                Group {
                    if isSpaceMode {
                        Text("\(model.filteredWindows.count) spaces", comment: "Picker header Space count")
                    } else {
                        Text(verbatim: "\(model.filteredWindows.count)")
                    }
                }
                .font(.system(size: scaled(12), weight: .semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
        }
        .padding(.horizontal, scaled(22))
        .frame(height: scaled(34))
        .padding(.top, scaled(12))
        .measureHeight(into: \.headerHeight)
    }

    private var grid: some View {
        ZStack {
            let results = model.searchResults
            if results.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        if isSpaceMode || prefs.verticalList {
                            LazyVStack(spacing: scaled(4)) {
                                ForEach(Array(results.enumerated()), id: \.element.id) { idx, result in
                                    listRow(result: result, index: idx)
                                        .measureHeight(into: \.rowHeight)
                                        .id(result.id)
                                }
                            }
                            .padding(.horizontal, scaled(14))
                            .padding(.top, scaled(showHeader ? 10 : 14))
                        } else {
                            let adaptiveGrid = adaptiveGridGeometry(itemCount: results.count)
                            LazyVGrid(
                                columns: Array(
                                    repeating: GridItem(.flexible(), spacing: scaled(14)),
                                    count: adaptiveGrid.columns
                                ),
                                spacing: scaled(14)
                            ) {
                                ForEach(Array(results.enumerated()), id: \.element.id) { idx, result in
                                    tile(
                                        result: result,
                                        index: idx,
                                        thumbnailHeight: adaptiveGrid.thumbnailHeight
                                    )
                                        .measureHeight(into: \.tileHeight)
                                        .id(result.id)
                                }
                            }
                            .padding(.horizontal, scaled(22))
                            .padding(.top, scaled(6))
                        }
                    }
                    .onChange(of: model.selected) { _, new in
                        // Skip auto-scroll when selection came from mouse hover;
                        // user is already looking at where they're pointing.
                        if lastSelectionFromMouse {
                            lastSelectionFromMouse = false
                            return
                        }
                        let cur = model.searchResults
                        guard cur.indices.contains(new) else { return }
                        withAnimation(switcherAnimation(.easeInOut(duration: 0.22))) {
                            proxy.scrollTo(cur[new].window.id, anchor: .center)
                        }
                    }
                    // Viewport chrome, not scroll content: no row can occupy this space
                    // and appear as a clipped sliver at the bottom.
                    .padding(.bottom, scaled(isSpaceMode || prefs.verticalList ? 10 : 12))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: scaled(8)) {
            Image(systemName: model.filterText.isEmpty ? "rectangle.stack" : "magnifyingglass")
                .font(.system(size: scaled(22), weight: .medium))
                .foregroundStyle(.tertiary)
            if model.filterText.isEmpty {
                Text("No windows", comment: "Empty picker")
                    .font(.system(size: scaled(13), weight: .semibold))
                    .foregroundStyle(.secondary)
            } else {
                Text("No matches", comment: "Empty picker after filter")
                    .font(.system(size: scaled(13), weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .transition(.scale(scale: 0.98).combined(with: .opacity))
    }

    private var hintStrip: some View {
        HStack(spacing: scaled(18)) {
            hint("↵", isSpaceMode ? "switch space" : "switch")
            hint(navKey, "navigate")
            if prefs.shiftTapReverses { hint("⇧", "reverse") }
            if !isSpaceMode { hint(closeKey, "close") }
            if prefs.typeToFilter { hint("type", "filter") }
            hint("esc", "cancel")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, scaled(22))
        .padding(.vertical, scaled(8))
        .background(Color.black.opacity(0.18))
        .measureHeight(into: \.hintHeight)
    }

    private var navKey: String {
        (prefs.verticalList || isSpaceMode) ? "↑↓" : "←↑↓→"
    }

    private var closeKey: String {
        (model.stickySession || !prefs.typeToFilter) ? "⌘W" : "⇧⌘W"
    }

    private func stoplights(for window: WindowInfo) -> some View {
        HStack(spacing: scaled(4)) {
            stoplight(color: Color(red: 1.0, green: 0.36, blue: 0.34), symbol: "xmark") {
                model.close(window)
            }
            stoplight(color: Color(red: 1.0, green: 0.74, blue: 0.20), symbol: "minus") {
                WindowMinimizer.minimize(window)
            }
            stoplight(color: Color(red: 0.30, green: 0.78, blue: 0.34), symbol: "plus") {
                WindowZoomer.zoom(window)
            }
        }
        .opacity(prefs.disableMouse ? 0 : 1)
        .allowsHitTesting(!prefs.disableMouse)
    }

    private func pinButton(for window: WindowInfo) -> some View {
        let bid = window.bundleID
        let isPinned = bid.map { prefs.pinnedBundleIDs.contains($0) } ?? false
        return Button {
            guard let bid else { return }
            if isPinned { prefs.pinnedBundleIDs.remove(bid) }
            else { prefs.pinnedBundleIDs.insert(bid) }
        } label: {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.system(size: scaled(11), weight: .semibold))
                .foregroundStyle(isPinned ? prefs.accent.color : Color.white.opacity(0.75))
                .frame(width: scaled(18), height: scaled(18))
                .background(Circle().fill(Color.black.opacity(0.35)))
        }
        .buttonStyle(.plain)
        .opacity(prefs.disableMouse ? 0 : 1)
        .allowsHitTesting(!prefs.disableMouse)
    }

    private func stoplight(color: Color, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(color)
                    .frame(width: scaled(12), height: scaled(12))
                    .shadow(color: .black.opacity(0.35), radius: scaled(1), y: scaled(0.5))
                Image(systemName: symbol)
                    .font(.system(size: scaled(7), weight: .bold))
                    .foregroundStyle(.black.opacity(0.55))
            }
        }
        .buttonStyle(.plain)
    }

    private func hint(_ key: String, _ label: LocalizedStringResource) -> some View {
        HStack(spacing: scaled(5)) {
            Text(verbatim: key)
                .font(.system(size: scaled(10), weight: .semibold, design: .monospaced))
                .tracking(scaled(1))
                .foregroundStyle(.primary.opacity(0.85))
                .padding(.horizontal, scaled(5))
                .padding(.vertical, scaled(1))
                .background(
                    RoundedRectangle(cornerRadius: scaled(3), style: .continuous)
                        .fill(Color.white.opacity(0.10))
                )
            Text(label)
                .font(.system(size: scaled(11)))
                .foregroundStyle(.secondary)
        }
        .fixedSize()
        .help(label)
    }

    private func adaptiveGridGeometry(itemCount: Int) -> SwitcherAdaptiveGridGeometry {
        let headerHeight = showHeader ? scaled(46) : 0
        let hintHeight = prefs.showHintStrip ? scaled(38) : 0
        let gridChrome = scaled(16 + 52)
        let verticalCapacity = model.panelSize.height - headerHeight - hintHeight - gridChrome
        return SwitcherPanelLayout.adaptiveGrid(
            panelWidth: model.panelSize.width,
            itemCount: itemCount,
            configuredColumns: prefs.gridColumns,
            baseThumbnailHeight: CGFloat(prefs.thumbnailHeight) * visualScale,
            compactThumbnailHeight: CGFloat(SwitchPreferences.compactThumbnailHeight) * visualScale,
            showsThumbnails: prefs.showThumbnails,
            visualScale: visualScale,
            verticalCapacity: verticalCapacity
        )
    }

    private func tile(
        result: WindowSearchIndex.Result,
        index: Int,
        thumbnailHeight: CGFloat
    ) -> some View {
        let window = result.window
        let selected = index == model.selected
        let hovered = hoveredID == window.id
        let icon = appIcon(for: window)

        return VStack(alignment: .leading, spacing: scaled(7)) {
            ZStack(alignment: .bottomLeading) {
                ZStack {
                    Color.black.opacity(0.22)
                    if prefs.showThumbnails, let img = model.thumbnails[window.id] {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(scaled(6))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .transition(.opacity)
                    } else if let icon {
                        Image(nsImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: scaled(56), height: scaled(56))
                            .opacity(0.55)
                            .scaleEffect(selected ? 1.05 : 1.0)
                            .animation(switcherAnimation(.spring(response: 0.20, dampingFraction: 0.82)), value: selected)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: thumbnailHeight)
                .clipShape(RoundedRectangle(cornerRadius: scaled(7), style: .continuous))
                .overlay(alignment: .topLeading) {
                    if prefs.showStoplights && !window.isWindowless {
                        stoplights(for: window).padding(scaled(7))
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if !window.isWindowless && (isPinned(window) || hovered) {
                        pinButton(for: window).padding(scaled(7))
                    }
                }
                .animation(switcherAnimation(.easeOut(duration: 0.18)), value: model.thumbnails[window.id] != nil)

                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: scaledAppIconSize, height: scaledAppIconSize)
                        .scaleEffect(selected ? 1.06 : 1.0)
                        .shadow(color: .black.opacity(0.35), radius: scaled(4), x: 0, y: scaled(1))
                        .padding(scaled(7))
                        .animation(switcherAnimation(.spring(response: 0.20, dampingFraction: 0.82)), value: selected)
                }

                HStack(spacing: 0) {
                    Spacer()
                    VStack {
                        Spacer()
                        windowBadge(for: window).padding(scaled(7))
                    }
                }
            }

            HStack(spacing: scaled(6)) {
                let titleFirst = prefs.showTitleFirst && !window.title.isEmpty
                numberHint(index: index)
                highlightedSearchText(
                    titleFirst ? window.title : window.appName,
                    match: titleFirst ? result.titleMatch : result.appNameMatch,
                    size: scaled(13),
                    weight: .semibold,
                    baseColor: .primary
                )
                    .lineLimit(1)
                if !window.title.isEmpty {
                    Text(verbatim: "·")
                        .font(.system(size: scaled(12), weight: .medium))
                        .foregroundStyle(.tertiary)
                    highlightedSearchText(
                        titleFirst ? window.appName : window.title,
                        match: titleFirst ? result.appNameMatch : result.titleMatch,
                        size: scaled(12),
                        weight: .medium,
                        baseColor: .secondary
                    )
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, scaled(2))
        }
        .padding(scaled(9))
        .modifier(SelectionChrome(selected: selected, hovered: hovered, cornerRadius: scaled(9), accent: prefs.accent.color, namespace: selectionNS, selectedValue: model.selected, animationsEnabled: animationsEnabled))
        .animation(switcherAnimation(.easeInOut(duration: 0.18)), value: thumbnailHeight)
        .contentShape(Rectangle())
        .onHover { handleHover($0, windowID: window.id, index: index) }
        .onTapGesture { handleTap(index: index) }
    }

    private func listRow(result: WindowSearchIndex.Result, index: Int) -> some View {
        let window = result.window
        let selected = index == model.selected
        let hovered = hoveredID == window.id
        let icon = appIcon(for: window)

        return HStack(spacing: scaled(11)) {
            numberHint(index: index)
            ZStack {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: scaledAppIconSize, height: scaledAppIconSize)
                        .scaleEffect(selected ? 1.08 : 1.0)
                        .animation(switcherAnimation(.spring(response: 0.20, dampingFraction: 0.82)), value: selected)
                } else {
                    Color.clear.frame(width: scaledAppIconSize, height: scaledAppIconSize)
                }
            }
            VStack(alignment: .leading, spacing: scaled(2)) {
                let titleFirst = prefs.showTitleFirst && !window.title.isEmpty
                highlightedSearchText(
                    titleFirst ? window.title : window.appName,
                    match: titleFirst ? result.titleMatch : result.appNameMatch,
                    size: scaled(14),
                    weight: .semibold,
                    baseColor: .primary
                )
                    .lineLimit(1)
                if !window.title.isEmpty {
                    highlightedSearchText(
                        titleFirst ? window.appName : window.title,
                        match: titleFirst ? result.appNameMatch : result.titleMatch,
                        size: scaled(12),
                        weight: .medium,
                        baseColor: .secondary
                    )
                        .lineLimit(1)
                }
            }
            Spacer(minLength: scaled(6))
            if !isSpaceMode && prefs.showStoplights && prefs.verticalShowStoplights && !window.isWindowless {
                stoplights(for: window)
                    .opacity(hovered ? 1 : 0.45)
            }
            if !isSpaceMode && !window.isWindowless && (isPinned(window) || hovered) {
                pinButton(for: window)
                    .opacity(hovered ? 1 : 0.8)
            }
            if isSpaceMode {
                if window.spaceLabel == "Current" {
                    capsuleBadge(String(localized: "CURRENT", comment: "Picker badge for the active Space"))
                }
            } else {
                windowBadge(for: window)
            }
            if prefs.showThumbnails && prefs.verticalShowPreview {
                Group {
                    if let img = model.thumbnails[window.id] {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: scaled(88), height: scaled(50))
                    } else {
                        Color.black.opacity(0.22)
                            .frame(width: scaled(88), height: scaled(50))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: scaled(5), style: .continuous))
            }
        }
        .padding(.horizontal, scaled(10))
        .padding(.vertical, scaled(6))
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(SelectionChrome(selected: selected, hovered: hovered, cornerRadius: scaled(8), accent: prefs.accent.color, namespace: selectionNS, selectedValue: model.selected, animationsEnabled: animationsEnabled))
        .contentShape(Rectangle())
        .onHover { handleHover($0, windowID: window.id, index: index) }
        .onTapGesture { handleTap(index: index) }
    }

    private func appIcon(for window: WindowInfo) -> NSImage? {
        let key = window.bundleID ?? "pid:\(window.pid)"
        if let cached = Self.iconCache[key] { return cached }
        guard let icon = NSRunningApplication(processIdentifier: window.pid)?.icon else { return nil }
        if Self.iconCache.count > 256 { Self.iconCache.removeAll() }
        Self.iconCache[key] = icon
        return icon
    }

    private static var iconCache: [String: NSImage] = [:]
}

private struct SelectionChrome: ViewModifier {
    let selected: Bool
    let hovered: Bool
    let cornerRadius: CGFloat
    let accent: Color
    let namespace: Namespace.ID
    let selectedValue: Int
    let animationsEnabled: Bool

    private func selectionAnimation(_ animation: Animation) -> Animation? {
        animationsEnabled ? animation : nil
    }

    func body(content: Content) -> some View {
        content
            .background(
                // Clipping at the row level hides the matched-geometry fill while it slides between rows, so the rounding lives on the fills themselves (#133).
                ZStack {
                    if hovered && !selected {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    }
                    if selected {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(accent.opacity(0.22))
                            .matchedGeometryEffect(id: "selectionBG", in: namespace)
                    }
                }
            )
            .overlay(
                ZStack {
                    if selected {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(accent.opacity(0.7), lineWidth: 1)
                            .matchedGeometryEffect(id: "selectionRing", in: namespace)
                    }
                }
            )
            .animation(selectionAnimation(.spring(response: 0.22, dampingFraction: 0.85)), value: selectedValue)
            .animation(selectionAnimation(.easeOut(duration: 0.10)), value: hovered)
    }
}

private struct PanelMetricsKey: PreferenceKey {
    static let defaultValue = PanelMetrics()

    static func reduce(value: inout PanelMetrics, nextValue: () -> PanelMetrics) {
        value.merge(nextValue())
    }
}

private extension View {
    /// Reports this component's laid-out height to the AppKit panel sizing layer.
    func measureHeight(into keyPath: WritableKeyPath<PanelMetrics, CGFloat>) -> some View {
        background(
            GeometryReader { proxy in
                var metrics = PanelMetrics()
                metrics[keyPath: keyPath] = proxy.size.height
                return Color.clear.preference(key: PanelMetricsKey.self, value: metrics)
            }
        )
    }
}
