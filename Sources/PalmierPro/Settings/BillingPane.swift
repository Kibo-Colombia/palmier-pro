import AppKit
import SwiftUI

/// Settings ▸ Billing — the in-app spend guard for AI usage (generation + summaries). Set a
/// monthly cap, watch the running tally, and (optionally) block actions that would exceed it.
/// Pairs with the provider-side hard caps, which are the real protection.
struct BillingPane: View {
    @Bindable private var budget = BudgetStore.shared

    private let falURL = URL(string: "https://fal.ai/dashboard/billing")!
    private let anthropicURL = URL(string: "https://console.anthropic.com/settings/limits")!

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            capSection
            usageCard
            Divider().overlay(AppTheme.Border.subtleColor)
            SettingsToggleRow(
                title: "Block actions over budget",
                subtitle: "Refuse a generation or AI call whose estimated cost would exceed the monthly cap.",
                isOn: $budget.enforce
            )
            Divider().overlay(AppTheme.Border.subtleColor)
            hardCapNote
        }
    }

    private var capSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            Text("Monthly budget")
                .font(.system(size: AppTheme.FontSize.md, weight: .medium))
                .foregroundStyle(AppTheme.Text.primaryColor)
            Text("A soft cap on estimated AI spend per month. Set 0 to track without a limit.")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: AppTheme.Spacing.sm) {
                TextField("0", value: $budget.monthlyCapUSD, format: .currency(code: "USD"))
                    .textFieldStyle(.plain)
                    .font(.system(size: AppTheme.FontSize.md, design: .monospaced))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .frame(width: 120)
                    .padding(.horizontal, AppTheme.Spacing.md)
                    .padding(.vertical, AppTheme.Spacing.smMd)
                    .background(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                            .fill(Color.black.opacity(AppTheme.Opacity.muted))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                            .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
                    )
                Text("/ month")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
        }
    }

    private var usageCard: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            HStack(alignment: .firstTextBaseline) {
                Text(usageHeadline)
                    .font(.system(size: AppTheme.FontSize.md, weight: .medium))
                    .foregroundStyle(budget.isOverBudget ? Color.red : AppTheme.Text.primaryColor)
                Spacer()
                Button("Reset", action: budget.resetThisMonth)
                    .buttonStyle(.plain)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .help("Clear this month's tracked spend")
            }

            if budget.hasCap {
                ProgressView(value: budget.fractionUsed)
                    .tint(budget.isOverBudget ? .red : AppTheme.Accent.primary)
            }

            Text("Resets \(budget.resetsAt.formatted(.dateTime.month().day()))")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.mutedColor)
        }
        .padding(AppTheme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .fill(Color.black.opacity(AppTheme.Opacity.muted))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
        )
    }

    private var usageHeadline: String {
        let spent = budget.spentThisMonthUSD.formatted(.currency(code: "USD"))
        guard budget.hasCap else { return "\(spent) this month" }
        let cap = budget.monthlyCapUSD.formatted(.currency(code: "USD"))
        return "\(spent) of \(cap) this month"
    }

    private var hardCapNote: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text("Real protection: set a hard cap with the providers")
                .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            Text("This in-app limit is a convenience based on estimates. A provider-enforced cap is the only guarantee.")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: AppTheme.Spacing.lg) {
                linkButton("fal.ai billing", falURL)
                linkButton("Anthropic limits", anthropicURL)
            }
            .padding(.top, AppTheme.Spacing.xxs)
        }
    }

    private func linkButton(_ title: String, _ url: URL) -> some View {
        Button(action: { NSWorkspace.shared.open(url) }) {
            HStack(spacing: 2) {
                Text(title)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
            }
            .font(.system(size: AppTheme.FontSize.sm))
            .foregroundStyle(AppTheme.Accent.primary)
        }
        .buttonStyle(.plain)
    }
}
