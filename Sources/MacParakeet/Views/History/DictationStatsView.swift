import AppKit
import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

struct DictationStatsView: View {
    @Bindable var viewModel: DictationHistoryViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                if viewModel.stats.isEmpty {
                    emptyState
                } else {
                    heroTiles
                    streakHeatmapCard
                    if !viewModel.topApps.isEmpty {
                        topAppsCard
                    }
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.lg)
            .padding(.vertical, DesignSystem.Spacing.md)
        }
        .onAppear { viewModel.refreshStatsTabData() }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: DesignSystem.Spacing.lg) {
            Spacer(minLength: DesignSystem.Spacing.xxl)
            MeditativeMerkabaView(size: 72, revolutionDuration: 8.0, tintColor: DesignSystem.Colors.accent)
                .opacity(0.4)
            VStack(spacing: DesignSystem.Spacing.sm) {
                Text("Your stats will appear here.")
                    .font(DesignSystem.Typography.pageTitle)
                    .foregroundStyle(.primary)
                Text(HotkeyTrigger.current.isDisabled
                     ? "Click the dictation pill or set a hotkey in Settings to start dictating."
                     : "Tap \(HotkeyTrigger.current.displayName) to start dictating from any app.")
                    .font(DesignSystem.Typography.bodySmall)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Hero Tiles

    private var heroTiles: some View {
        let stats = viewModel.stats
        return LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: DesignSystem.Spacing.md),
                GridItem(.flexible(), spacing: DesignSystem.Spacing.md),
                GridItem(.flexible(), spacing: DesignSystem.Spacing.md)
            ],
            spacing: DesignSystem.Spacing.md
        ) {
            HeroStatTile(
                label: "Total words",
                value: stats.totalWords.compactFormatted,
                subtitle: wordsSubtitle(stats),
                accent: true
            )
            HeroStatTile(
                label: "Voice speed",
                value: stats.averageWPM.formattedWPM,
                subtitle: wpmDescriptor(stats.averageWPM),
                accent: false
            )
            HeroStatTile(
                label: "Time speaking",
                value: stats.totalDurationMs.friendlyDuration,
                subtitle: timeSpeakingSubtitle(stats),
                accent: false
            )
        }
    }

    private func wordsSubtitle(_ stats: DictationStats) -> String {
        if stats.totalWords >= 80_000 {
            let books = stats.booksEquivalent
            return String(format: "%.1f novel%@ written", books, books >= 1.5 ? "s" : "")
        } else if stats.totalWords >= 200 {
            return "\(Int(stats.emailsEquivalent)) emails worth"
        }
        return "Keep going!"
    }

    private func wpmDescriptor(_ wpm: Double) -> String {
        switch wpm {
        case ..<1: return "—"
        case ..<80: return "Thoughtful pace"
        case 80..<120: return "Conversational"
        case 120..<160: return "Brisk speaker"
        case 160..<200: return "Fast talker"
        default: return "Lightning speed"
        }
    }

    private func timeSpeakingSubtitle(_ stats: DictationStats) -> String {
        if stats.timeSavedMs >= 60_000 {
            return "Saved \(stats.timeSavedMs.friendlyDuration) typing"
        }
        return "\(stats.totalCount) dictation\(stats.totalCount == 1 ? "" : "s")"
    }

    // MARK: - Streak Heatmap Card

    private var streakHeatmapCard: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            // Headline row with brand glyph anchoring the streak number.
            // The glyph signals "this is the brand's hero stat surface"
            // and gives the headline a visual lock-up without crowding.
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(DesignSystem.Colors.accent.opacity(0.12))
                        .frame(width: 34, height: 34)
                    BreathWaveLogo(size: 22, tint: DesignSystem.Colors.accent)
                }

                Text(streakHeadline)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                    .monospacedDigit()

                Spacer()

                Text("Longest streak · \(viewModel.longestStreak) day\(viewModel.longestStreak == 1 ? "" : "s")")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }

            StreakHeatmap(days: viewModel.dailyStats)
                .frame(maxWidth: .infinity, alignment: .center)

            HStack(spacing: 8) {
                Text("Less")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
                ForEach(0..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(StreakHeatmap.color(for: level))
                        .frame(width: 11, height: 11)
                }
                Text("More")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .background(
            // A barely-perceptible diagonal gradient gives the hero card a
            // hint of depth without crossing into glossy. Both stops are
            // close enough that it reads as a single surface, not a panel.
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .fill(
                    LinearGradient(
                        colors: [
                            DesignSystem.Colors.cardBackground,
                            DesignSystem.Colors.surfaceElevated.opacity(0.45)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            // A whisper-thin coral highlight on the top edge — a single
            // pixel of brand color that gives the card a "lit-from-above"
            // feel. Invisible at a glance, felt subliminally.
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            DesignSystem.Colors.accent.opacity(0.18),
                            Color.primary.opacity(0.04)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.5
                )
        )
    }

    private var streakHeadline: String {
        let n = viewModel.currentStreak
        if n == 0 { return "Build a streak" }
        return "\(n) day streak"
    }

    // MARK: - Top Apps

    private var topAppsCard: some View {
        let totalCount = viewModel.topApps.reduce(0) { $0 + $1.count }
        let maxCount = viewModel.topApps.map(\.count).max() ?? 1
        return VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text("Where you dictate")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                Spacer()
                Text("Top \(viewModel.topApps.count) app\(viewModel.topApps.count == 1 ? "" : "s")")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(viewModel.topApps.enumerated()), id: \.element.id) { index, entry in
                    TopAppRow(
                        entry: entry,
                        percentOfMax: Double(entry.count) / Double(max(maxCount, 1)),
                        percentOfTotal: Double(entry.count) / Double(max(totalCount, 1)),
                        rowIndex: index
                    )
                }
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .fill(
                    LinearGradient(
                        colors: [
                            DesignSystem.Colors.cardBackground,
                            DesignSystem.Colors.surfaceElevated.opacity(0.45)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .strokeBorder(Color.primary.opacity(0.05), lineWidth: 0.5)
        )
    }
}

// MARK: - Hero Stat Tile

private struct HeroStatTile: View {
    let label: String
    let value: String
    let subtitle: String
    /// When true, the hero value is rendered in the brand accent.
    /// Reserved for the lead tile only — three accented values would
    /// flatten the visual hierarchy.
    let accent: Bool

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(accent ? DesignSystem.Colors.accent : Color.primary)
                .contentTransition(.numericText())
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(subtitle)
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.md + 2)
        .background(
            // Same diagonal-gradient depth treatment as the streak card,
            // so the three tiles read as the same material family.
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .fill(
                    LinearGradient(
                        colors: [
                            DesignSystem.Colors.cardBackground,
                            DesignSystem.Colors.surfaceElevated.opacity(0.45)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .strokeBorder(
                    isHovered
                        ? DesignSystem.Colors.accent.opacity(0.30)
                        : Color.primary.opacity(0.05),
                    lineWidth: 0.5
                )
        )
        .scaleEffect(isHovered ? 1.012 : 1.0)
        .shadow(
            color: .black.opacity(isHovered ? 0.10 : 0.0),
            radius: isHovered ? 10 : 0,
            x: 0,
            y: isHovered ? 4 : 0
        )
        .animation(.easeOut(duration: 0.18), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Streak Heatmap

struct StreakHeatmap: View {
    let days: [DailyDictationStat]

    @State private var hoveredCell: HoveredCell?
    @State private var todayPulse: Bool = false

    struct HoveredCell: Equatable {
        let col: Int
        let row: Int
        let stat: DailyDictationStat
    }

    fileprivate static let cellSize: CGFloat = 16
    fileprivate static let cellSpacing: CGFloat = 4
    private let weekdayLabelWidth: CGFloat = 28
    private let monthLabelHeight: CGFloat = 14

    var body: some View {
        let columns = buildColumns()
        let boundaries = monthBoundaries(columns: columns)
        let cellStride = Self.cellSize + Self.cellSpacing

        VStack(alignment: .leading, spacing: Self.cellSpacing) {
            // Month-label row: free-floating Text positioned at each month-change column.
            ZStack(alignment: .topLeading) {
                Color.clear.frame(
                    width: CGFloat(columns.count) * Self.cellSize + CGFloat(max(0, columns.count - 1)) * Self.cellSpacing,
                    height: monthLabelHeight
                )
                ForEach(boundaries, id: \.col) { boundary in
                    Text(boundary.label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                        .offset(x: CGFloat(boundary.col) * cellStride, y: 0)
                }
            }
            .padding(.leading, weekdayLabelWidth + Self.cellSpacing)

            HStack(alignment: .top, spacing: Self.cellSpacing) {
                weekdayLabelColumn

                // The tooltip lives in an `.overlay` (which never propagates
                // a sizing hint to the parent) and uses `.offset` (a render-
                // only transform). Earlier this was a ZStack with a
                // `.position`-modified tooltip — `.position` claims the
                // ZStack's full bounds, which leaked a "fill" signal up the
                // tree. When the outer card was wider than the heatmap, the
                // surrounding `.frame(maxWidth: .infinity, alignment: .center)`
                // would re-center on every tooltip mount/unmount, producing
                // a rapid left/right jitter as the mouse moved cell-to-cell.
                gridBody(columns: columns)
                    .overlay(alignment: .topLeading) {
                        if let h = hoveredCell {
                            floatingTooltip(for: h, columnCount: columns.count)
                        }
                    }
                    .animation(.easeOut(duration: 0.12), value: hoveredCell)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                todayPulse = true
            }
        }
    }

    // MARK: - Subviews

    private var weekdayLabelColumn: some View {
        VStack(alignment: .trailing, spacing: Self.cellSpacing) {
            ForEach(0..<7, id: \.self) { row in
                Group {
                    if let label = weekdayLabel(forRow: row) {
                        Text(label)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: weekdayLabelWidth, height: Self.cellSize, alignment: .trailing)
            }
        }
    }

    private func gridBody(columns: [[DailyDictationStat?]]) -> some View {
        HStack(alignment: .top, spacing: Self.cellSpacing) {
            ForEach(columns.indices, id: \.self) { colIdx in
                VStack(spacing: Self.cellSpacing) {
                    ForEach(0..<7, id: \.self) { row in
                        if let stat = columns[colIdx][row] {
                            cell(for: stat, col: colIdx, row: row)
                        } else {
                            Color.clear.frame(width: Self.cellSize, height: Self.cellSize)
                        }
                    }
                }
            }
        }
    }

    private func cell(for stat: DailyDictationStat, col: Int, row: Int) -> some View {
        let level = Self.level(forCount: stat.count)
        let isToday = Calendar.current.isDateInToday(stat.day)
        let isHovered = hoveredCell?.stat.day == stat.day

        return RoundedRectangle(cornerRadius: 3)
            .fill(Self.color(for: level))
            .frame(width: Self.cellSize, height: Self.cellSize)
            .overlay(
                // Today: stronger ring + breathing animation so it reads as "you are here".
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(
                        isToday ? DesignSystem.Colors.accent : Color.clear,
                        lineWidth: isToday ? 1.75 : 0
                    )
                    .opacity(isToday && todayPulse ? 1.0 : (isToday ? 0.55 : 0))
            )
            .overlay(
                // Hover: white-ish stroke for affordance.
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(
                        isHovered ? Color.primary.opacity(0.55) : Color.clear,
                        lineWidth: 1.0
                    )
            )
            .scaleEffect(isHovered ? 1.18 : 1.0)
            .zIndex(isHovered ? 1 : 0)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.accessibilityLabel(for: stat, isToday: isToday))
            .onHover { hovering in
                if hovering {
                    hoveredCell = HoveredCell(col: col, row: row, stat: stat)
                } else if hoveredCell?.stat.day == stat.day {
                    hoveredCell = nil
                }
            }
    }

    private static let accessibilityDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    /// VoiceOver-friendly label for a single heatmap cell. Reads like
    /// "May 11, 2026, 3 dictations, 240 words" or "March 5, 2026, no dictations".
    static func accessibilityLabel(for stat: DailyDictationStat, isToday: Bool) -> String {
        let dateLabel = isToday ? "Today" : accessibilityDateFormatter.string(from: stat.day)
        guard stat.count > 0 else { return "\(dateLabel), no dictations" }
        let dictations = "\(stat.count) dictation\(stat.count == 1 ? "" : "s")"
        let words = "\(stat.words) word\(stat.words == 1 ? "" : "s")"
        return "\(dateLabel), \(dictations), \(words)"
    }

    private func floatingTooltip(for h: HoveredCell, columnCount: Int) -> some View {
        // Tooltip is ~52pt tall, ~220pt wide. Show above cell when row >= 2;
        // otherwise below to avoid clipping the heatmap's top edge.
        //
        // Anchor: top-leading of the grid (via the `.overlay(alignment:)`
        // host). We compute the offset of the tooltip's TOP-LEFT corner,
        // not its center — `.offset` shifts visually without affecting
        // layout, which is the whole point of the jitter fix.
        let tooltipApproxWidth: CGFloat = 220
        let tooltipApproxHeight: CGFloat = 52
        let gap: CGFloat = 8
        let cellStride = Self.cellSize + Self.cellSpacing

        let cellMidX = CGFloat(h.col) * cellStride + Self.cellSize / 2
        let cellTop = CGFloat(h.row) * cellStride
        let cellBottom = cellTop + Self.cellSize
        let showAbove = h.row >= 2

        // Tooltip top-left so its horizontal center sits on the cell.
        let rawLeftX = cellMidX - tooltipApproxWidth / 2

        // Keep the tooltip's bounding box inside the grid's horizontal extent.
        let gridWidth = CGFloat(columnCount) * cellStride - Self.cellSpacing
        let clampedLeftX = max(0, min(gridWidth - tooltipApproxWidth, rawLeftX))

        let topY = showAbove
            ? cellTop - tooltipApproxHeight - gap
            : cellBottom + gap

        return HeatmapTooltipView(stat: h.stat)
            .fixedSize()
            .offset(x: clampedLeftX, y: topY)
            .allowsHitTesting(false)
            .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: showAbove ? .bottom : .top)))
    }

    // MARK: - Layout helpers

    /// Lays out `days` (oldest-first, 182 entries) into columns where each
    /// column is one calendar week (7 rows). Pads leading column with `nil`s
    /// for days before the window's first entry.
    private func buildColumns() -> [[DailyDictationStat?]] {
        guard !days.isEmpty else {
            return Array(repeating: Array(repeating: nil, count: 7), count: 26)
        }
        let calendar = Calendar.current
        let firstWeekday = calendar.firstWeekday

        var columns: [[DailyDictationStat?]] = []
        var current: [DailyDictationStat?] = []

        let firstWeekdayOfData = calendar.component(.weekday, from: days[0].day)
        let leadingPad = (firstWeekdayOfData - firstWeekday + 7) % 7
        current.append(contentsOf: Array(repeating: nil as DailyDictationStat?, count: leadingPad))

        for stat in days {
            current.append(stat)
            if current.count == 7 {
                columns.append(current)
                current = []
            }
        }
        if !current.isEmpty {
            current.append(contentsOf: Array(repeating: nil as DailyDictationStat?, count: 7 - current.count))
            columns.append(current)
        }
        return columns
    }

    private func weekdayLabel(forRow row: Int) -> String? {
        let calendar = Calendar.current
        let weekday = ((calendar.firstWeekday - 1 + row) % 7) + 1
        switch weekday {
        case 2: return "Mon"
        case 4: return "Wed"
        case 6: return "Fri"
        default: return nil
        }
    }

    private func monthBoundaries(columns: [[DailyDictationStat?]]) -> [(col: Int, label: String)] {
        let calendar = Calendar.current
        var result: [(col: Int, label: String)] = []
        var lastMonth: Int? = nil
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM"

        for (idx, column) in columns.enumerated() {
            guard let firstDay = column.compactMap({ $0 }).first else { continue }
            let month = calendar.component(.month, from: firstDay.day)
            if month != lastMonth {
                result.append((col: idx, label: formatter.string(from: firstDay.day)))
                lastMonth = month
            }
        }
        return result
    }

    // MARK: - Level → Color

    static func level(forCount count: Int) -> Int {
        switch count {
        case 0: return 0
        case 1: return 1
        case 2...3: return 2
        case 4...7: return 3
        default: return 4
        }
    }

    /// Empty cells use `Color.primary.opacity(0.07)` rather than
    /// `surfaceElevated` because in dark mode the latter is nearly
    /// indistinguishable from the card background, dissolving the grid's
    /// visual structure. Primary-based opacity adapts to both schemes.
    static func color(for level: Int) -> Color {
        switch level {
        case 0: return Color.primary.opacity(0.07)
        case 1: return DesignSystem.Colors.accent.opacity(0.30)
        case 2: return DesignSystem.Colors.accent.opacity(0.55)
        case 3: return DesignSystem.Colors.accent.opacity(0.78)
        default: return DesignSystem.Colors.accent
        }
    }
}

// MARK: - Heatmap Tooltip

private struct HeatmapTooltipView: View {
    let stat: DailyDictationStat

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(headline)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
            Text(detail)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 4)
    }

    private var headline: String {
        let cal = Calendar.current
        if cal.isDateInToday(stat.day) { return "Today" }
        if cal.isDateInYesterday(stat.day) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d"
        return formatter.string(from: stat.day)
    }

    private var detail: String {
        guard stat.count > 0 else { return "No dictations" }
        let words = "\(stat.words) word\(stat.words == 1 ? "" : "s")"
        let duration = stat.durationMs.friendlyDuration
        return "\(stat.count) dictation\(stat.count == 1 ? "" : "s") · \(words) · \(duration)"
    }
}

// MARK: - Top App Row

private struct TopAppRow: View {
    let entry: DictationHistoryViewModel.TopAppEntry
    let percentOfMax: Double
    let percentOfTotal: Double
    /// Row index within the top-apps list. Used to flip the hover popover
    /// below the row when the row is near the top of the card, so the
    /// popover doesn't clip against the card edge or the section title.
    let rowIndex: Int

    @State private var isHovered = false

    var body: some View {
        let resolved = AppNameResolver.shared.resolve(bundleID: entry.bundleID)
        HStack(spacing: DesignSystem.Spacing.sm) {
            appIcon(for: entry.bundleID, fallbackInitial: resolved)
                .frame(width: 20, height: 20)

            Text(resolved)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .lineLimit(1)
                .frame(width: 140, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.06))
                    Capsule()
                        .fill(DesignSystem.Colors.accent.opacity(0.4 + percentOfMax * 0.5))
                        .frame(width: max(12, geo.size.width * percentOfMax))
                }
            }
            .frame(height: 14)

            Text(formatPercent(percentOfTotal))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    isHovered
                        ? DesignSystem.Colors.accent.opacity(0.10)
                        : Color.clear
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isHovered ? DesignSystem.Colors.accent.opacity(0.25) : Color.clear,
                    lineWidth: 0.5
                )
        )
        // Instant detail popover, centered above the row by default and
        // flipped below for the top row so it doesn't clip against the card
        // edge or the "Where you dictate" section title. Mirrors the
        // heatmap's hover pattern (no system tooltip delay, no system arrow).
        .overlay(alignment: showAbove ? .top : .bottom) {
            if isHovered {
                TopAppHoverDetail(entry: entry, resolved: resolved)
                    .fixedSize()
                    .offset(x: 0, y: showAbove ? -54 : 54)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: showAbove ? .bottom : .top)))
            }
        }
        // CRITICAL: without this, SwiftUI's hit-walk only registers hover on
        // the row's actual child glyphs (Text, Image, Capsule) — the padding
        // zones and gaps between children pass the cursor through, so
        // `.onHover` only fires intermittently and `.help` doesn't attach to
        // a stable region. `Rectangle()` forces the entire padded frame to
        // be the hit area.
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(resolved: resolved))
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .onHover { isHovered = $0 }
    }

    /// Show the popover above the row except for the first row, where the
    /// card's section title is directly above and the popover would clip.
    private var showAbove: Bool { rowIndex > 0 }

    private func accessibilityLabel(resolved: String) -> String {
        let dictationsLabel = "\(entry.count) dictation\(entry.count == 1 ? "" : "s")"
        return "\(resolved), \(dictationsLabel), \(formatPercent(percentOfTotal)) of total"
    }

    private func formatPercent(_ value: Double) -> String {
        let pct = value * 100
        if pct >= 1 {
            return "\(Int(pct.rounded()))%"
        } else if pct > 0 {
            return "<1%"
        }
        return "0%"
    }

    @ViewBuilder
    private func appIcon(for bundleID: String, fallbackInitial: String) -> some View {
        if let nsImage = AppNameResolver.shared.icon(forBundleID: bundleID) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            // Branded fallback — first letter of the resolved name on a tinted disc,
            // never the system-grey generic-app icon.
            ZStack {
                Circle()
                    .fill(DesignSystem.Colors.accent.opacity(0.18))
                Text(String(fallbackInitial.prefix(1)).uppercased())
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.accent)
            }
        }
    }
}

// MARK: - Top App Hover Detail

/// Instant-appearing popover surfaced when hovering an app row. Mirrors
/// `HeatmapTooltipView`'s chrome (regularMaterial + thin border + shadow,
/// rounded-design typography) so the two hover surfaces feel like one
/// design system.
private struct TopAppHoverDetail: View {
    let entry: DictationHistoryViewModel.TopAppEntry
    let resolved: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(resolved)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
            Text(detail)
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 4)
    }

    private var detail: String {
        let dictationsLabel = "\(entry.count) dictation\(entry.count == 1 ? "" : "s")"
        let wordsLabel = "\(entry.words.compactFormatted) word\(entry.words == 1 ? "" : "s")"
        guard entry.count > 0 else { return dictationsLabel }
        let avg = Int((Double(entry.words) / Double(entry.count)).rounded())
        return "\(dictationsLabel) · \(wordsLabel) · avg \(avg)/each"
    }
}

// MARK: - App Name Resolver

/// Cached bundle-ID → display name + icon resolution. Hits NSWorkspace once
/// per bundle ID, then serves from the cache for the rest of the session.
@MainActor
final class AppNameResolver {
    static let shared = AppNameResolver()

    private var nameCache: [String: String] = [:]
    private var iconCache: [String: NSImage?] = [:]

    private init() {}

    func resolve(bundleID: String) -> String {
        if let cached = nameCache[bundleID] { return cached }
        let resolved = resolveName(bundleID: bundleID)
        nameCache[bundleID] = resolved
        return resolved
    }

    func icon(forBundleID bundleID: String) -> NSImage? {
        if let cached = iconCache[bundleID] { return cached }
        let image = resolveIcon(bundleID: bundleID)
        iconCache[bundleID] = image
        return image
    }

    private func resolveName(bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        if let bundle = Bundle(url: url) {
            if let name = bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String { return name }
            if let name = bundle.infoDictionary?["CFBundleDisplayName"] as? String { return name }
            if let name = bundle.localizedInfoDictionary?["CFBundleName"] as? String { return name }
            if let name = bundle.infoDictionary?["CFBundleName"] as? String { return name }
        }
        return url.deletingPathExtension().lastPathComponent
    }

    private func resolveIcon(bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
