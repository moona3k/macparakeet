import SwiftUI
import MacParakeetCore

// MARK: - Export Options Popover (isolated view to prevent parent body re-evaluation)

/// Extracted from TranscriptResultView to prevent slider-driven state mutations
/// from re-evaluating the entire 3000+ line parent body on every drag frame.
/// SwiftUI only re-renders at View struct boundaries, so this isolation is critical
/// for Slider stability inside a popover.
struct ExportOptionsPopoverView: View {
    @Binding var transcriptExportOptions: TranscriptExportOptions
    @Binding var selectedExportFormat: TranscriptExportFormat
    @Binding var showingExportOptions: Bool
    let hasAlignedTimestampsForExport: Bool
    let hasSpeakerLabelsForExport: Bool
    let exportFormatOrder: [TranscriptExportFormat]
    let onExport: (TranscriptExportFormat) -> Void

    private var isDevBuild: Bool {
        Bundle.main.bundleIdentifier == "com.macparakeet.dev"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Label("Export Transcript", systemImage: "arrow.down.doc")
                    .font(DesignSystem.Typography.body.bold())

                Spacer()

                Button {
                    showingExportOptions = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close export options")
            }

            if isDevBuild {
                Text("Dev build — SRT caption controls appear when SRT or VTT is selected below.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("Format")
                    .font(DesignSystem.Typography.caption.weight(.medium))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 104), spacing: 8)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(exportFormatOrder) { format in
                        Button {
                            selectedExportFormat = format
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: format.iconName)
                                    .frame(width: 16)
                                Text(format.shortName)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                                Spacer(minLength: 0)
                            }
                            .font(DesignSystem.Typography.caption)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(selectedExportFormat == format
                                          ? DesignSystem.Colors.accent.opacity(0.14)
                                          : DesignSystem.Colors.surface)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(
                                        selectedExportFormat == format
                                        ? DesignSystem.Colors.accent.opacity(0.7)
                                        : DesignSystem.Colors.border.opacity(0.7),
                                        lineWidth: 1
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("Options")
                    .font(DesignSystem.Typography.caption.weight(.medium))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)

                Toggle("Include timestamps", isOn: $transcriptExportOptions.includeTimestamps)
                    .disabled(!selectedExportFormat.supportsTranscriptOptions || !hasAlignedTimestampsForExport)

                if selectedExportFormat.supportsTranscriptOptions {
                    Toggle("Include speaker labels", isOn: $transcriptExportOptions.includeSpeakerLabels)
                        .disabled(!hasSpeakerLabelsForExport)
                }

                Toggle("Include metadata", isOn: $transcriptExportOptions.includeMetadata)
                    .disabled(!selectedExportFormat.supportsTranscriptOptions)
            }

            if selectedExportFormat.isSubtitleFormat {
                if !hasAlignedTimestampsForExport {
                    Text("Timed cues need the original word timestamps. Edited transcripts export as one caption block; use Retranscribe or an unedited transcript for full SRT timing.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Files save to your Downloads folder. Adjust caption length and timing below.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Toggle("Include speaker names in captions", isOn: $transcriptExportOptions.includeSpeakerLabels)
                    .font(DesignSystem.Typography.caption)
                    .disabled(!hasSpeakerLabelsForExport)

                Divider()
                SubtitleConfigSection(config: $transcriptExportOptions.subtitleConfig)
                    .disabled(!hasAlignedTimestampsForExport)
                    .opacity(hasAlignedTimestampsForExport ? 1 : 0.55)
            }

            Divider()

            HStack {
                Spacer()
                Button {
                    showingExportOptions = false
                    onExport(selectedExportFormat)
                } label: {
                    Label("Export to Downloads", systemImage: "arrow.down.doc")
                }
                .parakeetAction(.primaryProminent)
                .keyboardShortcut(.defaultAction)
            }
            }
            .padding(DesignSystem.Spacing.md)
        }
        .frame(width: 400)
        .frame(maxHeight: 560)
    }
}

// MARK: - Subtitle Config Section (further isolation for slider state)

/// Owns a local copy of the subtitle config during editing. Changes are written
/// back to the parent Binding only when the user finishes dragging a slider,
/// preventing rapid-fire state propagation that crashes SwiftUI popovers.
private struct SubtitleConfigSection: View {
    @Binding var config: SubtitleExportConfig

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("Create Captions Settings")
                .font(DesignSystem.Typography.caption.weight(.medium))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .padding(.bottom, 4)

            StableSlider(
                title: "Maximum length in characters",
                intValue: $config.maxCharsPerLine,
                range: 10...80,
                step: 1
            )

            StableSlider(
                title: "Maximum duration in seconds",
                intValue: $config.maxDurationMs,
                range: 1000...10000,
                step: 100,
                displayDivisor: 1000.0,
                displayFormat: "%.1f"
            )

            StableSlider(
                title: "Gap between captions (ms)",
                intValue: $config.gapThresholdMs,
                range: 0...2000,
                step: 50
            )

            HStack {
                Text("Lines")
                    .font(DesignSystem.Typography.caption)
                Spacer()
                Picker("", selection: $config.maxLinesPerCue) {
                    Text("Single").tag(1)
                    Text("Double").tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 120)
                .controlSize(.small)
            }
            .padding(.top, 4)

            Toggle("Break on punctuation", isOn: $config.breakOnPunctuation)
                .font(DesignSystem.Typography.caption)

            if config.breakOnPunctuation {
                StableSlider(
                    title: "Min words before punctuation break",
                    intValue: $config.minWordsBeforePunctuationBreak,
                    range: 1...15,
                    step: 1
                )
            }

            Toggle("Balance line lengths", isOn: $config.preferBalancedLines)
                .font(DesignSystem.Typography.caption)
        }
    }
}

// MARK: - StableSlider (crash-proof slider for Int bindings)

/// A slider that maintains its own local Double state during drag gestures.
/// The external Int binding is only updated when the user **releases** the slider,
/// preventing rapid parent view re-evaluation that crashes SwiftUI inside popovers.
///
/// This replaces both the old `SubtitleConfigSlider` (with closure-based onCommit)
/// and the Binding-based approach (which wrote on every frame).
struct StableSlider: View {
    let title: String
    @Binding var intValue: Int
    let range: ClosedRange<Double>
    let step: Double
    var displayDivisor: Double = 1.0
    var displayFormat: String = "%.0f"

    /// Tracks slider position locally during drag. Only synced to the binding on release.
    @State private var dragValue: Double = 0
    /// Whether the user is currently dragging the slider.
    @State private var isDragging = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(DesignSystem.Typography.caption)
                Spacer()
                Text(String(format: displayFormat, dragValue / displayDivisor))
                    .font(DesignSystem.Typography.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $dragValue, in: range, step: step) { editing in
                isDragging = editing
                if !editing {
                    // Commit to the external binding only on release.
                    let committed = Int(dragValue)
                    if committed != intValue {
                        intValue = committed
                    }
                }
            }
            .controlSize(.small)
        }
        .onAppear {
            dragValue = Double(intValue)
        }
        .onChange(of: intValue) { newExternal in
            // External value changed (e.g. reset); update drag position if not dragging.
            if !isDragging {
                let target = Double(newExternal)
                if dragValue != target {
                    dragValue = target
                }
            }
        }
    }
}
