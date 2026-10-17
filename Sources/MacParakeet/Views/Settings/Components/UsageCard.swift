import MacParakeetCore
import MacParakeetViewModels
import SwiftUI

/// Usage & cost panel: what each AI model and speech engine was used for,
/// with an estimated cost from editable prices.
struct UsageCard: View {
    @State private var viewModel = UsageViewModel()
    @State private var editingRow: UsageSummaryRow?
    @State private var confirmingClear = false

    var body: some View {
        SettingsCard(
            title: "Usage & Cost",
            subtitle: "How much each AI model and speech engine has been used on this Mac, with an estimated cost.",
            icon: "chart.bar"
        ) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                HStack {
                    Picker("Period", selection: $viewModel.period) {
                        ForEach(UsageViewModel.Period.allCases) { period in
                            Text(period.title).tag(period)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 340)

                    Spacer()

                    Button("Refresh") { viewModel.reload() }
                        .parakeetAction(.secondary)
                        .controlSize(.small)
                }

                if let error = viewModel.loadError {
                    Text(error)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.errorRed)
                } else if viewModel.isEmpty {
                    Text(
                        "No usage recorded for this period yet. AI requests are counted from the first launch of this version."
                    )
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    totalRow
                    if !viewModel.aiRows.isEmpty {
                        section("AI models") {
                            ForEach(viewModel.aiRows) { aiRow($0) }
                        }
                    }
                    if !viewModel.onlineSpeechRows.isEmpty {
                        section("Online speech service") {
                            ForEach(viewModel.onlineSpeechRows) { onlineSpeechRow($0) }
                        }
                    }
                    if !viewModel.localSpeechRows.isEmpty {
                        section("Local speech engines (free)") {
                            ForEach(viewModel.localSpeechRows) { localSpeechRow($0) }
                        }
                    }
                }

                Text(
                    "Costs are estimates. Services report tokens or audio length, not prices, so the figures use a built-in price list that may be out of date. Click a price to correct it. Your provider's bill is the real amount."
                )
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

                if !viewModel.aiRows.isEmpty || !viewModel.onlineSpeechRows.isEmpty {
                    Button("Clear Usage History…", role: .destructive) { confirmingClear = true }
                        .parakeetAction(.secondary)
                        .controlSize(.small)
                }
            }
        }
        .onAppear { viewModel.reload() }
        .sheet(item: $editingRow) { row in
            UsagePriceEditor(row: row, viewModel: viewModel) { editingRow = nil }
        }
        .confirmationDialog("Clear usage history?", isPresented: $confirmingClear) {
            Button("Clear", role: .destructive) { viewModel.clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the recorded AI and online-speech usage. Transcripts and recordings are not affected.")
        }
    }

    private var totalRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text("Estimated total")
                    .font(DesignSystem.Typography.body.weight(.semibold))
                Spacer()
                Text(UsageViewModel.formatCost(viewModel.estimatedTotal))
                    .font(DesignSystem.Typography.body.weight(.semibold))
                    .monospacedDigit()
            }
            if !viewModel.modelsMissingPrice.isEmpty {
                Text("Not included (no price set): \(viewModel.modelsMissingPrice.joined(separator: ", "))")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.warningAmber)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Divider()
            Text(title)
                .font(DesignSystem.Typography.caption.weight(.semibold))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            content()
        }
    }

    private func aiRow(_ row: UsageSummaryRow) -> some View {
        usageRow(
            title: row.model,
            subtitle: row.isLocal ? "\(row.provider) · local" : row.provider,
            detail:
                "\(row.requests) requests · \(row.tokensEstimated ? "≈ " : "")\(UsageViewModel.formatTokens(row.promptTokens)) in / \(UsageViewModel.formatTokens(row.completionTokens)) out tokens",
            row: row
        )
    }

    private func onlineSpeechRow(_ row: UsageSummaryRow) -> some View {
        usageRow(
            title: row.model,
            subtitle: row.provider,
            detail: "\(row.requests) uploads · \(UsageViewModel.formatDuration(ms: row.audioMs)) of audio",
            row: row
        )
    }

    private func usageRow(title: String, subtitle: String, detail: String, row: UsageSummaryRow) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DesignSystem.Typography.bodySmall.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(subtitle) · \(detail)")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DesignSystem.Spacing.md)
            VStack(alignment: .trailing, spacing: 2) {
                Text(row.isLocal ? "Free" : UsageViewModel.formatCost(viewModel.estimatedCost(for: row)))
                    .font(DesignSystem.Typography.bodySmall.weight(.medium))
                    .monospacedDigit()
                if !row.isLocal {
                    Button(priceButtonTitle(for: row)) { editingRow = row }
                        .buttonStyle(.link)
                        .font(DesignSystem.Typography.caption)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func priceButtonTitle(for row: UsageSummaryRow) -> String {
        if viewModel.price(for: row) == nil { return "Set price" }
        return viewModel.hasCustomPrice(for: row) ? "Your price" : "Edit price"
    }

    private func localSpeechRow(_ row: SpeechEngineUsageRow) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(SpeechEnginePreference(rawValue: row.engine)?.displayName ?? row.engine.capitalized)
                    .font(DesignSystem.Typography.bodySmall.weight(.medium))
                Text(
                    "\(row.variant.map { "\($0) · " } ?? "")\(row.items) recordings · \(UsageViewModel.formatDuration(ms: row.audioMs)) of audio"
                )
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            Spacer()
            Text("Free")
                .font(DesignSystem.Typography.bodySmall.weight(.medium))
        }
        .padding(.vertical, 2)
    }
}

/// Sheet for correcting the price used to estimate one model's cost.
private struct UsagePriceEditor: View {
    let row: UsageSummaryRow
    var viewModel: UsageViewModel
    var onDone: () -> Void

    @State private var input = ""
    @State private var output = ""
    @State private var audio = ""

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Text("Price for \(row.model)")
                .font(DesignSystem.Typography.body.weight(.semibold))
            Text("Enter your provider's current price in US dollars.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)

            if row.kind == .llm {
                field("Input, per 1M tokens", text: $input)
                field("Output, per 1M tokens", text: $output)
            } else {
                field("Audio, per minute", text: $audio)
            }

            HStack {
                if viewModel.hasCustomPrice(for: row) {
                    Button("Use Built-in Price") {
                        viewModel.setPrice(nil, for: row)
                        onDone()
                    }
                    .parakeetAction(.secondary)
                }
                Spacer()
                Button("Cancel", action: onDone)
                    .parakeetAction(.secondary)
                Button("Save") {
                    viewModel.setPrice(
                        UsagePrice(
                            inputPerMillion: Self.number(input),
                            outputPerMillion: Self.number(output),
                            audioPerMinute: Self.number(audio)
                        ),
                        for: row
                    )
                    onDone()
                }
                .parakeetAction(.primary)
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(width: 380)
        .onAppear {
            let price = viewModel.price(for: row) ?? UsagePrice()
            input = Self.text(price.inputPerMillion)
            output = Self.text(price.outputPerMillion)
            audio = Self.text(price.audioPerMinute)
        }
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        HStack {
            Text(title)
                .font(DesignSystem.Typography.bodySmall)
            Spacer()
            Text("$")
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            TextField("0", text: text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 110)
                .multilineTextAlignment(.trailing)
        }
    }

    /// Accepts both "0.15" and "0,15".
    private static func number(_ text: String) -> Double {
        max(0, Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) ?? 0)
    }

    private static func text(_ value: Double) -> String {
        value == 0 ? "" : String(format: "%g", value)
    }
}
