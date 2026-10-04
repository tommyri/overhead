import Foundation

/// Published subscription prices (USD per month) keyed by the identifiers each product uses
/// for its tiers. Used to pre-fill the monthly fee once a provider reports the user's tier.
/// Verified against the vendors' pricing pages and the open-source clients that read these
/// identifiers; see `lastReviewed`.
public enum PlanPrices {
    public static let lastReviewed = "2026-10-04"

    public struct Tier: Sendable, Hashable {
        public let name: String
        public let monthly: Double?
        /// Per-month equivalent when billed annually, if the vendor offers it.
        public let annual: Double?
    }

    // MARK: Cursor — `membershipType` / `individualMembershipType` from cursor.com
    // https://cursor.com/pricing — yearly billing is 20% off across the board.

    public static func cursor(membershipType raw: String, yearly: Bool = false) -> Tier? {
        let t: Tier
        switch raw.lowercased() {
        case "free", "hobby":                 t = Tier(name: "Cursor Hobby", monthly: 0, annual: 0)
        case "free_trial", "pro_trial":       t = Tier(name: "Cursor Pro trial", monthly: 0, annual: 0)
        case "express":                       t = Tier(name: "Cursor Start", monthly: nil, annual: nil)
        case "pro", "pro_student":            t = Tier(name: "Cursor Pro", monthly: 20, annual: 16)
        case "pro_plus", "pro+", "proplus":   t = Tier(name: "Cursor Pro+", monthly: 60, annual: 48)
        case "ultra":                         t = Tier(name: "Cursor Ultra", monthly: 200, annual: 160)
        case "team", "teams", "business":     t = Tier(name: "Cursor Teams", monthly: nil, annual: nil) // Standard $40 or Premium $120 per seat
        case "enterprise":                    t = Tier(name: "Cursor Enterprise", monthly: nil, annual: nil)
        default:                              return nil
        }
        return yearly ? Tier(name: t.name, monthly: t.annual ?? t.monthly, annual: t.annual) : t
    }

    // MARK: ChatGPT — `plan_type` written by Codex CLI (codex-rs/protocol/src/account.rs)
    // https://learn.chatgpt.com/docs/pricing — Pro tiers are monthly-only.

    public static func chatGPT(planType raw: String) -> Tier? {
        switch raw.lowercased() {
        case "free":                                  return Tier(name: "ChatGPT Free", monthly: 0, annual: nil)
        case "go":                                    return Tier(name: "ChatGPT Go", monthly: 8, annual: nil)
        case "plus":                                  return Tier(name: "ChatGPT Plus", monthly: 20, annual: nil)
        case "prolite", "pro_lite", "pro-lite":       return Tier(name: "ChatGPT Pro 100", monthly: 100, annual: nil)
        case "pro":                                   return Tier(name: "ChatGPT Pro 200", monthly: 200, annual: nil)
        case "promax", "pro_max":                     return Tier(name: "ChatGPT Pro 500", monthly: 500, annual: nil)
        case "team", "self_serve_business_usage_based": return Tier(name: "ChatGPT Business", monthly: 25, annual: 20)
        case "self_serve_business_prolite":           return Tier(name: "ChatGPT Business Premium", monthly: nil, annual: nil)
        case "business", "enterprise", "hc", "ent26",
             "enterprise_cbp_usage_based":            return Tier(name: "ChatGPT Enterprise", monthly: nil, annual: nil)
        case "enterprise_cbp_automation":             return Tier(name: "ChatGPT Enterprise (Automation)", monthly: nil, annual: nil)
        case "edu", "education":                      return Tier(name: "ChatGPT Edu", monthly: nil, annual: nil)
        case "edu_plus":                              return Tier(name: "ChatGPT Edu Plus", monthly: nil, annual: nil)
        case "edu_pro":                               return Tier(name: "ChatGPT Edu Pro", monthly: nil, annual: nil)
        default:                                      return nil
        }
    }

    // MARK: Claude — fields cached by Claude Code in ~/.claude.json → oauthAccount
    // https://claude.com/pricing and support.claude.com Team/Max articles.
    //   organizationType: claude_pro | claude_max | claude_team | claude_enterprise
    //   userRateLimitTier: default_claude_ai (Pro) | default_claude_max_5x | default_claude_max_20x
    //   seatTier (Team): team_standard | team_tier_1 (Premium) | team_tier_2 (higher Premium)

    public static func claude(organizationType: String?, seatTier: String?, billingType: String?, rateLimitTier: String?) -> Tier? {
        let org = organizationType?.lowercased() ?? ""
        let seat = seatTier?.lowercased() ?? ""
        let tier = rateLimitTier?.lowercased() ?? ""

        if org.contains("enterprise") {
            return Tier(name: "Claude Enterprise", monthly: nil, annual: nil) // $20/seat + usage, billed annually
        }
        if org.contains("team") {
            if seat == "team_standard" || seat.contains("standard") {
                return Tier(name: "Claude Team (Standard seat)", monthly: 25, annual: 20)
            }
            if seat == "team_tier_1" || seat.contains("premium") || tier.contains("max_5") {
                return Tier(name: "Claude Team (Premium seat)", monthly: 125, annual: 100)
            }
            if seat.hasPrefix("team_tier") || tier.contains("max") {
                return Tier(name: "Claude Team (Premium seat, higher tier)", monthly: nil, annual: nil)
            }
            return Tier(name: "Claude Team", monthly: nil, annual: nil)
        }
        if tier.contains("max_20") || tier.contains("20x") || tier.contains("x20") { return Tier(name: "Claude Max 20x", monthly: 200, annual: nil) }
        if tier.contains("max_5") || tier.contains("5x") || tier.contains("x5") || org.contains("max") { return Tier(name: "Claude Max 5x", monthly: 100, annual: nil) }
        if tier.contains("claude_ai") || tier.contains("pro") || org.contains("pro") { return Tier(name: "Claude Pro", monthly: 20, annual: 17) }
        if tier.contains("free") || org.contains("free") { return Tier(name: "Claude Free", monthly: 0, annual: 0) }
        if let billingType, !billingType.isEmpty {
            return Tier(name: "Claude (\(billingType.replacingOccurrences(of: "_", with: " ")))", monthly: nil, annual: nil)
        }
        return nil
    }
}
