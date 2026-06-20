import Foundation

/// A soft, in-app spend guard for AI usage (generation + LLM), so a runaway loop or a fat-finger
/// can't quietly drain a provider account. This is a *convenience* rail on top of the real
/// protection — a hard spending cap set in the provider dashboards (fal.ai, Anthropic). It tracks
/// estimated spend per calendar month and can block actions that would push over the cap.
@Observable
@MainActor
final class BudgetStore {
    static let shared = BudgetStore()

    /// Monthly ceiling in USD. 0 means "no cap" (tracking only).
    var monthlyCapUSD: Double {
        didSet { UserDefaults.standard.set(monthlyCapUSD, forKey: Keys.cap) }
    }

    /// When true, an action whose estimated cost would exceed the cap is blocked.
    var enforce: Bool {
        didSet { UserDefaults.standard.set(enforce, forKey: Keys.enforce) }
    }

    /// Estimated spend keyed by month ("yyyy-MM"). Kept as monthly totals — small and durable.
    private(set) var monthlySpend: [String: Double]

    private enum Keys {
        static let cap = "budget.monthlyCapUSD"
        static let enforce = "budget.enforce"
        static let spend = "budget.monthlySpend"
    }

    private init() {
        let defaults = UserDefaults.standard
        monthlyCapUSD = defaults.object(forKey: Keys.cap) as? Double ?? 10
        enforce = defaults.object(forKey: Keys.enforce) as? Bool ?? true
        monthlySpend = (defaults.dictionary(forKey: Keys.spend) as? [String: Double]) ?? [:]
    }

    // MARK: - Derived

    var spentThisMonthUSD: Double { monthlySpend[Self.currentMonthKey()] ?? 0 }
    var remainingUSD: Double { max(0, monthlyCapUSD - spentThisMonthUSD) }
    var hasCap: Bool { monthlyCapUSD > 0 }
    var fractionUsed: Double {
        guard monthlyCapUSD > 0 else { return 0 }
        return min(1, spentThisMonthUSD / monthlyCapUSD)
    }
    var isOverBudget: Bool { hasCap && spentThisMonthUSD >= monthlyCapUSD }

    /// First moment of next month — when the soft tally rolls over.
    var resetsAt: Date {
        let cal = Calendar.current
        let start = cal.dateInterval(of: .month, for: Date())?.start ?? Date()
        return cal.date(byAdding: .month, value: 1, to: start) ?? Date()
    }

    // MARK: - Guard + record

    /// True if `cost` would push this month's spend over the cap (only when enforcing with a cap).
    func wouldExceed(addingUSD cost: Double) -> Bool {
        guard enforce, monthlyCapUSD > 0 else { return false }
        return spentThisMonthUSD + cost > monthlyCapUSD
    }

    /// Record actual/estimated spend against the current month.
    func record(_ cost: Double) {
        guard cost > 0 else { return }
        let key = Self.currentMonthKey()
        monthlySpend[key, default: 0] += cost
        persist()
    }

    func resetThisMonth() {
        monthlySpend[Self.currentMonthKey()] = 0
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(monthlySpend, forKey: Keys.spend)
    }

    private static func currentMonthKey() -> String {
        let comps = Calendar.current.dateComponents([.year, .month], from: Date())
        return String(format: "%04d-%02d", comps.year ?? 0, comps.month ?? 0)
    }
}
